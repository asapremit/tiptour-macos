//
//  OpenAIRealtimeClient.swift
//  TipTour
//
//  WebSocket client for OpenAI's Realtime API (gpt-realtime-1.5). Single
//  bidirectional streaming connection that handles voice in, voice out,
//  image input, and in-stream tool calling — same conceptual shape as
//  GeminiLiveClient, different wire encoding.
//
//  Connection lifecycle:
//   1. connect(ephemeralToken:) opens the WebSocket with bearer auth +
//      `OpenAI-Beta: realtime=v1` header.
//   2. Send a `session.update` event configuring modalities, audio
//      formats, voice, system instruction, and tool declarations.
//   3. Server responds with `session.created` then `session.updated`
//      confirming config — only then can we send data.
//   4. sendAudioChunk() streams base64-encoded PCM16 24kHz mono
//      via `input_audio_buffer.append`.
//   5. sendScreenshot() attaches a JPEG frame to a fresh conversation
//      item via `conversation.item.create` with an `input_image` part.
//   6. Server streams back `response.output_audio.delta` (b64 PCM16 24kHz),
//      transcripts, and `response.done` events containing tool calls.
//
//  Wire-level reference:
//    https://developers.openai.com/api/docs/guides/realtime-conversations
//

import Foundation

/// Events surfaced from the OpenAI Realtime WebSocket. Reuses the same
/// envelope as `GeminiLiveEvent` — see `GeminiLiveClient.swift`.
enum OpenAIRealtimeEvent {
    /// Server confirmed our session.update — safe to send audio/image/text.
    case sessionReady

    /// A chunk of PCM16 24kHz audio from the model's voice response.
    case audioChunk(Data)

    /// Partial transcript of the user's speech (input audio transcription).
    case inputTranscript(String)

    /// Partial transcript of the model's speech.
    case outputTranscript(String)

    /// The model finished its turn — free to send new user input.
    case turnComplete

    /// User barge-in — discard any queued model audio.
    case interrupted

    /// The model called one of our registered tools. Reply with
    /// `sendToolResponse(...)` before requesting another response.
    case toolCall(id: String, name: String, args: [String: Any])

    /// WebSocket closed unexpectedly (server / network drop, not user-
    /// initiated). The orchestrator may decide to reconnect.
    case unexpectedDisconnect(Error)

    /// Fatal error — client will disconnect.
    case error(Error)
}

/// Intentionally NOT @MainActor. Audio buffers arrive on the real-time
/// audio thread and cannot afford to hop to main on every frame. State
/// is protected by `stateLock`. Event callbacks dispatch to main.
final class OpenAIRealtimeClient: @unchecked Sendable {

    // MARK: - Configuration

    /// gpt-realtime-1.5 — current production-leaning model. Image input,
    /// function calling, and improved instruction following.
    static let modelID = "gpt-realtime-1.5"

    /// Voice. OpenAI's Realtime voices include marin, cedar, alloy, etc.
    /// "marin" is the documented default for gpt-realtime; sounds neutral.
    static let defaultVoice = "marin"

    /// Audio formats per OpenAI Realtime docs. Both directions are PCM16
    /// 24kHz mono — different from Gemini Live's 16kHz input.
    static let inputSampleRate: Double = 24_000
    static let outputSampleRate: Double = 24_000

    // MARK: - State (protected by stateLock)

    private let stateLock = NSLock()
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveLoopTask: Task<Void, Never>?
    private var _isConnected: Bool = false
    private var _isSessionReady: Bool = false
    private var _wasIntentionallyDisconnected: Bool = false

    /// Accumulator for the model's output transcript across delta events.
    /// OpenAI emits `response.output_audio_transcript.delta` with the new
    /// fragment; we concatenate so consumers always see the full text so far.
    private var outputTranscriptAccumulator: String = ""
    /// Same for input (user) transcription.
    private var inputTranscriptAccumulator: String = ""

    /// Function-call argument accumulators keyed by call_id. OpenAI streams
    /// function arguments incrementally via `response.function_call_arguments.delta`
    /// and only completes them with `response.function_call_arguments.done`,
    /// where we get the final args + call name to dispatch.
    private var pendingFunctionCalls: [String: PendingFunctionCall] = [:]
    private struct PendingFunctionCall {
        var name: String
        var argumentsJSON: String
    }

    var isConnected: Bool {
        stateLock.withLock { _isConnected }
    }
    var isSessionReady: Bool {
        stateLock.withLock { _isSessionReady }
    }

    /// Callback invoked on every event. Dispatched to main before firing.
    var onEvent: ((OpenAIRealtimeEvent) -> Void)?

