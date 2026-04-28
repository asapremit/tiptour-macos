//
//  OpenAIRealtimeSession.swift
//  TipTour
//
//  Orchestrates a full OpenAI Realtime conversation session, mirroring
//  GeminiLiveSession's role for the OpenAI backend:
//    1. Fetches a short-lived ephemeral token from the worker
//    2. Opens a WebSocket via OpenAIRealtimeClient with bearer auth
//    3. Captures mic audio with AVAudioEngine, converts to PCM16 24kHz,
//       and streams it over the WebSocket
//    4. Sends a screenshot at session start (and every few seconds) so
//       the model can see the user's screen
//    5. Plays back audio responses in real time via GeminiLiveAudioPlayer
//       (the player is vendor-neutral PCM16 24kHz playback)
//    6. Exposes input/output transcripts and parses tool calls so
//       CompanionManager can drive cursor pointing identically to the
//       Gemini path
//

import AppKit
import AVFoundation
import Combine
import Foundation

@MainActor
final class OpenAIRealtimeSession: ObservableObject, VoiceBackend {

    // MARK: - Published State

    @Published private(set) var isActive: Bool = false
    @Published private(set) var inputTranscript: String = ""
    @Published private(set) var outputTranscript: String = ""

    @Published private(set) var isModelSpeaking: Bool = false {
        didSet {
            modelSpeakingLock.withLock { modelSpeakingFlag = isModelSpeaking }
        }
    }
    private var modelSpeakingFlag: Bool = false
    private let modelSpeakingLock = NSLock()

    @Published private(set) var currentAudioPowerLevel: CGFloat = 0.0
    @Published private(set) var latestCapture: CompanionScreenCapture?

    var isAudioPlaying: Bool { audioPlayer.isPlaying }

    // MARK: - VoiceBackend Publisher Conformance

    var currentAudioPowerLevelPublisher: AnyPublisher<CGFloat, Never> {
        $currentAudioPowerLevel.eraseToAnyPublisher()
    }
    var isModelSpeakingPublisher: AnyPublisher<Bool, Never> {
        $isModelSpeaking.eraseToAnyPublisher()
    }

    // MARK: - Callbacks (VoiceBackend)

    var onPointAtElement: ((_ id: String, _ label: String, _ box2DNormalized: [Int]?, _ screenshotJPEG: Data?) async -> [String: Any])?
    var onSubmitWorkflowPlan: ((_ id: String, _ goal: String, _ app: String, _ steps: [[String: Any]]) async -> [String: Any])?
    var onOutputTranscript: ((String) -> Void)?
    var onInputTranscriptUpdate: ((String) -> Void)?
    var onTurnComplete: (() -> Void)?
    var onError: ((Error) -> Void)?

    // MARK: - Dependencies

    private let openaiClient = OpenAIRealtimeClient()
    private let audioPlayer = GeminiLiveAudioPlayer()  // vendor-neutral PCM16 24kHz player
    private var audioEngine = AVAudioEngine()
    private let pcm16Converter = BuddyPCM16AudioConverter(targetSampleRate: OpenAIRealtimeClient.inputSampleRate)

    /// Worker endpoint that mints ephemeral OpenAI tokens — the long-lived
    /// OPENAI_API_KEY stays inside the Cloudflare Worker.
    private let ephemeralTokenURL: URL
    private let systemPrompt: String

    private var isAudioTapInstalled: Bool = false
    private var screenshotUpdateTimer: Timer?
    private static let screenshotUpdateInterval: TimeInterval = 3.0

    /// Perceptual hash dedup state — same idea as GeminiLiveSession.
    /// Skip uploading frames identical to the last one we sent for the
    /// same screen.
    private var lastSentScreenshotHashByScreenLabel: [String: UInt64] = [:]

    /// Last set-of-marks string sent to the model — we skip resending if
    /// the AX tree is unchanged. Saves tokens during static screens.
    private var lastSentSetOfMarks: String = ""

    /// Whether mic + screenshots are paused for narration of a workflow
    /// plan. Same lifecycle as GeminiLiveSession.
    private var isInNarrationMode: Bool = false

