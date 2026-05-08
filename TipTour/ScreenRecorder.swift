//
//  ScreenRecorder.swift
//  TipTour
//
//  Records the main display to an .mov file using ScreenCaptureKit +
//  AVAssetWriter. Used by the workflow walkthrough feature to save a
//  video the user can replay or share — TipTour shows them how, the
//  recorder lets them keep it.
//
//  Design notes (lessons borrowed from a more complex recorder):
//    • One serial output queue. ScreenCaptureKit sample buffers MUST be
//      processed in order — dispatching them onto MainActor via Task
//      breaks FIFO ordering and causes AVAssetWriter to fail with
//      status 3 (`.failed`) on busy systems.
//    • Width and height are aligned to multiples of 16. Some hardware
//      H.264 encoders silently fail on odd dimensions even when the
//      framework advertises support.
//    • H.264 first, H.265 (HEVC) fallback. H.264 is the universal
//      replay format; HEVC is only used when the system rejects H.264
//      (rare, but happens on some external display + scaled-Retina
//      combinations).
//    • Our own overlay panel + menu bar UI are excluded from the
//      capture via `SCContentFilter(display:excludingWindows:)`. Without
//      this, the recording would show the cursor flying past TipTour's
//      own UI in a meta-loop.
//    • Writer state lives on a `@unchecked Sendable` `WriterContext` so
//      sample-buffer callbacks (which arrive on a non-main queue) can
//      append frames in order without crossing actor boundaries. This
//      is the same pattern that fixes the AVAssetWriter ordering race
//      Vellum's recorder hit.
//
//  This recorder is intentionally minimal: main display only, no
//  per-window or per-app variants, no microphone or system-audio mux.
//  Add those by extending `RecordingConfiguration` if/when the product
//  needs them — keeping the surface small now keeps every code path
//  testable by hand.
//

import AppKit
import AVFoundation
import Foundation
import ScreenCaptureKit

/// Result returned to the caller when a recording finishes successfully.
struct ScreenRecordingResult: Sendable {
    /// Absolute file path of the saved .mov.
    let fileURL: URL
    /// Wall-clock duration of the recording in milliseconds.
    let durationMilliseconds: Int
    /// Codec actually used (logs / debug; the user shouldn't need this).
    let codec: AVVideoCodecType
}

/// Errors the recorder can surface to its caller.
enum ScreenRecorderError: Error, LocalizedError {
    case noMainDisplayAvailable
    case screenRecordingPermissionDenied
    case streamFailedToStart(underlyingDescription: String)
    case writerSetupFailed(underlyingDescription: String)
    case noFramesCaptured
    case writerFinishedWithFailure(underlyingDescription: String?)
    case allCodecFallbacksExhausted
    case alreadyRecording
    case notRecording

    var errorDescription: String? {
        switch self {
        case .noMainDisplayAvailable:
            return "Couldn't find a main display to record."
        case .screenRecordingPermissionDenied:
            return "Screen Recording permission is required."
        case .streamFailedToStart(let reason):
            return "Failed to start screen capture: \(reason)"
        case .writerSetupFailed(let reason):
            return "Couldn't set up the video writer: \(reason)"
        case .noFramesCaptured:
            return "Recording produced no video frames."
        case .writerFinishedWithFailure(let reason):
            return "Writer finished with failure: \(reason ?? "unknown")"
        case .allCodecFallbacksExhausted:
            return "Could not record with any supported codec."
        case .alreadyRecording:
            return "A recording is already in progress."
        case .notRecording:
            return "No active recording to stop."
        }
    }
}

// MARK: - Writer Context (cross-thread state)

/// Holds the AVAssetWriter + input + first-frame state. Safe to read
/// from the SCStream sample-buffer queue and the MainActor recorder
/// without crossing actor boundaries — `AVAssetWriterInput.append` is
/// already thread-safe; the only thing we serialize manually is the
/// first-frame `startSession` call.
final class ScreenRecorderWriterContext: @unchecked Sendable {
    let writer: AVAssetWriter
    let videoInput: AVAssetWriterInput

    private let lock = NSLock()
    private var didStartSession: Bool = false
    private var hasReceivedFirstVideoFrame: Bool = false

    init(writer: AVAssetWriter, videoInput: AVAssetWriterInput) {
        self.writer = writer
        self.videoInput = videoInput
    }

    /// Start the writer's media session at the given timestamp on the
    /// very first frame. Returns true if the session was started by
    /// this call (so the caller knows it was the first frame).
    @discardableResult
    func startSessionIfNeeded(atSourceTime presentationTimestamp: CMTime) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didStartSession else { return false }
        writer.startSession(atSourceTime: presentationTimestamp)
        didStartSession = true
        hasReceivedFirstVideoFrame = true
        return true
    }

    /// True after the writer has accepted at least one video frame.
    /// Used by the recorder to detect "recording produced nothing"
    /// situations.
    var didReceiveAnyFrame: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasReceivedFirstVideoFrame
    }
}

// MARK: - Stream Output Receiver (off-main delegate)