    private let urlSession: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 0
        self.urlSession = URLSession(configuration: configuration)
    }

    // MARK: - Connection Lifecycle

    /// Open the WebSocket and send the initial session.update. Waits until
    /// the server responds with `session.updated` before returning. Throws
    /// on connection or setup failure.
    ///
    /// `ephemeralToken` is the short-lived token minted by the worker's
    /// `/openai-realtime-token` endpoint — the long-lived OPENAI_API_KEY
    /// never reaches the app.
    func connect(
        ephemeralToken: String,
        systemPrompt: String,
        tools: [[String: Any]],
        voice: String = OpenAIRealtimeClient.defaultVoice
    ) async throws {
        guard !isConnected else {
            print("[OpenAIRealtime] Already connected — ignoring connect()")
            return
        }

        let urlString = "wss://api.openai.com/v1/realtime?model=\(Self.modelID)"
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "OpenAIRealtime", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid WebSocket URL"])
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(ephemeralToken)", forHTTPHeaderField: "Authorization")
        // The `OpenAI-Beta: realtime=v1` header was required when Realtime
        // was in public beta. The API has since gone GA — sending the beta
        // header alongside a GA-minted client secret now makes the server
        // reject the session with an "API version mismatch" error.

        let task = urlSession.webSocketTask(with: request)
        stateLock.withLock {
            self.webSocketTask = task
            self._isConnected = true
            self._isSessionReady = false
            self._wasIntentionallyDisconnected = false
            self.outputTranscriptAccumulator = ""
            self.inputTranscriptAccumulator = ""
            self.pendingFunctionCalls.removeAll()
        }
        task.resume()
        print("[OpenAIRealtime] WebSocket opened")

        startReceiveLoop()

        // Send session.update — modalities, audio formats, voice, system
        // prompt, and the tools we want the model to be able to call.
        let sessionUpdate: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "realtime",
                "model": Self.modelID,
                "output_modalities": ["audio"],
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": Int(Self.inputSampleRate)
                        ],
                        "turn_detection": [
                            // Server-side voice activity detection — same
                            // pattern as Gemini's automatic VAD. Keeps the
                            // mic always-listen behavior.
                            "type": "server_vad"
                        ],
                        "transcription": [
                            // Have the server transcribe the user's speech
                            // so we can mirror Gemini's input-transcript
                            // observation pipeline.
                            "model": "whisper-1"
                        ]
                    ],
                    "output": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": Int(Self.outputSampleRate)
                        ],
                        "voice": voice
                    ]
                ],
                "instructions": systemPrompt,
                "tools": tools,
                "tool_choice": "auto"
            ]
        ]

        try await sendJSON(sessionUpdate)
        // Block start() until session.updated lands, mirroring Gemini's
        // setupComplete gate. Otherwise downstream sends race against a
        // half-configured session and silently fail.
        try await waitForSessionReady(timeoutSeconds: 10)
    }

    /// User-initiated close. Marks the session intentionally-closed so the
    /// receive loop's error handler doesn't fire `unexpectedDisconnect`.
    func disconnect() {
        stateLock.withLock { _wasIntentionallyDisconnected = true }
        receiveLoopTask?.cancel()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        stateLock.withLock {
            _isConnected = false
            _isSessionReady = false
            webSocketTask = nil
        }
        print("[OpenAIRealtime] Disconnected (intentional)")
    }

    // MARK: - Sending Audio / Image / Tool Responses

    /// Stream a base64-encoded PCM16 audio chunk to the server. Called
    /// from the audio capture thread — must NOT hop to main.
    func sendAudioChunk(_ pcm16Data: Data) {
        guard isConnected else { return }
        let base64 = pcm16Data.base64EncodedString()
        let event: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": base64
        ]
        sendJSONFireAndForget(event)
    }

    /// Attach a JPEG frame as a new user message in the conversation.
    /// OpenAI's Realtime API takes images as `input_image` content parts
    /// inside a conversation.item.create envelope.
    func sendScreenshot(_ jpegData: Data) {
        guard isConnected else { return }
        let dataURI = "data:image/jpeg;base64,\(jpegData.base64EncodedString())"
        let event: [String: Any] = [
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [
                    [
                        "type": "input_image",
                        "image_url": dataURI
                    ]
                ]
            ]
        ]
        sendJSONFireAndForget(event)
    }

    /// Send an arbitrary text input as a user message — useful for the
    /// set-of-marks element list we attach to screenshots so the model has
    /// ground-truth labels to reference in tool calls.
    func sendText(_ text: String) {
        guard isConnected else { return }
        let event: [String: Any] = [
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [
                    [
                        "type": "input_text",
                        "text": text
                    ]
                ]
            ]
        ]
        sendJSONFireAndForget(event)
    }

    /// Reply to a tool call so the model can continue its turn. `output`
    /// is serialized as JSON inside the function_call_output item.
    func sendToolResponse(callID: String, output: [String: Any]) {
        guard isConnected else { return }
        let outputJSON: String
        if let data = try? JSONSerialization.data(withJSONObject: output),
           let s = String(data: data, encoding: .utf8) {
            outputJSON = s
        } else {
            outputJSON = "{}"
        }
        let event: [String: Any] = [
            "type": "conversation.item.create",
            "item": [
                "type": "function_call_output",
                "call_id": callID,
                "output": outputJSON
            ]
        ]
        sendJSONFireAndForget(event)
        // After a tool response, prompt the model to continue speaking.
        sendJSONFireAndForget(["type": "response.create"])
    }

    // MARK: - Send Helpers

    private func sendJSON(_ payload: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let webSocketTask = (stateLock.withLock { self.webSocketTask }) else {
            throw NSError(domain: "OpenAIRealtime", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "WebSocket not available"])
        }
        let message = URLSessionWebSocketTask.Message.string(String(data: data, encoding: .utf8) ?? "")
        try await webSocketTask.send(message)
    }

    private func sendJSONFireAndForget(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let webSocketTask = (stateLock.withLock { self.webSocketTask }) else {
            return
        }
        let message = URLSessionWebSocketTask.Message.string(String(data: data, encoding: .utf8) ?? "")
        webSocketTask.send(message) { error in
            if let error {
                print("[OpenAIRealtime] sendJSONFireAndForget error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Receive Loop

    private func startReceiveLoop() {
        receiveLoopTask?.cancel()
        receiveLoopTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            guard let webSocketTask = (stateLock.withLock { self.webSocketTask }) else { return }
            do {
                let message = try await webSocketTask.receive()
                switch message {
                case .string(let text):
                    handleIncomingText(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        handleIncomingText(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                let wasIntentional = stateLock.withLock { _wasIntentionallyDisconnected }
                stateLock.withLock {
                    _isConnected = false
                    _isSessionReady = false
                }
                if !wasIntentional {
                    print("[OpenAIRealtime] Receive loop error: \(error.localizedDescription)")
                    dispatchEvent(.unexpectedDisconnect(error))
                }
                return
            }
        }
    }

    private func handleIncomingText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = envelope["type"] as? String else {
            return
        }

        switch type {
        case "session.created":
            // First confirmation that the session exists. session.updated
            // arrives after our session.update applies — gate readiness
            // on that, not this.
            break

        case "session.updated":
            stateLock.withLock { _isSessionReady = true }
            dispatchEvent(.sessionReady)

        case "response.output_audio.delta":
            if let b64 = envelope["delta"] as? String,
               let data = Data(base64Encoded: b64) {
                dispatchEvent(.audioChunk(data))
            }

        case "response.output_audio_transcript.delta":
            if let delta = envelope["delta"] as? String {
                stateLock.withLock { outputTranscriptAccumulator += delta }
                let snapshot = stateLock.withLock { outputTranscriptAccumulator }
                dispatchEvent(.outputTranscript(snapshot))
            }

        case "conversation.item.input_audio_transcription.delta":
            if let delta = envelope["delta"] as? String {
                stateLock.withLock { inputTranscriptAccumulator += delta }
                let snapshot = stateLock.withLock { inputTranscriptAccumulator }
                dispatchEvent(.inputTranscript(snapshot))
            }

        case "conversation.item.input_audio_transcription.completed":
            // OpenAI sends the final transcript here. Reset the accumulator
            // so the next utterance starts clean.
            if let transcript = envelope["transcript"] as? String {
                stateLock.withLock { inputTranscriptAccumulator = transcript }
                dispatchEvent(.inputTranscript(transcript))
            }

        case "input_audio_buffer.speech_started":
            // User began speaking — barge-in if the model is mid-response.
            dispatchEvent(.interrupted)

        case "response.function_call_arguments.delta":
            // Function args stream incrementally. Accumulate by call_id.
            if let callID = envelope["call_id"] as? String,
               let delta = envelope["delta"] as? String {
                stateLock.withLock {
                    var pending = pendingFunctionCalls[callID] ?? PendingFunctionCall(name: "", argumentsJSON: "")
                    pending.argumentsJSON += delta
                    pendingFunctionCalls[callID] = pending
                }
            }

        case "response.function_call_arguments.done":
            // Final args + call name — dispatch the tool call.
            if let callID = envelope["call_id"] as? String,
               let name = envelope["name"] as? String,
               let argumentsJSON = envelope["arguments"] as? String {
                stateLock.withLock {
                    pendingFunctionCalls[callID] = PendingFunctionCall(name: name, argumentsJSON: argumentsJSON)
                }
                let parsed = parseToolArgs(argumentsJSON)
                dispatchEvent(.toolCall(id: callID, name: name, args: parsed))
            }

        case "response.done":
            // Reset transcript accumulators for the next turn. Tool calls
            // were already dispatched on .arguments.done above.
            stateLock.withLock {
                outputTranscriptAccumulator = ""
                pendingFunctionCalls.removeAll()
            }
            dispatchEvent(.turnComplete)

        case "error":
            let message = (envelope["error"] as? [String: Any])?["message"] as? String ?? "unknown error"
            let error = NSError(
                domain: "OpenAIRealtime",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
            print("[OpenAIRealtime] server error: \(message)")
            dispatchEvent(.error(error))

        default:
            // Many event types we don't act on (response.created,
            // response.output_item.done, rate_limits.updated, etc.)
            // are intentionally ignored.
            break
        }
    }

    private func parseToolArgs(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return parsed
    }

    private func dispatchEvent(_ event: OpenAIRealtimeEvent) {
        guard let onEvent else { return }
        DispatchQueue.main.async {
            onEvent(event)
        }
    }

    private func waitForSessionReady(timeoutSeconds: Double) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if isSessionReady { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        throw NSError(
            domain: "OpenAIRealtime",
            code: -4,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for session.updated"]
        )
    }
}
