//
//  VoiceBackend.swift
//  TipTour
//
//  Common surface that any realtime voice/vision backend must expose so
//  CompanionManager can drive it without caring whether the underlying
//  model is Gemini Live or OpenAI Realtime.
//
//  Both implementations are end-to-end "speech in, speech out" with
//  in-stream tool calling — the conceptual shape is the same. Wire-level
//  protocol details (event encoding, audio formats, tool envelopes) live
//  inside each backend's own client + session pair. CompanionManager
//  treats them as interchangeable through this protocol.
//

import Combine
import Foundation

/// What kind of realtime backend is providing voice + tools right now.
/// Persisted in UserDefaults so the user's choice survives restarts.
enum VoiceBackendKind: String, CaseIterable, Identifiable {
    case geminiLive
    case openaiRealtime

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .geminiLive: return "Gemini Live"
        case .openaiRealtime: return "OpenAI Realtime"
        }
    }

    /// UserDefaults key — single source of truth so the panel toggle,
    /// CompanionManager's lazy backend init, and any debugging code all
    /// agree on what's persisted.
    static let userDefaultsKey = "voiceBackendKind"
}

/// The minimal contract CompanionManager needs from a realtime backend.
/// All methods mutate session state, so the protocol is `@MainActor` —
/// the conforming classes already are. State is exposed as both raw
/// values (for one-shot reads) and Combine publishers (so CompanionManager
/// can subscribe to backend events through the protocol surface).
@MainActor
protocol VoiceBackend: AnyObject {

    // MARK: - State

    /// Whether the backend's WebSocket is currently open and a session is
    /// active. CompanionManager uses this to decide whether the
    /// push-to-talk hotkey opens or closes the connection.
    var isActive: Bool { get }

    /// Current mic power level (0.0–1.0) from the backend's own audio
    /// engine. Drives the waveform animation.
    var currentAudioPowerLevel: CGFloat { get }

    /// True while the model is producing speech this turn.
    var isModelSpeaking: Bool { get }

    /// True while there's still audio queued for playback locally.
    /// Used by the narration-exit logic to avoid cutting off the model
    /// mid-word when we resume mic input.
    var isAudioPlaying: Bool { get }

    /// The most recent screenshot the backend processed. CompanionManager
    /// reads this when resolving box_2d hints back to screen pixels — the
    /// model's coordinates are relative to whichever frame it last saw.
    var latestCapture: CompanionScreenCapture? { get }

    // MARK: - Publishers (for Combine-based observation)

    /// `$currentAudioPowerLevel` projected as a type-erased publisher so
    /// CompanionManager can subscribe without pinning to the concrete
    /// backend type.
    var currentAudioPowerLevelPublisher: AnyPublisher<CGFloat, Never> { get }

    /// `$isModelSpeaking` as a publisher — drives the cursor's responding/
    /// listening state transitions in CompanionManager.
    var isModelSpeakingPublisher: AnyPublisher<Bool, Never> { get }

    // MARK: - Callbacks

    /// Fired when the model calls `point_at_element(label, box_2d?)`.
    /// `box2DNormalized` is the optional bounding box in [y1, x1, y2, x2]
    /// form (each value in [0, 1000]) that Gemini and OpenAI both natively
    /// emit when asked to localize an on-screen element.
    var onPointAtElement: ((_ id: String, _ label: String, _ box2DNormalized: [Int]?, _ screenshotJPEG: Data?) async -> [String: Any])? { get set }

    /// Fired when the model calls `submit_workflow_plan(goal, app, steps)`.
    /// The handler hands off to WorkflowRunner and returns an ack.
    var onSubmitWorkflowPlan: ((_ id: String, _ goal: String, _ app: String, _ steps: [[String: Any]]) async -> [String: Any])? { get set }

    /// Fires whenever the model's accumulated output transcript grows.
    /// CompanionManager keeps a legacy [POINT:] tag parser on this stream
    /// as a fallback in case the model bypasses tool calling.
    var onOutputTranscript: ((String) -> Void)? { get set }

    /// Fires on every input-transcript update (the user's speech as the
    /// model heard it). Used to detect "a fresh utterance just began" so
    /// per-turn dedup state resets at the right moment.
    var onInputTranscriptUpdate: ((String) -> Void)? { get set }

    /// Fires when the model completes a turn.
    var onTurnComplete: (() -> Void)? { get set }

    /// Fires on fatal errors so the caller can surface them.
    var onError: ((Error) -> Void)? { get set }

    // MARK: - Lifecycle

    /// Open the WebSocket, run setup, start mic capture and screenshot
    /// streaming. Throws on auth/connection failures.
    func start(initialScreenshot: Data?) async throws

    /// Tear down the session: close the WebSocket, stop mic capture,
    /// drain any queued audio.
    func stop()

    /// Pause mic + screenshot streaming so the model can narrate a
    /// just-submitted plan without interrupting itself. The WebSocket
    /// stays open. Re-armed by `exitNarrationMode()`.
    func enterNarrationMode()

    /// Resume mic + screenshot streaming after narration mode.
    func exitNarrationMode()

    /// After a successful tool call, suppress further screenshot pushes
    /// until the user speaks again. Without this, the model sees frames
    /// where "user hasn't moved" and tends to re-emit the same tool call
    /// in a tight loop.
    func suppressScreenshotsUntilUserSpeaks()

    /// Drop any cached frame deduplication state so the next periodic
    /// tick is guaranteed to push a fresh screenshot. CompanionManager
    /// calls this when a tool call fails — the model may be working from
    /// a stale frame and we want it to re-look.
    func invalidateScreenshotHashCache()
}