    /// True between a successful tool call and the next user utterance.
    /// Suppresses screenshot pushes so the model doesn't re-emit the
    /// same tool call in a "user hasn't moved yet" loop.
    private var areScreenshotsSuppressedUntilUserSpeaks: Bool = false

    // MARK: - Init

    init(ephemeralTokenURL: String, systemPrompt: String) {
        self.ephemeralTokenURL = URL(string: ephemeralTokenURL)!
        self.systemPrompt = systemPrompt

        openaiClient.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handleOpenAIEvent(event)
            }
        }
    }

    // MARK: - Session Lifecycle

    func start(initialScreenshot: Data?) async throws {
        guard !isActive else {
            print("[OpenAIRealtimeSession] Already active — ignoring start()")
            return
        }

        let ephemeralToken = try await RetryWithExponentialBackoff.run(
            maxAttempts: 3,
            initialDelay: 0.5,
            operationName: "OpenAIRealtime.fetchEphemeralToken"
        ) { [weak self] in
            guard let self else {
                throw NSError(domain: "OpenAIRealtimeSession", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Session deallocated during token fetch"])
            }
            return try await self.fetchEphemeralToken()
        }

        try await RetryWithExponentialBackoff.run(
            maxAttempts: 3,
            initialDelay: 0.5,
            operationName: "OpenAIRealtime.connect"
        ) { [weak self] in
            guard let self else {
                throw NSError(domain: "OpenAIRealtimeSession", code: -2,
                              userInfo: [NSLocalizedDescriptionKey: "Session deallocated during connect"])
            }
            try await self.openaiClient.connect(
                ephemeralToken: ephemeralToken,
                systemPrompt: self.systemPrompt,
                tools: Self.toolDeclarations()
            )
        }

        isActive = true
        outputTranscript = ""
        inputTranscript = ""
        lastSentScreenshotHashByScreenLabel.removeAll()
        lastSentSetOfMarks = ""
        areScreenshotsSuppressedUntilUserSpeaks = false

        // Optional kick-off screenshot so the model has visual context
        // before the user says anything.
        if let initialScreenshot {
            openaiClient.sendScreenshot(initialScreenshot)
        }

        try startMicCapture()
        startPeriodicScreenshotUpdates()
        print("[OpenAIRealtimeSession] Session started")
    }

    func stop() {
        guard isActive else { return }
        stopPeriodicScreenshotUpdates()
        stopMicCapture()
        audioPlayer.clearQueuedAudio()
        openaiClient.disconnect()
        isActive = false
        isModelSpeaking = false
        isInNarrationMode = false
        print("[OpenAIRealtimeSession] Session stopped")
    }

    // MARK: - Narration Mode

    func enterNarrationMode() {
        guard isActive else { return }
        isInNarrationMode = true
        stopMicCapture()
        stopPeriodicScreenshotUpdates()
        print("[OpenAIRealtimeSession] Narration mode entered (mic + screenshots paused)")
    }

    func exitNarrationMode() {
        guard isActive, isInNarrationMode else { return }
        isInNarrationMode = false
        do {
            try startMicCapture()
        } catch {
            print("[OpenAIRealtimeSession] Failed to restart mic on narration exit: \(error.localizedDescription)")
        }
        startPeriodicScreenshotUpdates()
        print("[OpenAIRealtimeSession] Narration mode exited (mic + screenshots resumed)")
    }

    // MARK: - Screenshot Suppression

    func suppressScreenshotsUntilUserSpeaks() {
        areScreenshotsSuppressedUntilUserSpeaks = true
        print("[OpenAIRealtimeSession] 🔇 screenshots suppressed until user speaks")
    }

    func invalidateScreenshotHashCache() {
        lastSentScreenshotHashByScreenLabel.removeAll()
    }

    // MARK: - Tool Declarations

    /// OpenAI Realtime function format. Same parameters as Gemini's
    /// declarations — only the envelope differs (flat object with
    /// `type: "function"` instead of nested `functionDeclarations`).
    private static func toolDeclarations() -> [[String: Any]] {
        let pointAtElement: [String: Any] = [
            "type": "function",
            "name": "point_at_element",
            "description": "Fly the cursor to a single visible UI element on the user's screen. Use for simple 'where is X' / 'point at X' questions where ONE element is all that's needed and it's visible right now.",
            "parameters": [
                "type": "object",
                "properties": [
                    "label": [
                        "type": "string",
                        "description": "The literal visible text of the element — e.g. 'Save', 'File', 'Source Control'. Use the actual text on screen, not a description."
                    ],
                    "box_2d": [
                        "type": "array",
                        "description": "Optional bounding box for the element in normalized [y1, x1, y2, x2] form, each value in [0, 1000] relative to the screenshot. RECOMMENDED for apps without accessibility (Blender, games, canvas tools) and for ambiguous labels. Origin is top-left, y comes first.",
                        "items": ["type": "integer"],
                        "minItems": 4,
                        "maxItems": 4
                    ]
                ],
                "required": ["label"]
            ]
        ]
        let submitWorkflowPlan: [String: Any] = [
            "type": "function",
            "name": "submit_workflow_plan",
            "description": "For any multi-step walkthrough (opening a menu then picking an item, 'how do I X', 'walk me through Y', 'teach me Z'). Emit the FULL plan of steps as a structured argument. The model narrates each step after the tool returns, while the cursor flies through them in order.",
            "parameters": [
                "type": "object",
                "properties": [
                    "goal": [
                        "type": "string",
                        "description": "Short natural-language summary of what the user wants to accomplish."
                    ],
                    "app": [
                        "type": "string",
                        "description": "EXACT name of the foreground application visible in the screenshot — e.g. 'Blender', 'Xcode', 'GarageBand'. Do NOT guess 'macOS' or 'unknown'."
                    ],
                    "steps": [
                        "type": "array",
                        "description": "Ordered list of steps. First step MUST be visible on the current screen; later steps describe the path to take after clicking step 1.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "label": [
                                    "type": "string",
                                    "description": "Literal visible text of the element, or nearest label for an icon."
                                ],
                                "hint": [
                                    "type": "string",
                                    "description": "Short sentence describing this step — e.g. 'Open the File menu'."
                                ],
                                "box_2d": [
                                    "type": "array",
                                    "description": "Optional bounding box for the element in normalized [y1, x1, y2, x2] form, each value in [0, 1000] relative to the current screenshot. Origin is top-left, y comes first.",
                                    "items": ["type": "integer"],
                                    "minItems": 4,
                                    "maxItems": 4
                                ]
                            ],
                            "required": ["label"]
                        ]
                    ]
                ],
                "required": ["goal", "app", "steps"]
            ]
        ]
        return [pointAtElement, submitWorkflowPlan]
    }

    // MARK: - Event Dispatch

    private func handleOpenAIEvent(_ event: OpenAIRealtimeEvent) {
        switch event {
        case .sessionReady:
            print("[OpenAIRealtimeSession] session.updated — ready")

        case .audioChunk(let pcm16Data):
            isModelSpeaking = true
            // GeminiLiveAudioPlayer is hard-coded to 24kHz PCM16 mono.
            // OpenAI Realtime emits the same format, so the same player
            // works as-is — see OpenAIRealtimeClient.outputSampleRate.
            audioPlayer.enqueueAudioChunk(pcm16Data)

        case .inputTranscript(let snapshot):
            inputTranscript = snapshot
            // User spoke — clear the post-tool-call screenshot suppression.
            if areScreenshotsSuppressedUntilUserSpeaks
                && !snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                areScreenshotsSuppressedUntilUserSpeaks = false
                print("[OpenAIRealtimeSession] 🔊 user spoke — screenshots resumed")
            }
            onInputTranscriptUpdate?(snapshot)

        case .outputTranscript(let snapshot):
            outputTranscript = snapshot
            onOutputTranscript?(snapshot)

        case .turnComplete:
            isModelSpeaking = false
            onTurnComplete?()

        case .interrupted:
            audioPlayer.clearQueuedAudio()
            isModelSpeaking = false

        case .toolCall(let id, let name, let args):
            handleToolCall(id: id, name: name, args: args)

        case .unexpectedDisconnect(let error):
            print("[OpenAIRealtimeSession] unexpected disconnect: \(error.localizedDescription)")
            // Reconnect logic could be added here mirroring Gemini's pattern.
            // For now, surface as fatal so the orchestrator can decide.
            isActive = false
            onError?(error)

        case .error(let error):
            isActive = false
            onError?(error)
        }
    }

    private func handleToolCall(id: String, name: String, args: [String: Any]) {
        // Clear any queued speech the moment a tool call fires — same
        // pattern as the Gemini path. The model often prefaces a tool
        // call with a half-word that should be discarded.
        audioPlayer.clearQueuedAudio()
        isModelSpeaking = false

        let screenshot = latestCapture?.imageData

        Task {
            var response: [String: Any] = ["ok": false, "error": "tool_unavailable"]

            switch name {
            case "point_at_element":
                let label = (args["label"] as? String) ?? ""
                let box2D = (args["box_2d"] as? [Int]).flatMap { $0.count == 4 ? $0 : nil }
                if !label.isEmpty, let handler = onPointAtElement {
                    response = await handler(id, label, box2D, screenshot)
                }

            case "submit_workflow_plan":
                let goal = (args["goal"] as? String) ?? ""
                let app = (args["app"] as? String) ?? ""
                let steps = (args["steps"] as? [[String: Any]]) ?? []
                if !goal.isEmpty, !steps.isEmpty, let handler = onSubmitWorkflowPlan {
                    response = await handler(id, goal, app, steps)
                }

            default:
                print("[OpenAIRealtimeSession] unknown tool \(name) — ignoring")
            }

            openaiClient.sendToolResponse(callID: id, output: response)
        }
    }

    // MARK: - Mic Capture

    private func startMicCapture() throws {
        // Rebuild the engine each session so we always pick up the
        // current input format (AirPods on/off, sample-rate switch).
        audioEngine = AVAudioEngine()

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        print("[OpenAIRealtimeSession] Mic input format: \(inputFormat)")

        guard inputFormat.sampleRate > 0 else {
            throw NSError(domain: "OpenAIRealtimeSession", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "Microphone has zero sample rate — likely no input device available"])
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }

            // Don't echo our own playback back into the model.
            let modelSpeaking = self.modelSpeakingLock.withLock { self.modelSpeakingFlag }
            if modelSpeaking { return }

            // Compute audio power for waveform UI.
            if let channelData = buffer.floatChannelData {
                let frameLength = Int(buffer.frameLength)
                var sumSquares: Float = 0
                for i in 0..<frameLength {
                    let sample = channelData[0][i]
                    sumSquares += sample * sample
                }
                let rms = sqrt(sumSquares / Float(frameLength))
                let normalized = min(1.0, max(0.0, CGFloat(rms) * 4.0))
                Task { @MainActor in
                    self.currentAudioPowerLevel = normalized
                }
            }

            guard let pcm16Data = self.pcm16Converter.convertToPCM16Data(from: buffer) else { return }
            self.openaiClient.sendAudioChunk(pcm16Data)
        }
        isAudioTapInstalled = true

        audioEngine.prepare()
        try audioEngine.start()
        print("[OpenAIRealtimeSession] Mic capture started")
    }

    private func stopMicCapture() {
        if isAudioTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            isAudioTapInstalled = false
        }
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        currentAudioPowerLevel = 0
        print("[OpenAIRealtimeSession] Mic capture stopped")
    }

    // MARK: - Periodic Screenshot Streaming

    private func startPeriodicScreenshotUpdates() {
        screenshotUpdateTimer?.invalidate()
        // Send one immediately, then on the timer.
        Task { await self.captureAndProcessFrame() }
        screenshotUpdateTimer = Timer.scheduledTimer(
            withTimeInterval: Self.screenshotUpdateInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in await self?.captureAndProcessFrame() }
        }
    }

    private func stopPeriodicScreenshotUpdates() {
        screenshotUpdateTimer?.invalidate()
        screenshotUpdateTimer = nil
    }

    private func captureAndProcessFrame() async {
        guard let screenshots = try? await CompanionScreenCaptureUtility.captureAllScreensAsJPEG(),
              let primaryCapture = screenshots.first else {
            return
        }

        // Always refresh the local cache so coordinate mapping + YOLO
        // cache stay current — those are local consumers, not network
        // sends.
        latestCapture = primaryCapture

        if areScreenshotsSuppressedUntilUserSpeaks { return }
        if WorkflowRunner.shared.activePlan != nil { return }

        let screenLabel = primaryCapture.label
        let newHash = ScreenshotPerceptualHash.perceptualHash(forJPEGData: primaryCapture.imageData)

        if let newHash,
           let lastHash = lastSentScreenshotHashByScreenLabel[screenLabel],
           ScreenshotPerceptualHash.isSameScene(lastHash, newHash) {
            return
        }
        if let newHash {
            lastSentScreenshotHashByScreenLabel[screenLabel] = newHash
        }
        openaiClient.sendScreenshot(primaryCapture.imageData)

        // Set-of-marks send: same pattern as Gemini path. Background
        // priority so the AX walk doesn't contend with the audio thread.
        let lastSentMarks = lastSentSetOfMarks
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            let resolver = AccessibilityTreeResolver()
            let targetAppHint = AccessibilityTreeResolver.userTargetAppOverride?.localizedName
            guard let marks = resolver.setOfMarksForTargetApp(hint: targetAppHint), !marks.isEmpty else {
                return
            }
            let formatted = AccessibilityTreeResolver.formatMarks(marks)
            if formatted == lastSentMarks { return }
            await MainActor.run { self.lastSentSetOfMarks = formatted }
            let preamble = "UI elements on screen (use these exact labels in tool calls):\n"
            self.openaiClient.sendText(preamble + formatted)
        }
    }

    // MARK: - Ephemeral Token Fetch

    /// Fetch an ephemeral token. By default we POST to the worker's
    /// `/openai-realtime-token` route (which mints the ephemeral with
    /// the production OPENAI_API_KEY secret server-side). If the user
    /// has pasted their own OpenAI key into the Dev section, mint the
    /// ephemeral directly against OpenAI from the app — bypassing the
    /// worker entirely. Useful for local source builds where the
    /// worker doesn't have a production secret configured yet.
    private func fetchEphemeralToken() async throws -> String {
        let request: URLRequest
        if let userOpenAIKey = KeychainStore.openAIAPIKey,
           !userOpenAIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let directURL = URL(string: "https://api.openai.com/v1/realtime/client_secrets") else {
                throw NSError(domain: "OpenAIRealtimeSession", code: -9,
                              userInfo: [NSLocalizedDescriptionKey: "Bad direct OpenAI URL"])
            }
            var directRequest = URLRequest(url: directURL)
            directRequest.httpMethod = "POST"
            directRequest.timeoutInterval = 8
            directRequest.setValue("application/json", forHTTPHeaderField: "content-type")
            directRequest.setValue("Bearer \(userOpenAIKey)", forHTTPHeaderField: "Authorization")
            directRequest.httpBody = "{}".data(using: .utf8)
            request = directRequest
        } else {
            var workerRequest = URLRequest(url: ephemeralTokenURL)
            workerRequest.httpMethod = "POST"
            workerRequest.timeoutInterval = 8
            workerRequest.setValue("application/json", forHTTPHeaderField: "content-type")
            workerRequest.httpBody = "{}".data(using: .utf8)
            request = workerRequest
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw NSError(
                domain: "OpenAIRealtimeSession",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey: "Worker returned \(status): \(body)"]
            )
        }

        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "OpenAIRealtimeSession",
                code: -11,
                userInfo: [NSLocalizedDescriptionKey: "Couldn't parse token envelope"]
            )
        }

        // OpenAI wraps the token in `client_secret.value` per the docs.
        // Also fall back to a flat `value` or `client_secret` field in case
        // the worker reshapes it.
        if let clientSecret = envelope["client_secret"] as? [String: Any],
           let value = clientSecret["value"] as? String, !value.isEmpty {
            return value
        }
        if let value = envelope["value"] as? String, !value.isEmpty {
            return value
        }
        if let value = envelope["client_secret"] as? String, !value.isEmpty {
            return value
        }
        throw NSError(
            domain: "OpenAIRealtimeSession",
            code: -12,
            userInfo: [NSLocalizedDescriptionKey: "Token field missing from worker response"]
        )
    }
}