/// `SCStreamOutput` receives buffers on a dispatch queue, not on
/// MainActor. Splitting the delegate into its own `nonisolated` object
/// lets the recorder stay `@MainActor` for its public API while the
/// hot-path append calls run on the capture queue with zero hops.
final class ScreenRecorderStreamOutputReceiver: NSObject, SCStreamOutput, SCStreamDelegate {
    private let writerContext: ScreenRecorderWriterContext

    init(writerContext: ScreenRecorderWriterContext) {
        self.writerContext = writerContext
        super.init()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard writerContext.videoInput.isReadyForMoreMediaData else { return }

        let presentationTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        writerContext.startSessionIfNeeded(atSourceTime: presentationTimestamp)
        writerContext.videoInput.append(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[ScreenRecorder] stream stopped with error: \(error.localizedDescription)")
    }
}

// MARK: - Recorder

/// Records the main display to a .mov on disk. Single-shot lifecycle
/// per instance: `start()` once, `stop()` once. Reuse a fresh
/// `ScreenRecorder` for each new recording.
@MainActor
final class ScreenRecorder {

    /// Where finished recordings land. Lazy-created on first start.
    static let recordingsDirectory: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("TipTour", isDirectory: true)
            .appendingPathComponent("recordings", isDirectory: true)
    }()

    private(set) var isRecording: Bool = false
    private(set) var outputFileURL: URL?

    private var stream: SCStream?
    private var writerContext: ScreenRecorderWriterContext?
    private var streamOutputReceiver: ScreenRecorderStreamOutputReceiver?

    /// Serial queue ScreenCaptureKit hands sample buffers off on. Single
    /// queue → single ordered write path → no FIFO race against the
    /// writer.
    private let sampleBufferOutputQueue = DispatchQueue(
        label: "tiptour.screenrecorder.output",
        qos: .userInitiated
    )

    /// Wall-clock start so `durationMilliseconds` doesn't depend on
    /// CMTime arithmetic if the writer reports something weird.
    private var wallClockStart: Date?

    /// Codec actually used for the active recording. Set in start().
    private var activeCodec: AVVideoCodecType = .h264

    // MARK: - Public API

    /// Begin recording the main display. Returns the output file URL
    /// once the stream is up; throws on permission failure, codec
    /// exhaustion, or writer setup error.
    ///
    /// `windowsToExclude` lets the caller scrub their own UI (overlay
    /// panel, menu bar window, source picker) out of the recording.
    func start(
        windowsToExclude: [SCWindow] = []
    ) async throws -> URL {
        guard !isRecording else {
            throw ScreenRecorderError.alreadyRecording
        }

        // Make sure the directory exists. Created lazily on first start
        // so a user who never records doesn't end up with empty dirs.
        try FileManager.default.createDirectory(
            at: Self.recordingsDirectory,
            withIntermediateDirectories: true
        )

        // Probe ScreenCaptureKit for the main display. If the user
        // hasn't granted Screen Recording permission this throws —
        // surface it as a typed error the caller can show in UI.
        let shareableContent: SCShareableContent
        do {
            shareableContent = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            throw ScreenRecorderError.screenRecordingPermissionDenied
        }

        guard let mainDisplay = shareableContent.displays.first(where: {
            $0.displayID == CGMainDisplayID()
        }) ?? shareableContent.displays.first else {
            throw ScreenRecorderError.noMainDisplayAvailable
        }

        let outputURL = Self.recordingsDirectory
            .appendingPathComponent("\(UUID().uuidString).mov")
        // Pre-delete in case of a stale leftover with the same name.
        try? FileManager.default.removeItem(at: outputURL)

        // Codec fallback ladder. H.264 covers ~99% of real-world
        // configurations; HEVC handles the edge cases where the system's
        // video toolbox refuses H.264 (very large external displays,
        // some scaled-Retina modes).
        let codecsToTry: [AVVideoCodecType] = [.h264, .hevc]
        var lastSetupError: Error?

        for codec in codecsToTry {
            do {
                try await self.startSession(
                    forDisplay: mainDisplay,
                    excludingWindows: windowsToExclude,
                    outputURL: outputURL,
                    codec: codec
                )
                self.activeCodec = codec
                self.outputFileURL = outputURL
                self.isRecording = true
                self.wallClockStart = Date()
                print("[ScreenRecorder] started — \(outputURL.lastPathComponent) — codec=\(codec.rawValue)")
                return outputURL
            } catch {
                lastSetupError = error
                print("[ScreenRecorder] codec \(codec.rawValue) failed: \(error.localizedDescription) — trying next")
                await teardownStreamAndWriter()
            }
        }

        if let lastSetupError {
            throw lastSetupError
        }
        throw ScreenRecorderError.allCodecFallbacksExhausted
    }

    /// Stop the active recording and return the file URL + duration.
    /// Throws if there's no active recording or the writer surfaces a
    /// failure during finalization.
    func stop() async throws -> ScreenRecordingResult {
        guard isRecording, let writerContext, let outputFileURL else {
            throw ScreenRecorderError.notRecording
        }
        let codec = activeCodec
        let startedAt = wallClockStart ?? Date()

        // Tear down the capture stream first so no further sample
        // buffers are queued against an input we're about to mark
        // finished.
        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }

