//
//  CompanionManager.swift
//  TipTour
//
//  Central state manager for the Gemini Live voice companion. Owns the
//  push-to-talk hotkey, screen capture, Gemini Live session, tool handlers
//  for cursor pointing + multi-step workflows, and overlay management.
//

import ApplicationServices
import AVFoundation
import Combine
import CuaDriverCore
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

    /// Debug-only visual overlay for the restored native CoreML/Vision
    /// detector. This is deliberately not sent to Gemini yet.
    @Published var isDetectionOverlayEnabled: Bool = false
    @Published var detectionOverlayElements: [[String: Any]] = []
    @Published var detectionOverlayImageSize: [Int] = [1512, 982]
    @Published var detectionOverlayDisplayFrame: CGRect?
    @Published var detectionOverlayHighlightedLabel: String?

    /// Whether the blue cursor overlay is currently visible on screen.
    @Published private(set) var isOverlayVisible: Bool = false

    /// Freeform attention brush. Hold control + shift and move the mouse
    /// to paint the area the user means by "this area" / "this line".
    @Published private(set) var isFocusHighlightActive: Bool = false
    @Published private(set) var focusHighlightGlobalPoints: [CGPoint] = []
    @Published private(set) var lastFocusHighlightContext: FocusHighlightContext?
    private var currentFocusHighlightWindowContext: FocusHighlightWindowContext?
    private var lastHoverWindowContext: FocusHighlightWindowContext?
    private var lastHoverWindowContextDate: Date?
    private var lastHoverTextSelectionContext: FocusHighlightTextSelectionContext?

    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let globalHighlightShortcutMonitor = GlobalHighlightShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()

    /// Optional Cloudflare Worker proxy for distributed builds. Source
    /// builds intentionally do not hardcode the maintainer's Worker URL;
    /// builders should paste their own Gemini key in the panel instead.
    private static let workerBaseURL: String? = {
        let url = AppBundleConfiguration.stringValue(forKey: "TipTourWorkerBaseURL")
        ElementResolver.workerBaseURLOverride = url
        return url
    }()

    private var shortcutTransitionCancellable: AnyCancellable?
    private var highlightTransitionCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var voiceAudioPowerCancellable: AnyCancellable?
    private var voiceModelSpeakingCancellable: AnyCancellable?
    private var detectionOverlayTask: Task<Void, Never>?
    private var detectionOverlayScreenMonitorTask: Task<Void, Never>?
    private var detectionOverlayAppActivationObserver: NSObjectProtocol?
    private var detectionOverlayScreenParametersObserver: NSObjectProtocol?
    private var detectionOverlayClickObserver: NSObjectProtocol?
    private var lastDetectionOverlaySceneSignature: DetectionOverlaySceneSignature?

    private struct DetectionOverlaySceneSignature: Equatable {
        let screenFrame: CGRect?
        let topmostWindowID: Int?
        let topmostWindowProcessIdentifier: Int32?
        let topmostWindowBounds: WindowBounds?
    }

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
            apiKeyURL: Self.workerBaseURL.map { "\($0)/gemini-live-key" },
            systemPrompt: Self.companionVoiceResponseSystemPrompt
        )
        backend.setScreenshotStreamingEnabled(isScreenshotStreamingEnabled)
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
        backend.onInputTranscriptUpdate = { [weak self] fullInputTranscript in
            guard let self else { return }
            self.lastTranscript = fullInputTranscript
            let isNewUtterance = fullInputTranscript.trimmingCharacters(in: .whitespacesAndNewlines).count > 0
                && self.previousInputTranscriptLength == 0
            if isNewUtterance {
                self.handledToolCallIDsThisUtterance.removeAll()
                self.acceptedToolCallIDThisUtterance = nil
                if !self.sendLatestFocusHighlightContextToGeminiIfPossible() {
                    self.sendLatestHoverWindowContextToGeminiIfPossible()
                }
            }
            self.previousInputTranscriptLength = fullInputTranscript.count
        }
        backend.onTurnComplete = { [weak self] in
            self?.previousInputTranscriptLength = 0
            self?.lastTranscript = nil
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

    // MARK: - Gemini spatial hints → screenshot-pixel conversion

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
        guard let capture else { return nil }
        return pixelHintFromBox2D(
            box2DNormalized: box2DNormalized,
            imageSize: CGSize(
                width: capture.screenshotWidthInPixels,
                height: capture.screenshotHeightInPixels
            )
        )
    }

    private func pixelHintFromBox2D(
        box2DNormalized: [Int]?,
        imageSize: CGSize
    ) -> CGPoint? {
        guard let box = box2DNormalized, box.count == 4 else {
            return nil
        }
        let y1Norm = CGFloat(box[0])
        let x1Norm = CGFloat(box[1])
        let y2Norm = CGFloat(box[2])
        let x2Norm = CGFloat(box[3])

        let centerNormX = (x1Norm + x2Norm) / 2
        let centerNormY = (y1Norm + y2Norm) / 2

        let pixelX = centerNormX * imageSize.width / 1000
        let pixelY = centerNormY * imageSize.height / 1000
        return CGPoint(x: pixelX, y: pixelY)
    }

    /// Convert Gemini's optional `point_2d` click target (normalized [y, x])
    /// into screenshot-pixel space. We prefer this over the center of
    /// `box_2d` when present because dense UI can produce wide/merged boxes
    /// whose center is not the actual clickable target.
    private func pixelHintFromPoint2D(
        point2DNormalized: [Int]?,
        capture: CompanionScreenCapture?
    ) -> CGPoint? {
        guard let capture else { return nil }
        return pixelHintFromPoint2D(
            point2DNormalized: point2DNormalized,
            imageSize: CGSize(
                width: capture.screenshotWidthInPixels,
                height: capture.screenshotHeightInPixels
            )
        )
    }

    private func pixelHintFromPoint2D(
        point2DNormalized: [Int]?,
        imageSize: CGSize
    ) -> CGPoint? {
        guard let point = point2DNormalized, point.count == 2 else {
            return nil
        }

        let yNorm = CGFloat(point[0])
        let xNorm = CGFloat(point[1])

        let pixelX = xNorm * imageSize.width / 1000
        let pixelY = yNorm * imageSize.height / 1000
        return CGPoint(x: pixelX, y: pixelY)
    }

    private func normalizedWorkflowSteps(
        _ steps: [WorkflowStep],
        targetAppName: String
    ) -> [WorkflowStep] {
        coalescingConsecutiveTypeSteps(
            normalizingNewNoteSteps(steps, targetAppName: targetAppName)
        )
    }

    private func normalizingNewNoteSteps(
        _ steps: [WorkflowStep],
        targetAppName: String
    ) -> [WorkflowStep] {
        let normalizedAppName = targetAppName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedAppName == "notes" else { return steps }

        return steps.map { step in
            guard step.type == .click || step.type == .keyboardShortcut,
                  let label = step.label?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  label == "new note" else {
                return step
            }

            print("[Workflow] normalized Notes \"New Note\" click to Cmd+N")
            return WorkflowStep(
                id: step.id,
                type: .keyboardShortcut,
                label: "Cmd+N",
                value: step.value,
                direction: step.direction,
                amount: step.amount,
                by: step.by,
                targetContext: step.targetContext,
                hint: step.hint.isEmpty ? "Create a new note" : step.hint,
                hintX: nil,
                hintY: nil,
                box2DNormalized: nil,
                screenNumber: step.screenNumber
            )
        }
    }

    private func coalescingConsecutiveTypeSteps(_ steps: [WorkflowStep]) -> [WorkflowStep] {
        var normalizedSteps: [WorkflowStep] = []
        var currentIndex = 0

        while currentIndex < steps.count {
            let step = steps[currentIndex]
            guard step.type == .type else {
                normalizedSteps.append(step)
                currentIndex += 1
                continue
            }

            var textParts: [String] = []
            var lastTypeStep = step
            while currentIndex < steps.count, steps[currentIndex].type == .type {
                if let text = steps[currentIndex].value ?? steps[currentIndex].label, !text.isEmpty {
                    textParts.append(text)
                }
                lastTypeStep = steps[currentIndex]
                currentIndex += 1
            }

            guard !textParts.isEmpty else {
                normalizedSteps.append(step)
                continue
            }

            if textParts.count > 1 {
                print("[Workflow] coalesced \(textParts.count) consecutive type steps into one paste")
            }
            normalizedSteps.append(
                WorkflowStep(
                    id: step.id,
                    type: .type,
                    label: step.label,
                    value: textParts.joined(separator: "\n\n"),
                    direction: lastTypeStep.direction,
                    amount: lastTypeStep.amount,
                    by: lastTypeStep.by,
                    targetContext: step.targetContext ?? lastTypeStep.targetContext,
                    hint: step.hint.isEmpty ? lastTypeStep.hint : step.hint,
                    hintX: step.hintX,
                    hintY: step.hintY,
                    box2DNormalized: step.box2DNormalized,
                    screenNumber: step.screenNumber
                )
            )
        }

        return normalizedSteps
    }

    // MARK: - Tool Handlers

    private func rejectIfToolCallShouldNotRun(
        id: String,
        toolName: String
    ) -> [String: Any]? {
        if handledToolCallIDsThisUtterance.contains(id) {
            print("[Tool] ⏭️  ignoring duplicate \(toolName) id=\(id)")
            return ["ok": true, "duplicate": true]
        }

        if let acceptedToolCallIDThisUtterance {
            print("[Tool] ⏭️  rejecting \(toolName) id=\(id) — already accepted tool id=\(acceptedToolCallIDThisUtterance) for this utterance")
            handledToolCallIDsThisUtterance.insert(id)
            voiceBackend.invalidateScreenshotHashCache()
            return [
                "ok": false,
                "reason": "tool_already_handled_this_utterance",
                "message": "A tool call has already been accepted for this spoken request. Do not call another tool until the user speaks again."
            ]
        }

        handledToolCallIDsThisUtterance.insert(id)
        acceptedToolCallIDThisUtterance = id
        return nil
    }

    /// Legacy tool handler. The tool is no longer declared in Gemini's
    /// setup; keep this reject path for old/resumed sessions.
    @MainActor
    private func handleToolPointAtElement(
        id: String,
        label: String,
        box2DNormalized: [Int]?,
        screenshotJPEG: Data?
    ) async -> [String: Any] {
        handledToolCallIDsThisUtterance.insert(id)
        voiceBackend.invalidateScreenshotHashCache()
        print("[Tool] ⏭️  point_at_element disabled — rejected \"\(label)\"")
        return [
            "ok": false,
            "reason": "point_at_element_disabled",
            "message": "point_at_element is disabled. Use submit_workflow_plan for computer actions, or answer conversationally for visual explanations."
        ]
    }

    /// Handle the `submit_workflow_plan` tool call. Gemini produces the
    /// plan itself via its own vision + reasoning; this just converts the
    /// raw tool args into a WorkflowPlan and kicks off the runner.
    @MainActor
    private func handleToolSubmitWorkflowPlan(id: String, goal: String, app: String, steps: [[String: Any]]) async -> [String: Any] {
        if let rejection = rejectIfToolCallShouldNotRun(id: id, toolName: "submit_workflow_plan") {
            return rejection
        }

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

        let captureForBoxConversion = voiceBackend.latestCapture
        let parsedStepsBeforeNormalization: [WorkflowStep] = steps.enumerated().map { index, raw in
            let label = raw["label"] as? String
            let hint = raw["hint"] as? String ?? ""
            let type = WorkflowStep.StepType.normalized(from: raw["type"] as? String)

            // Prefer Gemini's exact point_2d when present. Fall back to
            // box_2d center so older sessions and box-only model outputs
            // keep working.
            let point2DNormalized = (raw["point_2d"] as? [Int]).flatMap { $0.count == 2 ? $0 : nil }
            let box2DNormalized = (raw["box_2d"] as? [Int]).flatMap { $0.count == 4 ? $0 : nil }
            let pixelCenter = pixelHintFromPoint2D(
                point2DNormalized: point2DNormalized,
                capture: captureForBoxConversion
            ) ?? pixelHintFromBox2D(
                box2DNormalized: box2DNormalized,
                capture: captureForBoxConversion
            ) ?? pixelHintFromPoint2D(
                point2DNormalized: point2DNormalized,
                imageSize: CGSize(width: detectionOverlayImageSize[0], height: detectionOverlayImageSize[1])
            ) ?? pixelHintFromBox2D(
                box2DNormalized: box2DNormalized,
                imageSize: CGSize(width: detectionOverlayImageSize[0], height: detectionOverlayImageSize[1])
            )
            let hintX = pixelCenter.map { Int($0.x) }
            let hintY = pixelCenter.map { Int($0.y) }

            return WorkflowStep(
                id: "step_\(index + 1)",
                type: type,
                label: label,
                value: raw["value"] as? String,
                direction: raw["direction"] as? String,
                amount: raw["amount"] as? Int,
                by: raw["by"] as? String,
                targetContext: WorkflowStep.TargetContext.normalized(
                    from: (raw["targetContext"] as? String) ?? (raw["target_context"] as? String)
                ),
                hint: hint,
                hintX: hintX,
                hintY: hintY,
                box2DNormalized: box2DNormalized,
                screenNumber: nil
            )
        }
        let normalizedSteps = normalizedWorkflowSteps(
            parsedStepsBeforeNormalization,
            targetAppName: app
        )

        guard !normalizedSteps.isEmpty else {
            print("[Tool] ✗ submit_workflow_plan — zero steps")
            return ["ok": false, "reason": "empty_steps"]
        }

        let parsedSteps = Array(normalizedSteps.prefix(1))
        if normalizedSteps.count > parsedSteps.count {
            print("[Tool] ✂️ single-action mode: ignoring \(normalizedSteps.count - parsedSteps.count) extra step(s)")
        }

        guard isAutopilotEnabled || isMultiStepTourGuideEnabled else {
            print("[Tool] ✗ submit_workflow_plan — tour guide disabled and Autopilot off")
            voiceBackend.invalidateScreenshotHashCache()
            return [
                "ok": false,
                "reason": "tour_guide_disabled",
                "message": "The step-by-step teaching tour guide is disabled. If the user wants action-taking, ask them to turn Autopilot on; otherwise answer conversationally without submitting a workflow plan."
            ]
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

        if isMultiStepTourGuideEnabled {
            // Pause mic + screenshots so Gemini can narrate the plan in one
            // uninterrupted turn. Once narration finishes, exit narration mode
            // — mic/screenshots resume but the WebSocket stays open.
            print("[Workflow] entering Gemini narration mode — mic/screenshots paused, socket kept alive for narration")
            voiceBackend.enterNarrationMode()
            scheduleExitNarrationModeAfterSpeechEnds()
        }

        return [
            "ok": true,
            "accepted_steps": stepLabels.count,
            "ignored_steps": max(0, normalizedSteps.count - parsedSteps.count),
            "tour_guide_enabled": isMultiStepTourGuideEnabled
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
            }
        }
    }

    /// Set of tool-call IDs we've already dispatched within the current
    /// user utterance. Reset when a new user utterance starts.
    private var handledToolCallIDsThisUtterance: Set<String> = []
    private var acceptedToolCallIDThisUtterance: String?

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
    /// (classic oneko sprites). Defaults OFF so the standard cursor
    /// remains the primary action-taking visual on new installs.
    @Published var isNekoModeEnabled: Bool = UserDefaults.standard.object(forKey: "isNekoModeEnabled") == nil
        ? false
        : UserDefaults.standard.bool(forKey: "isNekoModeEnabled")

    func setNekoModeEnabled(_ enabled: Bool) {
        isNekoModeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isNekoModeEnabled")
    }

    /// Autopilot mode: when enabled, TipTour CLICKS the resolved
    /// element instead of waiting for the user to click it. Single
    /// workflow plans drive themselves end-to-end. Actions must use a
    /// CUA workflow plan so they are token-gated and app-scoped.
    ///
    /// Defaults ON so TipTour can take actions by default. Persisted
    /// per-user so people can still switch back to teaching mode and
    /// keep that preference.
    ///
    /// Safety net: `WorkflowRunner` already pauses when the user
    /// Cmd-Tabs to an unrelated app, when a modal dialog appears, and
    /// when the post-click AX fingerprint didn't change. Pressing the
    /// hotkey closes the Gemini Live session and stops anything in
    /// flight. Autopilot rides those rails — it doesn't bypass them.
    @Published var isAutopilotEnabled: Bool = UserDefaults.standard.object(forKey: "isAutopilotEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isAutopilotEnabled")

    func setAutopilotEnabled(_ enabled: Bool) {
        isAutopilotEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isAutopilotEnabled")
    }

    /// Privacy mode for Gemini Live visual context. When enabled, TipTour
    /// sends screen JPEGs to Gemini. When disabled, Gemini still hears the
    /// user and can call tools, but it does not receive screenshots.
    @Published var isScreenshotStreamingEnabled: Bool = UserDefaults.standard.object(forKey: "isScreenshotStreamingEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isScreenshotStreamingEnabled")

    func setScreenshotStreamingEnabled(_ enabled: Bool) {
        isScreenshotStreamingEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isScreenshotStreamingEnabled")
        _voiceBackend?.setScreenshotStreamingEnabled(enabled)
    }

    /// Feature flag for the older teaching/tour-guide experience:
    /// visible checklist, step-by-step user-click guidance, and plan
    /// narration mode. Defaults OFF while action-taking is the primary
    /// path.
    @Published var isMultiStepTourGuideEnabled: Bool = UserDefaults.standard.object(forKey: "isMultiStepTourGuideEnabled") == nil
        ? false
        : UserDefaults.standard.bool(forKey: "isMultiStepTourGuideEnabled")

    func setMultiStepTourGuideEnabled(_ enabled: Bool) {
        isMultiStepTourGuideEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isMultiStepTourGuideEnabled")
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

        // Cap how long any AX query can hang waiting for a target app's
        // accessibility server. Default is 6 seconds, which freezes the
        // entire AX queue when a slow/unresponsive app is queried. 0.4s
        // is generous enough for healthy responses and aggressive enough
        // that a hung app fails fast and we move on to a fallback path.
        // Per-element timeouts in AccessibilityTreeResolver layer on top.
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.4)

        // Touch the lazy property so the backend is constructed and the
        // publishers are subscribed BEFORE the user opens the panel /
        // presses the hotkey.
        _ = voiceBackend
        bindShortcutTransitions()
        bindHighlightTransitions()
        beginTrackingUserTargetApp()
        ClickDetector.advanceOnAnyClickEnabled = advanceOnAnyClickEnabled

        // Wire the autopilot toggle into the workflow runner. The
        // runner reads this on every step to decide whether to fly the
        // cursor and wait (teaching) or fly the cursor and click
        // (autopilot).
        WorkflowRunner.shared.isAutopilotEnabledProvider = { [weak self] in
            self?.isAutopilotEnabled ?? false
        }

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
        stopNativeDetectionOverlay()
        globalPushToTalkShortcutMonitor.stop()
        globalHighlightShortcutMonitor.stop()
        overlayWindowManager.hideOverlay()
        shortcutTransitionCancellable?.cancel()
        highlightTransitionCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
        voiceAudioPowerCancellable?.cancel()
        voiceModelSpeakingCancellable?.cancel()
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    // MARK: - Native Detection Overlay

    func setDetectionOverlayEnabled(_ enabled: Bool) {
        isDetectionOverlayEnabled = enabled

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
            startNativeDetectionOverlay()
        } else {
            stopNativeDetectionOverlay()
        }
    }

    private func startNativeDetectionOverlay() {
        detectionOverlayTask?.cancel()
        detectionOverlayScreenMonitorTask?.cancel()
        lastDetectionOverlaySceneSignature = currentDetectionOverlaySceneSignature()

        installNativeDetectionOverlayObservers()
        scheduleNativeDetectionOverlayRefresh(reason: "enabled")
        startNativeDetectionOverlayScreenMonitor()
    }

    private func installNativeDetectionOverlayObservers() {
        if detectionOverlayAppActivationObserver == nil {
            detectionOverlayAppActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self else { return }
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                    return
                }
                guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
                self.scheduleNativeDetectionOverlayRefresh(reason: "app changed")
            }
        }

        if detectionOverlayScreenParametersObserver == nil {
            detectionOverlayScreenParametersObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleNativeDetectionOverlayRefresh(reason: "screen parameters changed")
            }
        }

        if detectionOverlayClickObserver == nil {
            detectionOverlayClickObserver = NotificationCenter.default.addObserver(
                forName: .tipTourUserInterfaceClickExecuted,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleNativeDetectionOverlayRefresh(
                    reason: "click changed UI",
                    debounceNanoseconds: 240_000_000
                )
            }
        }
    }

    private func startNativeDetectionOverlayScreenMonitor() {
        detectionOverlayScreenMonitorTask = Task { [weak self] in
            guard let self else { return }
            let screenCheckIntervalNanoseconds: UInt64 = 300_000_000

            while !Task.isCancelled {
                await MainActor.run {
                    guard self.isDetectionOverlayEnabled else { return }
                    let currentSignature = self.currentDetectionOverlaySceneSignature()
                    if self.lastDetectionOverlaySceneSignature != currentSignature {
                        self.lastDetectionOverlaySceneSignature = currentSignature
                        self.scheduleNativeDetectionOverlayRefresh(reason: "CUA visible window scene changed")
                    }
                }

                try? await Task.sleep(nanoseconds: screenCheckIntervalNanoseconds)
            }
        }
    }

    private func scheduleNativeDetectionOverlayRefresh(
        reason: String,
        debounceNanoseconds: UInt64 = 150_000_000
    ) {
        guard isDetectionOverlayEnabled else { return }

        detectionOverlayTask?.cancel()
        detectionOverlayTask = Task { [weak self] in
            if debounceNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: debounceNanoseconds)
            }
            guard !Task.isCancelled else { return }
            await self?.refreshNativeDetectionOverlay(reason: reason)
        }
    }

    private func refreshNativeDetectionOverlay(reason: String) async {
        do {
            let mouseLocation = NSEvent.mouseLocation
            let cursorScreen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
            let capturedImage = try await CompanionScreenCaptureUtility.capturePrimaryScreenAsCGImage()
            let detectedElements = await NativeElementDetector.shared.detectElements(in: capturedImage)
            let overlayElements = detectedElements.map { detectedElement in
                [
                    "bbox": [
                        Int(detectedElement.bbox.minX),
                        Int(detectedElement.bbox.minY),
                        Int(detectedElement.bbox.maxX),
                        Int(detectedElement.bbox.maxY)
                    ],
                    "center": [
                        Int(detectedElement.center.x),
                        Int(detectedElement.center.y)
                    ],
                    "conf": detectedElement.confidence,
                    "label": detectedElement.label,
                    "source": detectedElement.source
                ] as [String: Any]
            }

            guard isDetectionOverlayEnabled else { return }
            detectionOverlayElements = overlayElements
            detectionOverlayImageSize = [capturedImage.width, capturedImage.height]
            detectionOverlayDisplayFrame = cursorScreen?.frame
            if let displayFrame = cursorScreen?.frame {
                LocalPerceptionTargetCache.shared.update(
                    elements: overlayElements,
                    imageSize: CGSize(width: capturedImage.width, height: capturedImage.height),
                    displayFrame: displayFrame
                )
            }
            lastDetectionOverlaySceneSignature = currentDetectionOverlaySceneSignature()
            print("[NativeDetector] overlay refreshed — \(reason)")
        } catch {
            print("[NativeDetector] overlay capture failed: \(error.localizedDescription)")
        }
    }

    private func stopNativeDetectionOverlay() {
        detectionOverlayTask?.cancel()
        detectionOverlayTask = nil
        detectionOverlayScreenMonitorTask?.cancel()
        detectionOverlayScreenMonitorTask = nil
        if let detectionOverlayAppActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(detectionOverlayAppActivationObserver)
            self.detectionOverlayAppActivationObserver = nil
        }
        if let detectionOverlayScreenParametersObserver {
            NotificationCenter.default.removeObserver(detectionOverlayScreenParametersObserver)
            self.detectionOverlayScreenParametersObserver = nil
        }
        if let detectionOverlayClickObserver {
            NotificationCenter.default.removeObserver(detectionOverlayClickObserver)
            self.detectionOverlayClickObserver = nil
        }
        isDetectionOverlayEnabled = false
        detectionOverlayElements = []
        detectionOverlayDisplayFrame = nil
        detectionOverlayHighlightedLabel = nil
        LocalPerceptionTargetCache.shared.clear()
        lastDetectionOverlaySceneSignature = nil
    }

    private func currentDetectionOverlaySceneSignature() -> DetectionOverlaySceneSignature {
        let mouseLocation = NSEvent.mouseLocation
        let cursorScreen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main

        return DetectionOverlaySceneSignature(
            screenFrame: cursorScreen?.frame,
            topmostWindowID: nil,
            topmostWindowProcessIdentifier: nil,
            topmostWindowBounds: nil
        )
    }

    private static func topmostVisibleWindow(at globalAppKitPoint: CGPoint) -> WindowInfo? {
        let ownProcessIdentifier = NSRunningApplication.current.processIdentifier
        return WindowEnumerator.visibleWindows()
            .filter { $0.layer == 0 }
            .filter { $0.pid > 0 && $0.pid != ownProcessIdentifier }
            .filter { windowInfo in
                appKitFrame(from: windowInfo.bounds).contains(globalAppKitPoint)
            }
            .max(by: { $0.zIndex < $1.zIndex })
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
            globalHighlightShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
            globalHighlightShortcutMonitor.stop()
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

    private func bindHighlightTransitions() {
        highlightTransitionCancellable = globalHighlightShortcutMonitor
            .highlightTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleHighlightTransition(transition)
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
            Self.enableManualAccessibilityIfNeeded(for: current)
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
            Self.enableManualAccessibilityIfNeeded(for: app)
        }
    }

    /// Electron apps (Framer, VS Code, Slack, Discord, Cursor, Notion,
    /// Figma desktop, etc.) ship with their AX tree gated behind a special
    /// `AXManualAccessibility` flag — Electron PR #10305 added this to
    /// avoid the side effects of `AXEnhancedUserInterface` (which makes
    /// Chromium animate window resizes and breaks window managers like
    /// Magnet/Rectangle).
    ///
    /// Setting this attribute on an Electron app's *application* AX
    /// element (not the window) populates the entire web-page AX tree so
    /// our resolver can find buttons, menus, and inputs by label.
    /// Non-Electron apps return `kAXErrorAttributeUnsupported` — which is
    /// harmless; we just ignore it. The cost of setting it universally on
    /// every app activation is one cheap AX call.
    ///
    /// Without this, the AX walk in apps like Framer returns 0 candidates
    /// (`menuBarChildren=7, candidates=0` in logs), forcing a slow,
    /// less-accurate vision fallback. With it, Framer's tree is fully
    /// populated and resolution lands on the right element first try.
    private static func enableManualAccessibilityIfNeeded(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid > 0 else { return }
        let appElement = AXUIElementCreateApplication(pid)
        // Cap the messaging timeout per-app too, in case the target's AX
        // server is slow on first contact.
        AXUIElementSetMessagingTimeout(appElement, 0.4)
        let attributeName = "AXManualAccessibility" as CFString
        let result = AXUIElementSetAttributeValue(appElement, attributeName, kCFBooleanTrue)
        switch result {
        case .success:
            print("[AX] enabled AXManualAccessibility for \(app.bundleIdentifier ?? "?") (\(app.localizedName ?? "?"))")
        case .attributeUnsupported, .actionUnsupported:
            // Non-Electron app — expected.
            break
        case .cannotComplete, .notImplemented:
            // App not ready / sandboxed — expected for some launchers.
            break
        default:
            // Anything else is unusual but non-fatal; log for diagnosis.
            print("[AX] AXManualAccessibility set returned \(result.rawValue) for \(app.bundleIdentifier ?? "?")")
        }
    }

    private func handleShortcutTransition(_ transition: PushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            // Snapshot the user's real frontmost app BEFORE opening the
            // menu bar panel or cursor overlay. Once TipTour shows any UI
            // macOS may flip frontmost to us, so this is the only reliable
            // moment to capture which app the user was actually looking at.
            let hoverWindowContext = Self.windowContext(at: NSEvent.mouseLocation)
            if let hoverWindowContext {
                lastHoverWindowContext = hoverWindowContext
                lastHoverWindowContextDate = Date()
                lastHoverTextSelectionContext = Self.textSelectionContext(for: hoverWindowContext)
                updateTargetAppOverride(for: hoverWindowContext)
                print("[Target] user's app under mouse at hotkey press: \(hoverWindowContext.bundleIdentifier ?? "?") (\(hoverWindowContext.appName))")
            } else if let frontmost = NSWorkspace.shared.frontmostApplication,
               frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
                AccessibilityTreeResolver.userTargetAppOverride = frontmost
                print("[Target] user's app at hotkey press: \(frontmost.bundleIdentifier ?? "?") (\(frontmost.localizedName ?? "?"))")
            }

            NotificationCenter.default.post(name: .tipTourDismissPanel, object: nil)
            clearDetectedElementLocation()
            WorkflowRunner.shared.stop()

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

    private func handleHighlightTransition(_ transition: GlobalHighlightShortcutMonitor.HighlightTransition) {
        switch transition {
        case .began(let globalPoint):
            beginFocusHighlight(at: globalPoint)
        case .moved(let globalPoint):
            appendFocusHighlightPoint(globalPoint)
        case .ended:
            commitFocusHighlight()
        }
    }

    private func beginFocusHighlight(at globalPoint: CGPoint) {
        isFocusHighlightActive = true
        focusHighlightGlobalPoints = [globalPoint]
        currentFocusHighlightWindowContext = Self.windowContext(at: globalPoint)
        updateTargetAppOverrideForFocusHighlightWindow()
        lastFocusHighlightContext = nil

        if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    private func appendFocusHighlightPoint(_ globalPoint: CGPoint) {
        guard isFocusHighlightActive else { return }

        if let lastPoint = focusHighlightGlobalPoints.last {
            let distance = hypot(globalPoint.x - lastPoint.x, globalPoint.y - lastPoint.y)
            guard distance >= 3 else { return }
        }

        focusHighlightGlobalPoints.append(globalPoint)
        currentFocusHighlightWindowContext = Self.windowContext(at: globalPoint)
            ?? currentFocusHighlightWindowContext
        updateTargetAppOverrideForFocusHighlightWindow()
    }

    private func commitFocusHighlight() {
        guard isFocusHighlightActive else { return }
        isFocusHighlightActive = false

        let highlightedBoundingRect = Self.boundingRect(for: focusHighlightGlobalPoints)
        let highlightedWindowContext = Self.windowContext(
            intersecting: highlightedBoundingRect,
            paintedPoints: focusHighlightGlobalPoints
        ) ?? currentFocusHighlightWindowContext
        currentFocusHighlightWindowContext = highlightedWindowContext
        updateTargetAppOverrideForFocusHighlightWindow()

        guard let context = FocusHighlightContext(
            points: focusHighlightGlobalPoints,
            hoveredWindow: highlightedWindowContext,
            intersectedElement: Self.elementContext(
                in: highlightedWindowContext,
                intersecting: highlightedBoundingRect,
                paintedPoints: focusHighlightGlobalPoints
            ),
            textSelection: Self.textSelectionContext(
                for: highlightedWindowContext,
                intersecting: highlightedBoundingRect,
                paintedPoints: focusHighlightGlobalPoints
            )
        ) else {
            focusHighlightGlobalPoints = []
            lastFocusHighlightContext = nil
            currentFocusHighlightWindowContext = nil
            return
        }

        lastFocusHighlightContext = context
        if let highlightedWindowContext = context.hoveredWindow {
            let elementRole = context.intersectedElement?.role ?? "none"
            print("[FocusHighlight] committed in app=\(highlightedWindowContext.appName) pid=\(highlightedWindowContext.processIdentifier) window_id=\(highlightedWindowContext.windowID.map(String.init) ?? "?") element=\(elementRole)")
        }
        focusHighlightGlobalPoints = []
        currentFocusHighlightWindowContext = nil
        sendLatestFocusHighlightContextToGeminiIfPossible()
    }

    private func updateTargetAppOverrideForFocusHighlightWindow() {
        updateTargetAppOverride(for: currentFocusHighlightWindowContext)
    }

    private func updateTargetAppOverride(for windowContext: FocusHighlightWindowContext?) {
        guard let processIdentifier = windowContext?.processIdentifier,
              let runningApplication = NSRunningApplication(processIdentifier: processIdentifier),
              runningApplication.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return
        }
        AccessibilityTreeResolver.userTargetAppOverride = runningApplication
        Self.enableManualAccessibilityIfNeeded(for: runningApplication)
    }

    @discardableResult
    private func sendLatestFocusHighlightContextToGeminiIfPossible() -> Bool {
        guard voiceBackend.isActive,
              let context = lastFocusHighlightContext else {
            return false
        }

        voiceBackend.sendText(focusHighlightContextPrompt(context))
        voiceBackend.invalidateScreenshotHashCache()
        return true
    }

    private func sendLatestHoverWindowContextToGeminiIfPossible() {
        guard voiceBackend.isActive,
              let hoverWindowContext = lastHoverWindowContext else {
            return
        }

        voiceBackend.sendText(hoverWindowContextPrompt(hoverWindowContext))
        voiceBackend.invalidateScreenshotHashCache()
    }

    private func focusHighlightContextPrompt(_ context: FocusHighlightContext) -> String {
        let rect = context.globalAppKitBoundingRect
        var lines = [
            "user focus highlight context:",
            "the user just painted a freeform highlight region. treat phrases like \"this\", \"this area\", \"this line\", \"that text\", \"rewrite this\", or \"change this\" as referring to this highlighted region.",
            "global appkit rect: x=\(Int(rect.minX)), y=\(Int(rect.minY)), width=\(Int(rect.width)), height=\(Int(rect.height))."
        ]

        if let lastPaintedPoint = context.globalAppKitPoints.last {
            lines.append("current hover / last painted point: x=\(Int(lastPaintedPoint.x)), y=\(Int(lastPaintedPoint.y)).")
        }

        if let hoveredWindow = context.hoveredWindow {
            lines.append("hovered app/window target: app=\"\(hoveredWindow.appName)\", bundle_id=\"\(hoveredWindow.bundleIdentifier ?? "unknown")\", pid=\(hoveredWindow.processIdentifier), window_title=\"\(hoveredWindow.windowTitle ?? "")\", window_rect x=\(Int(hoveredWindow.globalAppKitFrame.minX)), y=\(Int(hoveredWindow.globalAppKitFrame.minY)), width=\(Int(hoveredWindow.globalAppKitFrame.width)), height=\(Int(hoveredWindow.globalAppKitFrame.height)).")
            lines.append("for this request, keep actions inside that hovered app/window unless the user explicitly asks to switch apps.")
        }

        if let textSelection = context.textSelection {
            lines.append("highlight-resolved text target: selected_text=\"\(Self.promptEscapedText(textSelection.selectedText, maxLength: 900))\", source=\"\(textSelection.source)\", focused_role=\"\(textSelection.focusedElementRole ?? "unknown")\", selected_range_location=\(textSelection.selectedTextRangeLocation.map(String.init) ?? "unknown"), selected_range_length=\(textSelection.selectedTextRangeLength.map(String.init) ?? "unknown").")
            lines.append("critical highlighted-text rule: if the user asks to replace, rewrite, delete, format, or otherwise edit this highlighted text, preserve this exact range. do not click the selected words first because that can collapse or move the insertion point. use a direct type, pressKey, keyboardShortcut, setValue, or app menu action against the already-focused selection. for a one-word change, type only the replacement word, not the surrounding paragraph.")
        }

        if let intersectedElement = context.intersectedElement {
            var elementLine = "highlight-intersected accessibility element: role=\"\(intersectedElement.role ?? "unknown")\""
            if let title = intersectedElement.title, !title.isEmpty {
                elementLine += ", title=\"\(Self.promptEscapedText(title, maxLength: 180))\""
            }
            if let value = intersectedElement.value, !value.isEmpty {
                elementLine += ", element_value_context=\"\(Self.promptEscapedText(value, maxLength: 500))\""
            }
            if let description = intersectedElement.description, !description.isEmpty {
                elementLine += ", description=\"\(Self.promptEscapedText(description, maxLength: 180))\""
            }
            if let frame = intersectedElement.globalAppKitFrame {
                elementLine += ", element_rect x=\(Int(frame.minX)), y=\(Int(frame.minY)), width=\(Int(frame.width)), height=\(Int(frame.height))"
            }
            lines.append(elementLine + ".")
            lines.append("prefer this intersected element over any stale focused element when deciding what text area or control the highlight refers to. element_value_context may be the whole text field or note, so never type it back as the replacement unless the user explicitly asks to replace the whole field.")
        }

        if let capture = voiceBackend.latestCapture,
           let screenshotRectDescription = screenshotRectDescription(for: context, capture: capture) {
            lines.append(screenshotRectDescription)
        }

        lines.append("when editing, prefer the accessibility element or text field intersecting this region; choose exactly one next action, such as clicking inside the region or typing into an already focused/highlighted range.")
        return lines.joined(separator: "\n")
    }

    private func hoverWindowContextPrompt(_ hoverWindowContext: FocusHighlightWindowContext) -> String {
        var lines = [
            "current hover app/window context:",
            "the user's pointer was over app=\"\(hoverWindowContext.appName)\", bundle_id=\"\(hoverWindowContext.bundleIdentifier ?? "unknown")\", pid=\(hoverWindowContext.processIdentifier), window_title=\"\(hoverWindowContext.windowTitle ?? "")\" when they started speaking.",
            "treat this as the target app/window for this request unless the user explicitly asks to switch apps."
        ]

        if let textSelection = lastHoverTextSelectionContext {
            lines.append("active text selection in that app: selected_text=\"\(Self.promptEscapedText(textSelection.selectedText, maxLength: 900))\", source=\"\(textSelection.source)\", focused_role=\"\(textSelection.focusedElementRole ?? "unknown")\", selected_range_location=\(textSelection.selectedTextRangeLocation.map(String.init) ?? "unknown"), selected_range_length=\(textSelection.selectedTextRangeLength.map(String.init) ?? "unknown").")
            lines.append("critical selected-text rule: if the user asks to replace, rewrite, delete, format, or otherwise edit the selected text, preserve the existing selection. do not click the selected words first because that can collapse the selection. use a direct type, pressKey, keyboardShortcut, setValue, or app menu action against the already-focused selection. for a one-word change, type only the replacement word, not the surrounding paragraph.")
        }

        return lines.joined(separator: "\n")
    }

    private func screenshotRectDescription(
        for context: FocusHighlightContext,
        capture: CompanionScreenCapture
    ) -> String? {
        let intersection = context.globalAppKitBoundingRect.intersection(capture.displayFrame)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
            return nil
        }

        let xScale = CGFloat(capture.screenshotWidthInPixels) / CGFloat(capture.displayWidthInPoints)
        let yScale = CGFloat(capture.screenshotHeightInPixels) / CGFloat(capture.displayHeightInPoints)

        let localMinX = intersection.minX - capture.displayFrame.minX
        let localMaxX = intersection.maxX - capture.displayFrame.minX
        let localTopY = capture.displayFrame.maxY - intersection.maxY
        let localBottomY = capture.displayFrame.maxY - intersection.minY

        let pixelMinX = Int(localMinX * xScale)
        let pixelMaxX = Int(localMaxX * xScale)
        let pixelTopY = Int(localTopY * yScale)
        let pixelBottomY = Int(localBottomY * yScale)

        let normalizedY1 = Int((CGFloat(pixelTopY) / CGFloat(capture.screenshotHeightInPixels)) * 1000)
        let normalizedX1 = Int((CGFloat(pixelMinX) / CGFloat(capture.screenshotWidthInPixels)) * 1000)
        let normalizedY2 = Int((CGFloat(pixelBottomY) / CGFloat(capture.screenshotHeightInPixels)) * 1000)
        let normalizedX2 = Int((CGFloat(pixelMaxX) / CGFloat(capture.screenshotWidthInPixels)) * 1000)

        return "relative to the latest screenshot labeled \"\(capture.label)\": pixel rect x=\(pixelMinX), y=\(pixelTopY), width=\(pixelMaxX - pixelMinX), height=\(pixelBottomY - pixelTopY); normalized box_2d=[\(normalizedY1), \(normalizedX1), \(normalizedY2), \(normalizedX2)]."
    }

    private static func windowContext(at globalAppKitPoint: CGPoint) -> FocusHighlightWindowContext? {
        let ownProcessIdentifier = NSRunningApplication.current.processIdentifier
        return WindowEnumerator.visibleWindows()
            .filter { $0.layer == 0 }
            .filter { $0.pid > 0 && $0.pid != ownProcessIdentifier }
            .filter { windowInfo in
                let frame = appKitFrame(from: windowInfo.bounds)
                return frame.contains(globalAppKitPoint)
            }
            .max(by: { $0.zIndex < $1.zIndex })
            .map(windowContext(from:))
    }

    private static func windowContext(
        intersecting highlightedBoundingRect: CGRect,
        paintedPoints: [CGPoint]
    ) -> FocusHighlightWindowContext? {
        guard !highlightedBoundingRect.isNull else { return nil }

        let ownProcessIdentifier = NSRunningApplication.current.processIdentifier
        return WindowEnumerator.visibleWindows()
            .filter { $0.layer == 0 }
            .filter { $0.pid > 0 && $0.pid != ownProcessIdentifier }
            .compactMap { windowInfo -> (windowInfo: WindowInfo, score: CGFloat)? in
                let frame = appKitFrame(from: windowInfo.bounds)
                let intersection = frame.intersection(highlightedBoundingRect)
                let pointsInsideCount = paintedPoints.filter { frame.contains($0) }.count
                guard !intersection.isNull || pointsInsideCount > 0 else { return nil }

                let intersectionArea = max(0, intersection.width) * max(0, intersection.height)
                let pointScore = CGFloat(pointsInsideCount) * 10_000
                let zScore = CGFloat(windowInfo.zIndex)
                return (windowInfo, pointScore + intersectionArea + zScore)
            }
            .max(by: { $0.score < $1.score })
            .map { windowContext(from: $0.windowInfo) }
    }

    private static func textSelectionContext(
        for windowContext: FocusHighlightWindowContext?,
        intersecting highlightedBoundingRect: CGRect? = nil,
        paintedPoints: [CGPoint] = []
    ) -> FocusHighlightTextSelectionContext? {
        guard let processIdentifier = windowContext?.processIdentifier else { return nil }

        let axApp = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.2)

        var focusedElementRef: AnyObject?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedElementRef) == .success,
           let focusedElementRef {
            let focusedElement = focusedElementRef as! AXUIElement

            if highlightedBoundingRect == nil
                || globalAppKitFrame(of: focusedElement)?.insetBy(dx: -12, dy: -12).intersects(highlightedBoundingRect!) == true {
                var selectedTextRef: AnyObject?
                if AXUIElementCopyAttributeValue(focusedElement, "AXSelectedText" as CFString, &selectedTextRef) == .success,
                   let selectedText = selectedTextRef as? String {
                    let trimmedSelectedText = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedSelectedText.isEmpty {
                        var roleRef: AnyObject?
                        AXUIElementCopyAttributeValue(focusedElement, kAXRoleAttribute as CFString, &roleRef)

                        var selectedRangeLocation: Int?
                        var selectedRangeLength: Int?
                        var selectedRangeRef: AnyObject?
                        if AXUIElementCopyAttributeValue(focusedElement, "AXSelectedTextRange" as CFString, &selectedRangeRef) == .success,
                           let selectedRangeValue = selectedRangeRef,
                           CFGetTypeID(selectedRangeValue) == AXValueGetTypeID() {
                            var selectedRange = CFRange()
                            if AXValueGetValue(selectedRangeValue as! AXValue, .cfRange, &selectedRange) {
                                selectedRangeLocation = selectedRange.location
                                selectedRangeLength = selectedRange.length
                            }
                        }

                        return FocusHighlightTextSelectionContext(
                            selectedText: trimmedSelectedText,
                            focusedElementRole: roleRef as? String,
                            selectedTextRangeLocation: selectedRangeLocation,
                            selectedTextRangeLength: selectedRangeLength,
                            source: "system_selection"
                        )
                    }
                }
            }
        }

        guard let highlightedBoundingRect else { return nil }
        return highlightedTextRangeContext(
            in: windowContext,
            intersecting: highlightedBoundingRect,
            paintedPoints: paintedPoints
        )
    }

    private static func highlightedTextRangeContext(
        in windowContext: FocusHighlightWindowContext?,
        intersecting highlightedBoundingRect: CGRect,
        paintedPoints: [CGPoint]
    ) -> FocusHighlightTextSelectionContext? {
        guard let processIdentifier = windowContext?.processIdentifier else { return nil }

        let candidatePoints = sampledHighlightPoints(
            boundingRect: highlightedBoundingRect,
            paintedPoints: paintedPoints
        )

        var resolvedFullText: String?
        var resolvedRole: String?
        var resolvedRange: CFRange?

        for appKitPoint in candidatePoints {
            do {
                let element = try AXInput.elementAt(appKitPointToCoreGraphicsPoint(appKitPoint))
                var elementProcessIdentifier: pid_t = 0
                AXUIElementGetPid(element, &elementProcessIdentifier)
                guard elementProcessIdentifier == processIdentifier else { continue }
                guard let fullText = AXInput.stringAttribute("AXValue", of: element),
                      !fullText.isEmpty else { continue }

                var screenPoint = appKitPointToCoreGraphicsPoint(appKitPoint)
                guard let screenPointValue = AXValueCreate(.cgPoint, &screenPoint) else { continue }

                var rawRangeRef: CFTypeRef?
                let result = AXUIElementCopyParameterizedAttributeValue(
                    element,
                    "AXRangeForPosition" as CFString,
                    screenPointValue,
                    &rawRangeRef
                )
                guard result == .success,
                      let rawRangeValue = rawRangeRef,
                      CFGetTypeID(rawRangeValue) == AXValueGetTypeID() else {
                    continue
                }

                var rawRange = CFRange()
                guard AXValueGetValue(rawRangeValue as! AXValue, .cfRange, &rawRange),
                      let wordRange = expandedWordRange(around: rawRange, in: fullText) else {
                    continue
                }

                if resolvedFullText == nil {
                    resolvedFullText = fullText
                    resolvedRole = AXInput.stringAttribute("AXRole", of: element)
                    resolvedRange = wordRange
                } else if resolvedFullText == fullText,
                          let currentRange = resolvedRange {
                    let unionStart = min(currentRange.location, wordRange.location)
                    let unionEnd = max(
                        currentRange.location + currentRange.length,
                        wordRange.location + wordRange.length
                    )
                    resolvedRange = CFRange(location: unionStart, length: unionEnd - unionStart)
                }
            } catch {
                continue
            }
        }

        guard let resolvedFullText,
              let resolvedRange else {
            return nil
        }

        let nsText = resolvedFullText as NSString
        let selectedText = nsText
            .substring(with: NSRange(location: resolvedRange.location, length: resolvedRange.length))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedText.isEmpty else { return nil }

        return FocusHighlightTextSelectionContext(
            selectedText: selectedText,
            focusedElementRole: resolvedRole,
            selectedTextRangeLocation: resolvedRange.location,
            selectedTextRangeLength: resolvedRange.length,
            source: "painted_highlight"
        )
    }

    private static func expandedWordRange(around rawRange: CFRange, in text: String) -> CFRange? {
        let nsText = text as NSString
        let textLength = nsText.length
        guard textLength > 0 else { return nil }

        let rawLocation = min(max(rawRange.location, 0), textLength - 1)
        var candidateIndex = rawLocation

        let wordCharacterSet = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "'’_-"))

        func isWordCharacter(at utf16Index: Int) -> Bool {
            guard utf16Index >= 0, utf16Index < textLength,
                  let scalar = UnicodeScalar(Int(nsText.character(at: utf16Index))) else {
                return false
            }
            return wordCharacterSet.contains(scalar)
        }

        if !isWordCharacter(at: candidateIndex) {
            if candidateIndex > 0, isWordCharacter(at: candidateIndex - 1) {
                candidateIndex -= 1
            } else {
                var nearbyWordIndex: Int?
                for offset in 1...24 {
                    let rightIndex = candidateIndex + offset
                    if rightIndex < textLength, isWordCharacter(at: rightIndex) {
                        nearbyWordIndex = rightIndex
                        break
                    }

                    let leftIndex = candidateIndex - offset
                    if leftIndex >= 0, isWordCharacter(at: leftIndex) {
                        nearbyWordIndex = leftIndex
                        break
                    }
                }

                guard let nearbyWordIndex else { return nil }
                candidateIndex = nearbyWordIndex
            }
        }

        var startIndex = candidateIndex
        while startIndex > 0, isWordCharacter(at: startIndex - 1) {
            startIndex -= 1
        }

        var endIndex = candidateIndex + 1
        while endIndex < textLength, isWordCharacter(at: endIndex) {
            endIndex += 1
        }

        guard endIndex > startIndex else { return nil }
        return CFRange(location: startIndex, length: endIndex - startIndex)
    }

    private static func elementContext(
        in windowContext: FocusHighlightWindowContext?,
        intersecting highlightedBoundingRect: CGRect,
        paintedPoints: [CGPoint]
    ) -> FocusHighlightElementContext? {
        guard let processIdentifier = windowContext?.processIdentifier else { return nil }

        let candidatePoints = sampledHighlightPoints(
            boundingRect: highlightedBoundingRect,
            paintedPoints: paintedPoints
        )

        for appKitPoint in candidatePoints {
            do {
                let element = try AXInput.elementAt(appKitPointToCoreGraphicsPoint(appKitPoint))
                var elementProcessIdentifier: pid_t = 0
                AXUIElementGetPid(element, &elementProcessIdentifier)
                guard elementProcessIdentifier == processIdentifier else { continue }

                return FocusHighlightElementContext(
                    role: AXInput.stringAttribute("AXRole", of: element),
                    title: AXInput.stringAttribute("AXTitle", of: element),
                    value: AXInput.stringAttribute("AXValue", of: element),
                    description: AXInput.stringAttribute("AXDescription", of: element),
                    globalAppKitFrame: globalAppKitFrame(of: element)
                )
            } catch {
                continue
            }
        }

        return nil
    }

    private static func sampledHighlightPoints(
        boundingRect: CGRect,
        paintedPoints: [CGPoint]
    ) -> [CGPoint] {
        var points: [CGPoint] = []

        if let lastPoint = paintedPoints.last {
            points.append(lastPoint)
        }
        points.append(CGPoint(x: boundingRect.midX, y: boundingRect.midY))
        points.append(CGPoint(x: boundingRect.minX + boundingRect.width * 0.25, y: boundingRect.midY))
        points.append(CGPoint(x: boundingRect.minX + boundingRect.width * 0.75, y: boundingRect.midY))
        points.append(CGPoint(x: boundingRect.midX, y: boundingRect.minY + boundingRect.height * 0.25))
        points.append(CGPoint(x: boundingRect.midX, y: boundingRect.minY + boundingRect.height * 0.75))
        points.append(contentsOf: paintedPoints.suffix(6))

        var seen = Set<String>()
        return points.filter { point in
            let key = "\(Int(point.x)):\(Int(point.y))"
            return seen.insert(key).inserted
        }
    }

    private static func globalAppKitFrame(of element: AXUIElement) -> CGRect? {
        guard let screenRect = AXInput.screenBoundingRect(of: element) else { return nil }
        return coreGraphicsRectToAppKitRect(screenRect)
    }

    private static func boundingRect(for points: [CGPoint]) -> CGRect {
        points.reduce(CGRect.null) { partialRect, point in
            partialRect.union(CGRect(origin: point, size: .zero))
        }.insetBy(dx: -12, dy: -12)
    }

    private static func windowContext(from windowInfo: WindowInfo) -> FocusHighlightWindowContext {
        let processIdentifier = pid_t(windowInfo.pid)
        let runningApplication = NSRunningApplication(processIdentifier: processIdentifier)
        return FocusHighlightWindowContext(
            windowID: windowInfo.id,
            appName: runningApplication?.localizedName ?? windowInfo.owner,
            bundleIdentifier: runningApplication?.bundleIdentifier,
            processIdentifier: processIdentifier,
            windowTitle: windowInfo.name,
            globalAppKitFrame: appKitFrame(from: windowInfo.bounds)
        )
    }

    private static func appKitFrame(from windowBounds: WindowBounds) -> CGRect {
        coreGraphicsRectToAppKitRect(
            CGRect(
                x: windowBounds.x,
                y: windowBounds.y,
                width: windowBounds.width,
                height: windowBounds.height
            )
        )
    }

    private static func promptEscapedText(_ text: String, maxLength: Int) -> String {
        let clippedText = text.count > maxLength ? "\(text.prefix(maxLength))..." : text
        return clippedText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func appKitPointToCoreGraphicsPoint(_ appKitPoint: CGPoint) -> CGPoint {
        let primaryScreen = NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let primaryScreen else { return appKitPoint }
        return CGPoint(
            x: appKitPoint.x,
            y: primaryScreen.frame.height - appKitPoint.y
        )
    }

    private static func coreGraphicsRectToAppKitRect(_ coreGraphicsRect: CGRect) -> CGRect {
        let primaryScreen = NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let primaryScreen else { return coreGraphicsRect }
        return CGRect(
            x: coreGraphicsRect.minX,
            y: primaryScreen.frame.height - coreGraphicsRect.maxY,
            width: coreGraphicsRect.width,
            height: coreGraphicsRect.height
        )
    }

    /// Fly the cursor to a resolved element. The Resolution already contains
    /// global AppKit coordinates — no further conversion needed.
    private func pointAtResolution(_ resolution: ElementResolver.Resolution) {
        detectedElementScreenLocation = resolution.globalScreenPoint
        detectedElementDisplayFrame = resolution.displayFrame
        detectedElementBubbleText = resolution.label
    }

    // MARK: - Companion Prompt

    private static var companionVoiceResponseSystemPrompt: String {
        """
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

    computer control via tools (VERY IMPORTANT — read carefully):

    you have exactly ONE tool: submit_workflow_plan. call AT MOST ONE tool per turn. do NOT narrate before the tool call. call it silently, wait for the response, THEN speak ONCE.

    \(Self.multiStepTourGuidePromptRule)

    UI ELEMENT HINTS (set-of-marks):
    alongside screenshots you will sometimes receive a "UI elements on screen" message listing pointable elements as [role:label] tokens — for example [button:Save] [menu:File] [item:New File...] [tab:Preview] [field:Search].
    these labels come straight from the accessibility tree, so they are guaranteed to resolve. when a listed element matches what the user asked for, pass that EXACT label string (the part after the colon) to a workflow step. if nothing matches, fall back to the visible text you see in the screenshot.

    FOCUS HIGHLIGHT CONTEXT:
    the user can hold control plus shift and paint a freeform highlight over part of the screen. when they do, you receive a "user focus highlight context" message with a global rect, a current hover / last painted point, the hovered app/window target, and usually a normalized box_2d for the latest screenshot. treat phrases like "this", "that line", "this area", "rewrite this", "change this", "make this better", or "update the highlighted part" as referring to that highlighted region inside that hovered app/window. prefer visible elements, text fields, and text ranges that intersect the highlighted region. when an action should operate on that highlighted region, set targetContext:"currentHighlight" on the action step. when it should operate on a normal native selection, set targetContext:"currentSelection". when it should operate on the currently focused field, set targetContext:"focusedElement". do not type into some other app unless the user explicitly asks to switch apps.

    LANGUAGE RULE (CRITICAL — read every time):
    the user may speak in ANY language. you respond in their language. but tool LABELS are different — they must EXACTLY match what is shown on the user's screen, in whatever language the UI is set to. you NEVER translate UI labels to match the user's spoken language.

    rule of thumb: a label that the user can SEE on their screen is the only label that resolves. if the marks say [menu:File], pass "File" — even if the user asked in Hindi or Spanish. if the marks say [menu:Archivo] (the user has a Spanish-localized macOS), pass "Archivo" — even if the user asked in English. literal screen text always wins.

    examples:
      user (Hindi): "फ़ाइल मेनू कहाँ है"  (where is File menu)
        screen shows: [menu:File]
        → submit_workflow_plan(... steps: [{type:"observe", label:"File"}])     ✓
        → submit_workflow_plan(... steps: [{type:"observe", label:"फ़ाइल"}])     ✗ won't resolve

      user (English): "open the archivo menu"
        screen shows: [menu:Archivo]
        → submit_workflow_plan(... steps: [{type:"click", label:"Archivo"}])  ✓
        → submit_workflow_plan(... steps: [{type:"click", label:"File"}])     ✗ won't resolve

      user (Spanish): "donde está el botón guardar"
        screen shows: [button:Save]
        → submit_workflow_plan(... steps: [{type:"observe", label:"Save"}])     ✓
        → submit_workflow_plan(... steps: [{type:"observe", label:"Guardar"}])  ✗ won't resolve

    same rule applies for every step in submit_workflow_plan — each step's label MUST be the literal on-screen text. translate the `goal` and `hint` fields freely (those are for narration), but NEVER translate `label`.

    TOOL: submit_workflow_plan(goal, app, steps)
      use for ANY computer action. open one app, open one URL, click one button/menu/item, press one shortcut, type text into the focused/highlighted target, scroll once, edit highlighted text, or observe/point at one visible element.
      SINGLE-ACTION MODE IS CRITICAL: emit exactly ONE step. never emit a chain like File → New → File, Add → Mesh → Cylinder, click field → type → press Return, or any other sequence. if the user's request requires a sequence, choose only the next visible/actionable step from the current screen, then wait for the next user utterance/screen state before doing the following step.
      arguments:
        goal  = short summary of the user's intent ("create a new file", "render an animation").
        app   = exact foreground app name visible in the screenshot ("Blender", "Xcode", "GarageBand"). never "macOS" or "unknown".
        steps = exactly one item: [{type?, label, value?, hint, targetContext?, point_2d?, box_2d?}]. the step MUST be visible on the current screen unless it has targetContext:"currentHighlight", targetContext:"currentSelection", or targetContext:"focusedElement".
        point_2d = OPTIONAL exact click/target point in [y, x] form, each value in [0, 1000] normalized to the current screenshot. origin top-left, y first. include this whenever you can, especially for Blender, games, canvas tools, tiny controls, toolbar icons, dense menus, and anything where the center of a box might be wrong.
        box_2d = OPTIONAL bounding box for the step's element in [y1, x1, y2, x2] form, each value in [0, 1000] normalized to the current screenshot. origin top-left, y first. include it as supporting context when useful, but point_2d is preferred for the actual target location.

    STEP TYPES (for submit_workflow_plan):
    every step has an optional `type` field. omit it and it defaults to "click", which is what 95% of steps are. only emit a non-click type when the step is genuinely not a click on visible UI.

      type: "click"  (default — omit the field)
        label = literal visible text on screen (the element to click).
        use this for menus, buttons, tabs, items, links, fields you need to focus by clicking, anything you can SEE.

      type: "rightClick" / "doubleClick"
        label = literal visible text on screen. use only when the user explicitly asks for a context menu or double-click behavior.

      type: "openApp"
        label = exact application name to launch or foreground (e.g. "Safari", "Finder", "Activity Monitor", "Xcode").
        use this when the user says "open X", "launch X", or the next step requires starting an app that is not already visible.

      type: "openURL"
        label = exact URL or file/folder path to open (e.g. "https://youtube.com", "https://github.com", "/Users/milindsoni/Desktop").
        use this when the user asks to open a website/link/path directly. if a browser/app is specified, put it in the plan's `app` field.

      type: "keyboardShortcut"
        label = the shortcut combo as written (e.g. "Cmd+S", "Cmd+Shift+N", "Cmd+Space", "Return", "Escape").
        ONLY use when the action is purely a key press, not a click. examples: confirming a dialog with Return, opening Spotlight with Cmd+Space, saving with Cmd+S when the user explicitly wants the shortcut path. never use this just because there IS a shortcut — if the user can ALSO click File → Save, prefer the click steps so the user learns the menu path.
        modifier names recognized: Cmd / Command, Opt / Option / Alt, Ctrl / Control, Shift, Fn. key names: letters, digits, Space, Return, Tab, Escape, Delete, Left/Right/Up/Down, Home, End, PageUp, PageDown, F1-F12.
        for creating a new native document/note in the current Mac app, prefer Cmd+N over clicking labels like "New Note" because sidebar/list items with similar text can be ambiguous.

      type: "pressKey"
        label = one key name only (e.g. "Return", "Escape", "Tab", "PageDown", "Down").
        use when no modifiers are involved.

      type: "type"
        value = the literal text to type into the currently focused field. label may name the target field, like "Note body".
        ONLY use when the text field/range is already focused, highlighted, or selected. because this is single-action mode, do NOT emit a separate click step before typing in the same tool call.
        do NOT translate the text. if the user said "type 'on my way'", the value is exactly `on my way`, not the user's spoken language.
        if the user said to rewrite/change/delete/replace the current highlighted area, include targetContext:"currentHighlight" and type ONLY the replacement text in value.
        for writing a title plus body, put the entire text in ONE type step's value with newline characters between title and paragraphs.

      type: "setValue"
        value = the value to set on the currently focused native AX element. use sparingly; prefer `type` for normal text fields.

      targetContext:
        optional grounding field for any step. use targetContext:"currentHighlight" when the user refers to the painted highlight or "this highlighted part"; targetContext:"currentSelection" for a normal selected text range; targetContext:"focusedElement" for the active field; targetContext:"visibleElement" for ordinary screen labels. targetContext tells TipTour what app/window/element/range to bind the action to, so it is safer than clicking before typing.

      type: "scroll"
        direction = "up" | "down" | "left" | "right"; amount = small integer; by = "line" or "page".
        use for "scroll down", "go lower", "page down", or when a later visible target is below the current viewport.

    SECURE-FIELD RULE (CRITICAL — read every time):
    NEVER emit a `type` step targeting a password / passcode / 2FA / credit-card / secret-token field, even if the user asks. AX marks these as secure-text inputs; pasting into them via autopilot would echo the user's secrets through the system pasteboard. instead, click the field with a regular click step so the cursor lands there, and let the user type the secret themselves. for the spoken narration say something like "i'll bring you to the password field — type it yourself".

    LOGIN / 2FA RULE: when a workflow lands on a sign-in screen, an OAuth consent screen, or a 2FA prompt, STOP the plan there and hand off. do not auto-click "Continue" / "Allow" / "Sign in" buttons that finalize a credential exchange.

    ABSOLUTE RULES:
    - exactly ONE tool call per turn. never the same tool twice.
    - exactly ONE step inside submit_workflow_plan. never chain actions.
    - any computer control → submit_workflow_plan.
    - for "where is it" / pointing-only requests, do not call a tool; answer conversationally from the screenshot.
    - no UI involvement (pure knowledge or chit-chat) → no tool, just speak.

    POST-TOOL-CALL NARRATION RULE (CRITICAL — read every time):
    the moment a tool call returns ok, you MUST speak. going silent after a tool fires is a bug — the user hears nothing happen. ALWAYS produce one short spoken acknowledgement first ("right at the top left", "opening the File menu", "okay, clicking object mode now"), and ONLY THEN go silent and wait for the user. silence comes AFTER the narration, not instead of it. this rule overrides every other instinct to stay quiet — even if you're unsure what to say, narrate the action you just performed in plain words.

    POST-TOOL-CALL SILENCE-AFTER-NARRATION RULE (CRITICAL):
    once you've spoken your one short narration, the user takes over. they read, they think, they act at human speed — this can take many seconds. during that time you stay COMPLETELY SILENT and call NO tool. do NOT re-point at the same element because "they didn't click yet." do NOT re-submit a plan because "they haven't moved." do NOT helpfully suggest the next step. just wait. the only signal that should make you act again is the USER SPEAKING — a new utterance arriving in the input transcript. screenshots showing an unchanged screen mean nothing; ignore them. if a toolResponse comes back with reason "plan_already_running", you have hallucinated a re-submit — stop, say nothing, wait for the user.

    PRE-TOOL-CALL SILENCE:
    if your next action is a tool call, stay completely silent — no filler, no "sure", no "hmm". call the tool, wait for toolResponse, THEN speak. if you speak before the tool call, the user hears a half-word that cuts off when the tool fires.

    this rule ONLY applies when a tool call is coming. for pure knowledge / chit-chat with no tool, speak normally.

    after submit_workflow_plan returns, narrate only the single action you performed in one short sentence. do not describe future steps or a sequence.
      example: "opening the add menu."
      example: "clicking object mode."

    examples:

    user: "where's the File menu"
      → no tool
      → speak: "right at the top left"

    user: "how do I create a new file in Xcode"
      → submit_workflow_plan(goal: "create a new file", app: "Xcode",
           steps: [{label:"File", hint:"Open the File menu"}])
      → speak: "opening File."

    user: "save this file as report.pdf"
      (Pages is foreground, document is unsaved)
      → submit_workflow_plan(goal: "save the file as report.pdf", app: "Pages",
           steps: [{type:"keyboardShortcut", label:"Cmd+S", hint:"Open the save sheet"}])
      → speak: "opening the save sheet."

    user: "make a new folder on the desktop called Photos"
      (Finder is foreground, desktop visible)
      → submit_workflow_plan(goal: "create a Photos folder on the desktop", app: "Finder",
           steps: [{type:"keyboardShortcut", label:"Cmd+Shift+N", hint:"New folder shortcut"}])
      → speak: "creating a new folder."

    user: "open Activity Monitor"
      → submit_workflow_plan(goal: "launch Activity Monitor", app: "Activity Monitor",
           steps: [{type:"openApp", label:"Activity Monitor", hint:"Open Activity Monitor"}])
      → speak: "opening Activity Monitor."

    user: "open youtube.com"
      → submit_workflow_plan(goal: "open youtube.com", app: "Safari",
           steps: [{type:"openURL", label:"https://youtube.com", hint:"Open youtube.com"}])
      → speak: "opening youtube.com."

    user: "send 'on my way' to mom in messages"
      (Messages is foreground, the user is in mom's thread)
      → submit_workflow_plan(goal: "send a message to mom", app: "Messages",
           steps: [{label:"iMessage", hint:"Click the message field to focus it"}])
      → speak: "focusing the message field."

    user: "log in to my bank"
      → respond conversationally; do NOT auto-fill credentials. you can plan getting them TO the login page (open browser → navigate → click the username field), but stop there and let them type the password themselves.

    user: "what is HTML"
      → no tool
      → speak your answer
    """
    }

    private static var multiStepTourGuidePromptRule: String {
        let isEnabled = UserDefaults.standard.object(forKey: "isMultiStepTourGuideEnabled") == nil
            ? false
            : UserDefaults.standard.bool(forKey: "isMultiStepTourGuideEnabled")

        if isEnabled {
            return "MULTI-STEP TOUR GUIDE MODE: unavailable in single-action mode. even when teaching is enabled, submit_workflow_plan may contain exactly one step."
        }

        return "MULTI-STEP TOUR GUIDE MODE: disabled. do not create guided tours or chained action plans. use submit_workflow_plan only for the next single Autopilot action. if the user asks \"how do i\", \"show me\", \"walk me through\", or \"teach me\", answer conversationally or point at one visible element instead of creating a guided tour."
    }

    // MARK: - Image Conversion

    static func cgImage(from jpegData: Data) -> CGImage? {
        guard let imageSource = CGImageSourceCreateWithData(jpegData as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
    }

    // MARK: - Gemini Live Mode

    /// Execute a workflow plan emitted by Gemini.
    private func startWorkflowPlan(_ plan: WorkflowPlan) {
        let effectivePlan = planForCurrentFocusHighlightIfNeeded(plan)
        print("[Workflow] received plan from LLM: \"\(effectivePlan.goal)\" (\(effectivePlan.steps.count) steps, app=\(effectivePlan.app ?? "?"))")
        WorkflowRunner.shared.start(
            plan: effectivePlan,
            pointHandler: { [weak self] resolution in
                self?.pointAtResolution(resolution)
            },
            latestCapture: voiceBackend.latestCapture
        )
    }

    private func planForCurrentFocusHighlightIfNeeded(_ plan: WorkflowPlan) -> WorkflowPlan {
        guard shouldBindPlanToCurrentFocusContext(plan) else {
            return plan
        }

        if let context = lastFocusHighlightContext,
           Date().timeIntervalSince(context.createdAt) < 300,
           let hoveredWindow = context.hoveredWindow,
           !hoveredWindow.appName.isEmpty {
            configurePendingTextReplacementRangeIfNeeded(
                windowContext: hoveredWindow,
                textSelection: context.textSelection,
                steps: plan.steps
            )
            return WorkflowPlan(
                goal: plan.goal,
                app: hoveredWindow.appName,
                steps: stepsPreservingSelectedTextIfNeeded(
                    plan.steps,
                    selectedText: context.textSelection?.selectedText
                )
            )
        }

        if let hoverWindowContext = lastHoverWindowContext,
           let hoverDate = lastHoverWindowContextDate,
           Date().timeIntervalSince(hoverDate) < 300,
           !hoverWindowContext.appName.isEmpty {
            configurePendingTextReplacementRangeIfNeeded(
                windowContext: hoverWindowContext,
                textSelection: lastHoverTextSelectionContext,
                steps: plan.steps
            )
            return WorkflowPlan(
                goal: plan.goal,
                app: hoverWindowContext.appName,
                steps: stepsPreservingSelectedTextIfNeeded(
                    plan.steps,
                    selectedText: lastHoverTextSelectionContext?.selectedText
                )
            )
        }

        return plan
    }

    private func shouldBindPlanToCurrentFocusContext(_ plan: WorkflowPlan) -> Bool {
        let hasExplicitContextStep = plan.steps.contains { step in
            step.targetContext == .currentHighlight || step.targetContext == .currentSelection
        }
        guard hasExplicitContextStep else { return false }

        let opensDifferentApp = plan.steps.contains { step in
            step.type == .openApp || step.type == .openURL
        }
        return !opensDifferentApp
    }

    private func configurePendingTextReplacementRangeIfNeeded(
        windowContext: FocusHighlightWindowContext,
        textSelection: FocusHighlightTextSelectionContext?,
        steps: [WorkflowStep]
    ) {
        let hasRangeEditingStep = steps.contains { step in
            let stepTargetsContext = step.targetContext == .currentHighlight
                || step.targetContext == .currentSelection

            if step.type == .type || step.type == .setValue {
                return stepTargetsContext || step.targetContext == nil
            }
            guard step.type == .pressKey,
                  let label = step.label else {
                return false
            }
            let normalizedLabel = label
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
                .lowercased()
            let isTextDeletionKey = normalizedLabel == "delete"
                || normalizedLabel == "del"
                || normalizedLabel == "backspace"
            return (stepTargetsContext || step.targetContext == nil) && isTextDeletionKey
        }
        guard hasRangeEditingStep else { return }

        guard let selectedTextRangeLocation = textSelection?.selectedTextRangeLocation,
              let selectedTextRangeLength = textSelection?.selectedTextRangeLength,
              selectedTextRangeLocation >= 0,
              selectedTextRangeLength > 0 else {
            return
        }

        ActionExecutor.shared.setPendingTextReplacementRange(
            processIdentifier: windowContext.processIdentifier,
            location: selectedTextRangeLocation,
            length: selectedTextRangeLength
        )
    }

    private func stepsPreservingSelectedTextIfNeeded(
        _ steps: [WorkflowStep],
        selectedText: String?
    ) -> [WorkflowStep] {
        guard steps.count >= 2,
              let selectedText,
              !selectedText.isEmpty else {
            return steps
        }

        let firstStep = steps[0]
        let secondStep = steps[1]
        let secondStepTargetsExistingContext = secondStep.targetContext == .currentHighlight
            || secondStep.targetContext == .currentSelection
        guard firstStep.type == .click || firstStep.type == .doubleClick,
              secondStep.type == .type || secondStep.type == .pressKey || secondStep.type == .keyboardShortcut || secondStep.type == .setValue,
              secondStepTargetsExistingContext
                || (firstStep.label.map {
                    Self.normalizedTextForSelectionComparison(selectedText)
                        .contains(Self.normalizedTextForSelectionComparison($0))
                } ?? false) else {
            return steps
        }

        print("[FocusHighlight] preserving existing text context — dropping leading \(firstStep.type.rawValue) step")
        return Array(steps.dropFirst())
    }

    private static func normalizedTextForSelectionComparison(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Start a Gemini Live session on hotkey press. Two things run in
    /// parallel from the instant the hotkey fires:
    ///   1. WebSocket open + Gemini session setup (~300-500ms)
    ///   2. Real AX-tree prefetch on the user's target app — walks the
    ///      frontmost app's AX tree and primes the set-of-marks cache so
    ///      the moment Gemini emits its first tool call, the resolver
    ///      already has the AX data it needs.
    ///
    /// The prefetch overlaps the user's first words / Gemini's session
    /// setup, so the latency cost (typically 50-300ms on Cocoa apps,
    /// up to 1s on heavy Electron trees) lands entirely in "free" time.
    /// This is the single biggest perceived-latency win on the warm
    /// path: by the time the first CUA plan arrives,
    /// resolution returns in ~10-30ms instead of 100-400ms.
    func startVoiceSession() {
        if isDetectionOverlayEnabled {
            scheduleNativeDetectionOverlayRefresh(reason: "voice session started", debounceNanoseconds: 0)
        }

        Task.detached(priority: .userInitiated) {
            await Self.prefetchAccessibilityTreeForTargetApp()
        }

        Task {
            do {
                try await voiceBackend.start(initialScreenshot: nil)
            } catch {
                print("[GeminiLive] Failed to start session: \(error.localizedDescription)")
            }
        }
    }

    /// Walk the user's target app AX tree to prime caches so the first
    /// CUA plan resolves against warm data. The set-of-marks
    /// walk inside `setOfMarksForTargetApp` is the heaviest AX call
    /// the resolver makes at runtime, so doing it now means the first
    /// real `findElement` call is mostly cached I/O.
    ///
    /// Uses the snapshot of the user's frontmost app captured at hotkey
    /// press time (set in `handleShortcutTransition`) — never our own
    /// menu bar app.
    private static func prefetchAccessibilityTreeForTargetApp() async {
        let resolver = AccessibilityTreeResolver()
        // Touch set-of-marks first (warms the full traversal cache),
        // then a "no-match-expected" findElement call so any
        // empty-tree detection (Blender / canvas apps) is recorded
        // before the first real resolution attempt arrives.
        _ = resolver.setOfMarksForTargetApp(hint: nil)
        _ = await ElementResolver.shared.tryAccessibilityTree(label: "__warmup__")
    }

    /// End the Gemini Live session.
    func stopVoiceSession() {
        WorkflowRunner.shared.stop()
        voiceBackend.stop()
    }
}
