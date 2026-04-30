//
//  CompanionManager.swift
//  TipTour
//
//  Central state manager for the Gemini Live voice companion. Owns the
//  push-to-talk hotkey, screen capture, Gemini Live session, tool handlers
//  for cursor pointing + multi-step workflows, and overlay management.
//

import AVFoundation
import Combine
import Foundation
import PostHog
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// cursor should fly to and point at. Observed by BlueCursorView to
    /// trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// Display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation.
    @Published var detectedElementBubbleText: String?

    /// Show YOLO detection boxes overlay — toggle from dev tools.
    @Published var showDetectionOverlay: Bool = false
    /// Latest detected elements from the native detector for overlay rendering.
    @Published var detectedElements: [[String: Any]] = []
    /// Image size of the screenshot used for detection (for coordinate scaling).
    @Published var detectedImageSize: [Int] = [1512, 982]
    /// The element currently being highlighted (matched by voice query).
    @Published var highlightedElementLabel: String? = nil

    /// Whether the blue cursor overlay is currently visible on screen.
    @Published private(set) var isOverlayVisible: Bool = false

    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()

    /// Base URL for the Cloudflare Worker proxy. All API requests route
    /// through this so keys never ship in the app binary.
    private static let workerBaseURL: String = {
        let url = "https://clicky-proxy.milindsoni201.workers.dev"
        // ElementResolver's multilingual /match-label fallback hits the
        // same worker. Setting the override here means we have one
        // source of truth for the base URL.
        ElementResolver.workerBaseURLOverride = url
        return url
    }()

    private var shortcutTransitionCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var voiceAudioPowerCancellable: AnyCancellable?
    private var voiceModelSpeakingCancellable: AnyCancellable?

    /// True when all four required permissions (accessibility, screen recording,
    /// microphone, screen content) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Backing storage for the active voice session. Built lazily on first
    /// access via `voiceBackend`. Single backend now — Gemini Live.
    private var _voiceBackend: GeminiLiveSession?

    /// The active voice session. Constructs the Gemini Live session on
    /// first access and wires all the tool / transcript callbacks once.
    var voiceBackend: GeminiLiveSession {
        if let existing = _voiceBackend { return existing }
        let backend = GeminiLiveSession(
            apiKeyURL: "\(Self.workerBaseURL)/gemini-live-key",
            systemPrompt: Self.companionVoiceResponseSystemPrompt
        )
        wireCallbacks(on: backend)
        _voiceBackend = backend
        rebindVoiceBackendPublishers(backend)
        return backend
    }

    /// Hook all tool / transcript / error callbacks.
    private func wireCallbacks(on backend: GeminiLiveSession) {
        backend.onPointAtElement = { [weak self] id, label, box2DNormalized, screenshotJPEG in
            await self?.handleToolPointAtElement(
                id: id,
                label: label,
                box2DNormalized: box2DNormalized,
                screenshotJPEG: screenshotJPEG
            ) ?? ["ok": false]
        }
        backend.onSubmitWorkflowPlan = { [weak self] id, goal, app, steps in
            await self?.handleToolSubmitWorkflowPlan(id: id, goal: goal, app: app, steps: steps) ?? ["ok": false]
        }
        backend.onOutputTranscript = { [weak self] fullTranscript in
            self?.handleVoiceTranscriptUpdate(fullTranscript)
        }
        backend.onInputTranscriptUpdate = { [weak self] fullInputTranscript in
            guard let self else { return }
            let isNewUtterance = fullInputTranscript.trimmingCharacters(in: .whitespacesAndNewlines).count > 0
                && self.previousInputTranscriptLength == 0
            if isNewUtterance {
                self.handledToolCallIDsThisUtterance.removeAll()
                self.planAppliedThisTurn = false
                self.lastVoiceTranscriptLength = 0
            }
            self.previousInputTranscriptLength = fullInputTranscript.count
        }
        backend.onTurnComplete = { [weak self] in
            self?.previousInputTranscriptLength = 0
        }
        backend.onError = { error in
            print("[VoiceBackend] Error: \(error.localizedDescription)")
        }
    }

    /// Subscribe to the backend's audio-power and model-speaking publishers.
    private func rebindVoiceBackendPublishers(_ backend: GeminiLiveSession) {
        voiceAudioPowerCancellable = backend.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
        voiceModelSpeakingCancellable = backend.$isModelSpeaking
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isSpeaking in
                guard let self = self, self.voiceBackend.isActive else { return }
                self.voiceState = isSpeaking ? .responding : .listening
            }
    }

    // MARK: - box_2d → screenshot-pixel conversion

    /// Convert Gemini's `box_2d` (in normalized [y1, x1, y2, x2] form, each
    /// value in [0, 1000]) to the box's center in screenshot-pixel space.
    /// Returns nil when no valid box was provided OR when we don't yet have
    /// a screenshot to scale against.
    ///
    /// Why box_2d at all: Gemini 2.5 / 3.x is natively trained to localize
    /// in this exact format. Asking for free-form (x, y) integers makes the
    /// model do mental math against a downscaled image it never sees the
    /// resolution of, which hurts pixel precision. box_2d normalizes that
    /// away — the model emits the same format the docs prescribe and we
    /// scale to the real screenshot dimensions on our side.
    private func pixelHintFromBox2D(
        box2DNormalized: [Int]?,
        capture: CompanionScreenCapture?
    ) -> CGPoint? {
        guard let box = box2DNormalized, box.count == 4, let capture else {
            return nil
        }
        let y1Norm = CGFloat(box[0])
        let x1Norm = CGFloat(box[1])
        let y2Norm = CGFloat(box[2])
        let x2Norm = CGFloat(box[3])

        let centerNormX = (x1Norm + x2Norm) / 2
        let centerNormY = (y1Norm + y2Norm) / 2

        let screenshotWidth = CGFloat(capture.screenshotWidthInPixels)
        let screenshotHeight = CGFloat(capture.screenshotHeightInPixels)

        let pixelX = centerNormX * screenshotWidth / 1000
        let pixelY = centerNormY * screenshotHeight / 1000
        return CGPoint(x: pixelX, y: pixelY)
    }

    // MARK: - Tool Handlers

    /// Handle the `point_at_element` tool call. Resolves the label via the
    /// AX tree → YOLO + OCR cascade and flies the cursor there. When Gemini
    /// supplies a `box_2d`, its center (in screenshot-pixel space) is fed
    /// to the resolver as a coordinate hint for the YOLO and raw-LLM-coord
    /// fallbacks.
    @MainActor
    private func handleToolPointAtElement(
        id: String,
        label: String,
        box2DNormalized: [Int]?,
        screenshotJPEG: Data?
    ) async -> [String: Any] {
        if handledToolCallIDsThisUtterance.contains(id) {
            print("[Tool] ⏭️  ignoring duplicate point_at_element id=\(id)")
            return ["ok": true, "duplicate": true]
        }
        handledToolCallIDsThisUtterance.insert(id)

        // A point_at_element call means the user is asking about a single
        // visible element — supersede any abandoned multi-step plan.
        if let activePlan = WorkflowRunner.shared.activePlan {
            print("[Tool] 🔄 superseding active plan \"\(activePlan.goal)\" — user asked for a single element \"\(label)\"")
            WorkflowRunner.shared.stop()
        }
        let capture = voiceBackend.latestCapture
        let hintInScreenshotPixels = pixelHintFromBox2D(
            box2DNormalized: box2DNormalized,
            capture: capture
        )
        if let hintInScreenshotPixels {
            print("[Tool] 🔧 point_at_element(label=\"\(label)\", box_2d=\(box2DNormalized ?? []) → screenshot pixel \(hintInScreenshotPixels))")
        } else {
            print("[Tool] 🔧 point_at_element(label=\"\(label)\")")
        }
        let startedAt = Date()
        planAppliedThisTurn = true
        let resolution = await ElementResolver.shared.resolve(
            label: label,
            llmHintInScreenshotPixels: hintInScreenshotPixels,
            latestCapture: capture
        )
        let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
        guard let resolution else {
            print("[Tool] ✗ point_at_element(\"\(label)\") → no match after \(elapsed)ms")
            voiceBackend.invalidateScreenshotHashCache()
            return ["ok": false, "reason": "element_not_found", "label": label]
        }
        print("[Tool] ✓ point_at_element(\"\(label)\") → \(resolution.label) via \(resolution.source) in \(elapsed)ms")
        pointAtResolution(resolution)

        // Single-click ask — disarm any leftover ClickDetector state from a
        // previous workflow.
        ClickDetector.shared.disarm()

        // Mute screenshot pushes until the user speaks again so Gemini doesn't
        // re-emit the same tool call on a "user hasn't moved" frame.
        voiceBackend.suppressScreenshotsUntilUserSpeaks()

        return [
            "ok": true,
            "label": resolution.label,
            "source": String(describing: resolution.source)
        ]
    }

    /// Handle the `submit_workflow_plan` tool call. Gemini produces the
    /// plan itself via its own vision + reasoning; this just converts the
    /// raw tool args into a WorkflowPlan and kicks off the runner.
    @MainActor
    private func handleToolSubmitWorkflowPlan(id: String, goal: String, app: String, steps: [[String: Any]]) async -> [String: Any] {
        if handledToolCallIDsThisUtterance.contains(id) {
            print("[Tool] ⏭️  ignoring duplicate submit_workflow_plan id=\(id)")
            return ["ok": true, "duplicate": true]
        }
        handledToolCallIDsThisUtterance.insert(id)

        if let activePlan = WorkflowRunner.shared.activePlan {
            let isSameGoalAsActivePlan = activePlan.goal.caseInsensitiveCompare(goal) == .orderedSame
            if isSameGoalAsActivePlan {
                print("[Tool] ⏭️  rejecting submit_workflow_plan — same-goal re-submit of \"\(activePlan.goal)\" (already on step \(WorkflowRunner.shared.activeStepIndex + 1)/\(activePlan.steps.count))")
                return [
                    "ok": false,
                    "reason": "plan_already_running",
                    "message": "This exact plan is already executing on the user's machine. The user reads at human speed; an unchanged screenshot is normal. Do not re-submit this plan. Stay silent and wait for the user to speak again."
                ]
            }
            print("[Tool] 🔄 superseding active plan \"\(activePlan.goal)\" with new request \"\(goal)\"")
            WorkflowRunner.shared.stop()
        }

        print("[Tool] 🔧 submit_workflow_plan(goal=\"\(goal)\", app=\"\(app)\", \(steps.count) steps)")
        planAppliedThisTurn = true

        let captureForBoxConversion = voiceBackend.latestCapture
        let parsedSteps: [WorkflowStep] = steps.enumerated().map { index, raw in
            let label = raw["label"] as? String
            let hint = raw["hint"] as? String ?? ""

            // Convert Gemini's box_2d ([y1, x1, y2, x2] in [0, 1000]) to
            // the box's center in screenshot-pixel space. The downstream
            // resolver / YOLO pipeline expects pixel coords.
            let box2DNormalized = (raw["box_2d"] as? [Int]).flatMap { $0.count == 4 ? $0 : nil }
            let pixelCenter = pixelHintFromBox2D(
                box2DNormalized: box2DNormalized,
                capture: captureForBoxConversion
            )
            let hintX = pixelCenter.map { Int($0.x) }
            let hintY = pixelCenter.map { Int($0.y) }

            return WorkflowStep(
                id: "step_\(index + 1)",
                type: .click,
                label: label,
                hint: hint,
                hintX: hintX,
                hintY: hintY,
                screenNumber: nil
            )
        }

        guard !parsedSteps.isEmpty else {
            print("[Tool] ✗ submit_workflow_plan — zero steps")
            return ["ok": false, "reason": "empty_steps"]
        }

        let plan = WorkflowPlan(
            goal: goal,
            app: app.isEmpty ? nil : app,
            steps: parsedSteps
        )
        let stepLabels = parsedSteps.map { $0.label ?? "<unlabeled>" }
        print("[Tool] ✓ submit_workflow_plan → \(plan.app ?? "?"): \(stepLabels)")
        startWorkflowPlan(plan)

        voiceBackend.suppressScreenshotsUntilUserSpeaks()

        // Pause mic + screenshots so Gemini can narrate the plan in one
        // uninterrupted turn. Once narration finishes, exit narration mode
        // — mic/screenshots resume but the WebSocket stays open.
        print("[Workflow] entering Gemini narration mode — mic/screenshots paused, socket kept alive for narration")
        voiceBackend.enterNarrationMode()
        scheduleExitNarrationModeAfterSpeechEnds()

        return [
            "ok": true,
            "accepted_steps": stepLabels.count
        ]
    }

    /// Wait for Gemini's post-tool narration turn to finish, then exit
    /// narration mode so mic + periodic screenshots resume. Session stays
    /// open for conversational follow-ups.
    private func scheduleExitNarrationModeAfterSpeechEnds() {
        // OpenAI Realtime regularly takes 3-5s for post-tool-call audio
        // to start arriving (TTFT after function_call_output → response.create).
        // Gemini Live is closer to 1-2s. Use 6s so neither backend's
        // narration is cut off before it can start.
        let silentNarrationGraceSeconds: TimeInterval = 6.0
        let quietConfirmationSeconds: TimeInterval = 0.8
        let maxTotalWaitSeconds: TimeInterval = 15.0

        Task { [weak self] in
            guard let self = self else { return }

            let startedAt = Date()
            let maxDeadline = startedAt.addingTimeInterval(maxTotalWaitSeconds)
            var hasObservedSpeechStart = false
            var quietSinceTimestamp: Date?

            while Date() < maxDeadline {
                try? await Task.sleep(nanoseconds: 200_000_000)

                let (isActive, speaking, playing) = await MainActor.run { () -> (Bool, Bool, Bool) in
                    (
                        self.voiceBackend.isActive,
                        self.voiceBackend.isModelSpeaking,
                        self.voiceBackend.isAudioPlaying
                    )
                }
                if !isActive { return }

                let currentlySpeaking = speaking || playing
                if currentlySpeaking {
                    hasObservedSpeechStart = true
                    quietSinceTimestamp = nil
                    continue
                }

                if !hasObservedSpeechStart,
                   Date().timeIntervalSince(startedAt) >= silentNarrationGraceSeconds {
                    break
                }

                if hasObservedSpeechStart {
                    if quietSinceTimestamp == nil {
                        quietSinceTimestamp = Date()
                    } else if let quietStart = quietSinceTimestamp,
                              Date().timeIntervalSince(quietStart) >= quietConfirmationSeconds {
                        break
                    }
                }
            }

            await MainActor.run {
                guard self.voiceBackend.isActive else { return }
                print("[Workflow] narration window closed — exiting narration mode, session stays alive for follow-ups")
                self.voiceBackend.exitNarrationMode()
                self.planAppliedThisTurn = false
            }
        }
    }

    /// Set of tool-call IDs we've already dispatched within the current
    /// user utterance. Reset when a new user utterance starts.
    private var handledToolCallIDsThisUtterance: Set<String> = []

    /// Set when a tool call has already applied a pointing/plan this turn,
    /// so the legacy [POINT:] transcript-tag fallback doesn't fight it.
    private var planAppliedThisTurn: Bool = false

    /// Tracks input transcript length on the last update so we can detect
    /// "transcript went from empty → non-empty" — the reliable signal that
    /// a new user utterance just began.
    private var previousInputTranscriptLength: Int = 0

    // MARK: - Toggles

    /// Pin the menu bar panel so outside clicks don't dismiss it.
    @Published var isPanelPinned: Bool = UserDefaults.standard.bool(forKey: "isPanelPinned")

    func setPanelPinned(_ pinned: Bool) {
        isPanelPinned = pinned
        UserDefaults.standard.set(pinned, forKey: "isPanelPinned")
        NotificationCenter.default.post(name: .tipTourPanelPinStateChanged, object: nil)
    }

    /// Neko mode: replace the blue triangle cursor with a pixel-art cat
    /// (classic oneko sprites). Defaults ON for new installs since the cat
    /// is part of TipTour's identity.
    @Published var isNekoModeEnabled: Bool = UserDefaults.standard.object(forKey: "isNekoModeEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isNekoModeEnabled")

    func setNekoModeEnabled(_ enabled: Bool) {
        isNekoModeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isNekoModeEnabled")
    }

    /// Debug flag for the workflow checklist: when true, ClickDetector
    /// advances on ANY click instead of requiring the click to land
    /// within 40pt of the resolved target.
    @Published var advanceOnAnyClickEnabled: Bool = UserDefaults.standard.bool(forKey: "advanceOnAnyClickEnabled") {
        didSet {
            ClickDetector.advanceOnAnyClickEnabled = advanceOnAnyClickEnabled
        }
    }

    func setAdvanceOnAnyClickEnabled(_ enabled: Bool) {
        advanceOnAnyClickEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "advanceOnAnyClickEnabled")
    }

    // MARK: - Onboarding

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Text streamed character-by-character on the cursor when the user
    /// first completes onboarding — "press ctrl+option to talk".
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    func triggerOnboarding() {
        NotificationCenter.default.post(name: .tipTourDismissPanel, object: nil)
        hasCompletedOnboarding = true
        TipTourAnalytics.trackOnboardingStarted()
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    func showOnboardingHotkeyPrompt() {
        startOnboardingPromptStream()
    }

    private func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    // MARK: - Lifecycle

    func start() {
        refreshAllPermissions()
        print("🔑 TipTour start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        // Touch the lazy property so the backend is constructed and the
        // publishers are subscribed BEFORE the user opens the panel /
        // presses the hotkey.
        _ = voiceBackend
        bindShortcutTransitions()
        beginTrackingUserTargetApp()
        ClickDetector.advanceOnAnyClickEnabled = advanceOnAnyClickEnabled

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        overlayWindowManager.hideOverlay()
        shortcutTransitionCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
        voiceAudioPowerCancellable?.cancel()
        voiceModelSpeakingCancellable?.cancel()
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
        highlightedElementLabel = nil
    }

    // MARK: - Permissions

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        if !previouslyHadAccessibility && hasAccessibilityPermission {
            TipTourAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            TipTourAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            TipTourAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted — once approved it sticks.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            TipTourAnalytics.trackAllPermissionsGranted()
        }
    }

    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    TipTourAnalytics.trackPermissionGranted(permission: "screen_content")

                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    /// Watch NSWorkspace for app-activation events and continuously remember
    /// the last NON-TipTour app the user activated. This is the
    /// `userTargetAppOverride` the AX resolver uses to route queries at
    /// the right app.
    private func beginTrackingUserTargetApp() {
        if let current = NSWorkspace.shared.frontmostApplication,
           current.bundleIdentifier != Bundle.main.bundleIdentifier {
            AccessibilityTreeResolver.userTargetAppOverride = current
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            AccessibilityTreeResolver.userTargetAppOverride = app
        }
    }

    private func handleShortcutTransition(_ transition: PushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            // Snapshot the user's real frontmost app BEFORE opening the
            // menu bar panel or cursor overlay. Once TipTour shows any UI
            // macOS may flip frontmost to us, so this is the only reliable
            // moment to capture which app the user was actually looking at.
            if let frontmost = NSWorkspace.shared.frontmostApplication,
               frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
                AccessibilityTreeResolver.userTargetAppOverride = frontmost
                print("[Target] user's app at hotkey press: \(frontmost.bundleIdentifier ?? "?") (\(frontmost.localizedName ?? "?"))")
            }

            NotificationCenter.default.post(name: .tipTourDismissPanel, object: nil)
            clearDetectedElementLocation()

            showOnboardingPrompt = false
            onboardingPromptText = ""
            onboardingPromptOpacity = 0.0

            TipTourAnalytics.trackPushToTalkStarted()

            // Gemini Live uses TOGGLE behavior — press once to start, press
            // again to end. The connection stays open across turns so the
            // user can have a real conversation.
            if voiceBackend.isActive {
                stopVoiceSession()
                voiceState = .idle
            } else {
                startVoiceSession()
                voiceState = .listening
            }
        case .released:
            // Release is a no-op — the session is toggled by hotkey PRESS.
            TipTourAnalytics.trackPushToTalkReleased()
        case .none:
            break
        }
    }

    /// Fly the cursor to a resolved element. The Resolution already contains
    /// global AppKit coordinates — no further conversion needed.
    private func pointAtResolution(_ resolution: ElementResolver.Resolution) {
        detectedElementScreenLocation = resolution.globalScreenPoint
        detectedElementDisplayFrame = resolution.displayFrame
        detectedElementBubbleText = resolution.label
    }

    // MARK: - Detection Overlay (Debug)

    func startDetectionOverlayFeeding() {
        NativeElementDetector.shared.startLiveFeeding(interval: 1.5) { [weak self] in
            guard let cgImage = try? await CompanionScreenCaptureUtility.capturePrimaryScreenAsCGImage() else { return nil }
            Task {
                await self?.updateDetectionOverlay()
            }
            return cgImage
        }
    }

    private func updateDetectionOverlay() async {
        let cached = NativeElementDetector.shared.getCachedElements()
        await MainActor.run {
            self.detectedElements = cached.elements
            self.detectedImageSize = cached.imageSize
        }
    }

    // MARK: - Companion Prompt

    private static let companionVoiceResponseSystemPrompt = """
    you're tiptour, a friendly always-on companion that lives in the user's menu bar. you can see the user's screen(s) at all times via streaming screenshots, and you can hear them when they speak. your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    SILENCE-AT-CONNECT RULE (CRITICAL — read every time):
    when a session begins, you are silent. you wait. do NOT greet the user. do NOT say "hi" / "hello" / "i see you have X" / "how can i help". do NOT comment on what's on screen. do NOT narrate anything you see in incoming screenshots. screenshots arriving on their own are NOT a prompt to speak — they're just visual context for when the user eventually does speak. the very first thing you say in this session must be a direct response to the user's actual VOICE — words you heard them speak through the microphone. background noise, breathing, mouse clicks, keyboard taps, room sound, music, or ambient audio are NOT user input — ignore them and stay silent. if the input transcript is empty or contains only non-speech sounds, you stay silent. never speak first.

    GREETING-ONLY RULE (CRITICAL — read every time):
    if the user's utterance is just a greeting ("hi", "hey", "hello", "yo", "what's up", "good morning", etc.) and contains no actual question or request, respond with a brief greeting back ("hey", "hi there", "what's up") and STOP. do NOT volunteer information about what's on screen. do NOT call any tool. do NOT mention menus, buttons, or anything visible. wait for the user to ask an actual question. screen content is reference material for when the user asks about it — never narrate it unprompted, even right after a greeting.

    rules:
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    element pointing via tools (VERY IMPORTANT — read carefully):

    you have exactly TWO tools. call AT MOST ONE tool per turn. do NOT narrate before the tool call. call it silently, wait for the response, THEN speak ONCE.

    TOOL: point_at_element(label, box_2d?)
      use for a SINGLE visible element. examples: "where's the save button", "point at the color inspector", "what is this tab".
      label = literal visible text on screen.
      box_2d = OPTIONAL bounding box in [y1, x1, y2, x2] form, each value in [0, 1000] normalized to the screenshot. origin top-left, y first. include this whenever you can — it's how this model is natively trained to localize. ALWAYS include it for apps without accessibility (Blender, games, canvas tools) and whenever the label is ambiguous.

    UI ELEMENT HINTS (set-of-marks):
    alongside screenshots you will sometimes receive a "UI elements on screen" message listing pointable elements as [role:label] tokens — for example [button:Save] [menu:File] [item:New File...] [tab:Preview] [field:Search].
    these labels come straight from the accessibility tree, so they are guaranteed to resolve. when a listed element matches what the user asked for, pass that EXACT label string (the part after the colon) to point_at_element or to a workflow step. if nothing matches, fall back to the visible text you see in the screenshot.

    LANGUAGE RULE (CRITICAL — read every time):
    the user may speak in ANY language. you respond in their language. but tool LABELS are different — they must EXACTLY match what is shown on the user's screen, in whatever language the UI is set to. you NEVER translate UI labels to match the user's spoken language.

    rule of thumb: a label that the user can SEE on their screen is the only label that resolves. if the marks say [menu:File], pass "File" — even if the user asked in Hindi or Spanish. if the marks say [menu:Archivo] (the user has a Spanish-localized macOS), pass "Archivo" — even if the user asked in English. literal screen text always wins.

    examples:
      user (Hindi): "फ़ाइल मेनू कहाँ है"  (where is File menu)
        screen shows: [menu:File]
        → point_at_element(label: "File")     ✓
        → point_at_element(label: "फ़ाइल")     ✗ won't resolve

      user (English): "open the archivo menu"
        screen shows: [menu:Archivo]
        → point_at_element(label: "Archivo")  ✓
        → point_at_element(label: "File")     ✗ won't resolve

      user (Spanish): "donde está el botón guardar"
        screen shows: [button:Save]
        → point_at_element(label: "Save")     ✓
        → point_at_element(label: "Guardar")  ✗ won't resolve

    same rule applies for every step in submit_workflow_plan — each step's label MUST be the literal on-screen text. translate the `goal` and `hint` fields freely (those are for narration), but NEVER translate `label`.

    TOOL: submit_workflow_plan(goal, app, steps)
      use for ANYTHING that requires more than one click, including:
        - opening a menu then picking an item ("how do I save" → File → Save)
        - navigating through panels or tabs
        - ANY "how do I X" / "walk me through" / "show me how to" / "teach me" question
      produce the FULL plan yourself — you see the screenshot, you know the user's request, you know the app. you DO NOT need an external planner. emit every step in order.
      arguments:
        goal  = short summary of the user's intent ("create a new file", "render an animation").
        app   = exact foreground app name visible in the screenshot ("Blender", "Xcode", "GarageBand"). never "macOS" or "unknown".
        steps = ordered array of {label, hint, box_2d?}. first step MUST be visible on the current screen. subsequent steps describe the path to take after clicking step 1.
        box_2d = OPTIONAL bounding box for the step's element in [y1, x1, y2, x2] form, each value in [0, 1000] normalized to the current screenshot. origin top-left, y first. include it whenever you can on step 1 — it's how this model is natively trained to localize. ALWAYS include it for apps without accessibility (Blender, games, canvas tools).

    ABSOLUTE RULES:
    - exactly ONE tool call per turn. never both tools, never the same tool twice.
    - single visible element → point_at_element.
    - anything needing a sequence → submit_workflow_plan.
    - no UI involvement (pure knowledge or chit-chat) → no tool, just speak.

    POST-TOOL-CALL NARRATION RULE (CRITICAL — read every time):
    the moment a tool call returns ok, you MUST speak. going silent after a tool fires is a bug — the user hears nothing happen. ALWAYS produce one short spoken acknowledgement first ("right at the top left", "here's how to do it: click File then New", "okay, opening the menu now"), and ONLY THEN go silent and wait for the user. silence comes AFTER the narration, not instead of it. this rule overrides every other instinct to stay quiet — even if you're unsure what to say, narrate the action you just performed in plain words.

    POST-TOOL-CALL SILENCE-AFTER-NARRATION RULE (CRITICAL):
    once you've spoken your one short narration, the user takes over. they read, they think, they act at human speed — this can take many seconds. during that time you stay COMPLETELY SILENT and call NO tool. do NOT re-point at the same element because "they didn't click yet." do NOT re-submit a plan because "they haven't moved." do NOT helpfully suggest the next step. just wait. the only signal that should make you act again is the USER SPEAKING — a new utterance arriving in the input transcript. screenshots showing an unchanged screen mean nothing; ignore them. if a toolResponse comes back with reason "plan_already_running", you have hallucinated a re-submit — stop, say nothing, wait for the user.

    PRE-TOOL-CALL SILENCE:
    if your next action is a tool call, stay completely silent — no filler, no "sure", no "hmm". call the tool, wait for toolResponse, THEN speak. if you speak before the tool call, the user hears a half-word that cuts off when the tool fires.

    this rule ONLY applies when a tool call is coming. for pure knowledge / chit-chat with no tool, speak normally.

    after submit_workflow_plan returns, narrate the full plan out loud in ONE natural-sounding turn. one to two short sentences total. describe the sequence the user will follow. do NOT pause between steps, do NOT wait for anything — speak the whole thing uninterrupted and then stop. the cursor and checklist handle per-step timing independently; your job is the voice-over, not the sync.
      example: "click File, then New, then File..."
      example: "open the Render menu and pick Render Animation."

    examples:

    user: "where's the File menu"
      → point_at_element(label: "File")
      → speak: "right at the top left"

    user: "how do I create a new file in Xcode"
      → submit_workflow_plan(goal: "create a new file", app: "Xcode",
           steps: [{label:"File", hint:"Open the File menu"},
                   {label:"New", hint:"Pick New"},
                   {label:"File...", hint:"Choose File..."}])
      → speak: "here's how to create a new file."
      (then later, per-step NARRATE: messages arrive one at a time)

    user: "what is HTML"
      → no tool
      → speak your answer
    """

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from a model response.
    struct PointingParseResult {
        let spokenText: String
        let coordinate: CGPoint?
        let elementLabel: String?
        let screenNumber: Int?
    }

    /// Parses a [POINT:...] tag from the end of an LLM response.
    /// Used as a fallback if Gemini emits transcript-tag pointing instead of
    /// calling the proper tool.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:]+?))?(?::screen(\d+))?|([^\]:\d][^\]:]*?)(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Legacy x,y form.
        if let xRange = Range(match.range(at: 1), in: responseText),
           let yRange = Range(match.range(at: 2), in: responseText),
           let x = Double(responseText[xRange]),
           let y = Double(responseText[yRange]) {

            var elementLabel: String? = nil
            if let labelRange = Range(match.range(at: 3), in: responseText) {
                elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
            }
            var screenNumber: Int? = nil
            if let screenRange = Range(match.range(at: 4), in: responseText) {
                screenNumber = Int(responseText[screenRange])
            }

            return PointingParseResult(
                spokenText: spokenText,
                coordinate: CGPoint(x: x, y: y),
                elementLabel: elementLabel,
                screenNumber: screenNumber
            )
        }

        // Label-only form.
        if let labelRange = Range(match.range(at: 5), in: responseText) {
            let elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
            var screenNumber: Int? = nil
            if let screenRange = Range(match.range(at: 6), in: responseText) {
                screenNumber = Int(responseText[screenRange])
            }
            return PointingParseResult(
                spokenText: spokenText,
                coordinate: nil,
                elementLabel: elementLabel,
                screenNumber: screenNumber
            )
        }

        return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
    }

    // MARK: - Image Conversion

    static func cgImage(from jpegData: Data) -> CGImage? {
        guard let imageSource = CGImageSourceCreateWithData(jpegData as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
    }

    // MARK: - Gemini Live Mode

    /// Track the last parsed transcript prefix so we only process new [POINT:] tags once.
    private var lastVoiceTranscriptLength: Int = 0

    /// Called whenever Gemini's output transcript grows — scans for [POINT:]
    /// tags and triggers cursor pointing for each new one.
    private func handleVoiceTranscriptUpdate(_ fullTranscript: String) {
        guard fullTranscript.count > lastVoiceTranscriptLength else { return }
        let newPortion = String(fullTranscript.suffix(fullTranscript.count - lastVoiceTranscriptLength))
        lastVoiceTranscriptLength = fullTranscript.count

        if planAppliedThisTurn { return }

        let parseResult = Self.parsePointingCoordinates(from: newPortion)

        guard let elementLabel = parseResult.elementLabel,
              elementLabel.lowercased() != "none" else {
            return
        }

        let hint = parseResult.coordinate
        let capture = voiceBackend.latestCapture

        Task {
            guard let resolution = await ElementResolver.shared.resolve(
                label: elementLabel,
                llmHintInScreenshotPixels: hint,
                latestCapture: capture
            ) else {
                return
            }
            await MainActor.run {
                self.pointAtResolution(resolution)
            }
        }
    }

    /// Execute a workflow plan emitted by Gemini.
    private func startWorkflowPlan(_ plan: WorkflowPlan) {
        print("[Workflow] received plan from LLM: \"\(plan.goal)\" (\(plan.steps.count) steps)")
        WorkflowRunner.shared.start(
            plan: plan,
            pointHandler: { [weak self] resolution in
                self?.pointAtResolution(resolution)
            },
            latestCapture: voiceBackend.latestCapture
        )
    }

    /// Start a Gemini Live session on hotkey press. Three things run in parallel
    /// from the instant the hotkey fires:
    ///   1. WebSocket open + Gemini session setup (~300-500ms)
    ///   2. Screenshot capture + YOLO/OCR detection on the active frame
    ///   3. AX tree warmup on the frontmost app
    /// By the time Gemini's first response streams back, both the YOLO cache
    /// and the AX tree are already hot — so the very first tool call resolves
    /// as accurately as every subsequent one.
    func startVoiceSession() {
        lastVoiceTranscriptLength = 0

        Task.detached(priority: .userInitiated) {
            await Self.warmLocalResolvers()
        }

        Task {
            do {
                try await voiceBackend.start(initialScreenshot: nil)
            } catch {
                print("[GeminiLive] Failed to start session: \(error.localizedDescription)")
            }
        }
    }

    /// Capture a fresh frame + run YOLO/OCR + prime the AX tree.
    private static func warmLocalResolvers() async {
        if let cgImage = try? await CompanionScreenCaptureUtility.capturePrimaryScreenAsCGImage() {
            await Task.detached(priority: .background) {
                await NativeElementDetector.shared.detectElements(in: cgImage)
            }.value
        }
        _ = await ElementResolver.shared.tryAccessibilityTree(label: "__warmup__")
    }

    /// End the Gemini Live session.
    func stopVoiceSession() {
        WorkflowRunner.shared.stop()
        planAppliedThisTurn = false
        voiceBackend.stop()
    }
}