        // Finalize the writer on the same serial queue the output
        // delegate uses, so any already-queued buffers drain in order
        // before `markAsFinished` lands. Without this the last few
        // frames can race past the finish call.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sampleBufferOutputQueue.async {
                writerContext.videoInput.markAsFinished()
                continuation.resume()
            }
        }

        await writerContext.writer.finishWriting()

        if writerContext.writer.status != .completed {
            let underlying = writerContext.writer.error?.localizedDescription
            print("[ScreenRecorder] ✗ writer status \(writerContext.writer.status.rawValue) — \(underlying ?? "no error description")")
            self.isRecording = false
            await teardownStreamAndWriter()
            throw ScreenRecorderError.writerFinishedWithFailure(
                underlyingDescription: underlying
            )
        }

        if !writerContext.didReceiveAnyFrame {
            self.isRecording = false
            await teardownStreamAndWriter()
            throw ScreenRecorderError.noFramesCaptured
        }

        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        let result = ScreenRecordingResult(
            fileURL: outputFileURL,
            durationMilliseconds: durationMs,
            codec: codec
        )
        print("[ScreenRecorder] ✓ stopped — \(outputFileURL.lastPathComponent) — \(durationMs)ms")
        self.isRecording = false
        await teardownStreamAndWriter()
        return result
    }

    // MARK: - Internal Setup

    /// Configure SCStream + AVAssetWriter for one codec attempt. Throws
    /// on permission/setup failure so the caller can fall back to the
    /// next codec.
    private func startSession(
        forDisplay display: SCDisplay,
        excludingWindows: [SCWindow],
        outputURL: URL,
        codec: AVVideoCodecType
    ) async throws {
        // Compute the recording dimensions, aligned to multiples of 16.
        // Some hardware H.264 encoders silently produce broken files at
        // unaligned widths (1920 fine, 1921 not). Using `display.width`
        // and `display.height` gives us the display's pixel dimensions
        // in the capture's native scale.
        let alignedWidth = (display.width / 16) * 16
        let alignedHeight = (display.height / 16) * 16
        guard alignedWidth > 0, alignedHeight > 0 else {
            throw ScreenRecorderError.writerSetupFailed(
                underlyingDescription: "display has zero dimensions"
            )
        }

        // 1. AVAssetWriter — produces the .mov on disk.
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        } catch {
            throw ScreenRecorderError.writerSetupFailed(
                underlyingDescription: error.localizedDescription
            )
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: alignedWidth,
            AVVideoHeightKey: alignedHeight,
            // 8 Mbps target — sweet spot for screen capture; spikes
            // during animation, idle text drops below.
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 8_000_000,
                AVVideoMaxKeyFrameIntervalKey: 60
            ]
        ]
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: videoSettings
        )
        videoInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoInput) else {
            throw ScreenRecorderError.writerSetupFailed(
                underlyingDescription: "writer rejected codec \(codec.rawValue) for \(alignedWidth)x\(alignedHeight)"
            )
        }
        writer.add(videoInput)

        guard writer.startWriting() else {
            throw ScreenRecorderError.writerSetupFailed(
                underlyingDescription: writer.error?.localizedDescription ?? "writer.startWriting() returned false"
            )
        }

        let context = ScreenRecorderWriterContext(
            writer: writer,
            videoInput: videoInput
        )
        let receiver = ScreenRecorderStreamOutputReceiver(writerContext: context)

        // 2. SCStream — feeds video sample buffers into our delegate.
        let filter = SCContentFilter(
            display: display,
            excludingWindows: excludingWindows
        )
        let configuration = SCStreamConfiguration()
        configuration.width = alignedWidth
        configuration.height = alignedHeight
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 8
        configuration.showsCursor = true
        // Don't capture audio at the framework level — we don't write an
        // audio track. Saves CPU and keeps the .mov video-only.
        configuration.capturesAudio = false

        let stream = SCStream(
            filter: filter,
            configuration: configuration,
            delegate: receiver
        )

        do {
            try stream.addStreamOutput(
                receiver,
                type: .screen,
                sampleHandlerQueue: sampleBufferOutputQueue
            )
        } catch {
            throw ScreenRecorderError.streamFailedToStart(
                underlyingDescription: error.localizedDescription
            )
        }

        // Awaiting startCapture means by the time start() returns, the
        // stream is wired up and frames are already being queued — the
        // caller can rely on "isRecording == true" being meaningful.
        do {
            try await stream.startCapture()
        } catch {
            throw ScreenRecorderError.streamFailedToStart(
                underlyingDescription: error.localizedDescription
            )
        }

        self.writerContext = context
        self.streamOutputReceiver = receiver
        self.stream = stream
    }

    /// Reset internal state after a stop or failed start.
    private func teardownStreamAndWriter() async {
        if let stream {
            try? await stream.stopCapture()
        }
        self.stream = nil
        self.writerContext = nil
        self.streamOutputReceiver = nil
        self.wallClockStart = nil
    }
}
