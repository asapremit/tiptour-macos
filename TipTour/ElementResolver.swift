//
//  ElementResolver.swift
//  TipTour
//
//  Single entry point for "where on screen should the cursor fly to?"
//
//  Tries two lookup strategies in order of reliability:
//    1. macOS Accessibility tree (~30ms, pixel-perfect when the app
//       supports AX — almost all native Mac apps, most Cocoa third-party
//       apps, and Electron apps that respect AXManualAccessibility).
//    2. Raw Gemini-emitted box_2d coordinates as the absolute fallback.
//       These come from the same model that named the element, so they
//       reflect Gemini's spatial intent for that exact tool call.
//
//  The on-device YOLO + OCR visual detector that previously sat between
//  these two tiers has been removed: the model's box_2d output covers
//  the same fallback role with strictly better accuracy (one model, one
//  decision, no fuzzy text-match drift), and the YOLO weights carried
//  AGPL-3 distribution constraints we no longer want to ship with.
//
//  The resolver returns a global AppKit screen coordinate so the cursor
//  overlay can fly to it without further conversion.
//

import AppKit
import Foundation

final class ElementResolver: @unchecked Sendable {

    static let shared = ElementResolver()

    private let axResolver = AccessibilityTreeResolver()

    // MARK: - Public Types

    /// Where the resolved coordinate came from — useful for logging and
    /// telling the cursor what confidence to render with.
    enum ResolutionSource {
        case accessibilityTree       // AX tree gave us exact frame
        case llmRawCoordinates       // Straight from Gemini's box_2d, no refinement
    }

    struct Resolution {
        /// Global AppKit-space coordinate — ready to pass to the overlay.
        let globalScreenPoint: CGPoint
        /// The display the point is on.
        let displayFrame: CGRect
        /// Human-readable label describing what was pointed at.
        let label: String
        /// Where the resolution came from — for logging/telemetry.
        let source: ResolutionSource
        /// Global AppKit-space rect for the matched element, when the
        /// resolution source can produce one. AX always gives us this
        /// (pixel-perfect). Raw box_2d does not — the click detector
        /// falls back to a radius around `globalScreenPoint` when this
        /// is nil.
        let globalScreenRect: CGRect?
    }

    // MARK: - Resolution

    /// Try AX tree only. Runs on a background task so the walk doesn't
    /// block main. Returns nil if AX has no match for the label.
    /// `targetAppHint` (e.g. "Blender") lets us query the app the user
    /// is actually looking at when the system's focused app is a
    /// background recorder like Cap.
    func tryAccessibilityTree(label: String, targetAppHint: String? = nil) async -> Resolution? {
        let axResolverRef = axResolver
        let axResult = await Task.detached(priority: .userInitiated) {
            return axResolverRef.findElement(byLabel: label, targetAppHint: targetAppHint)
        }.value

        guard let axResult else { return nil }

        let globalPoint = await MainActor.run {
            displayFrameContaining(axResult.center) ?? axResult.screenFrame
        }
        print("[ElementResolver] ✓ AX matched \"\(label)\" → \"\(axResult.title)\" [\(axResult.role)] at \(axResult.center)")
        return Resolution(
            globalScreenPoint: axResult.center,
            displayFrame: globalPoint,
            label: label,
            source: .accessibilityTree,
            globalScreenRect: axResult.screenFrame
        )
    }

    /// Absolute last resort — use Gemini's raw box_2d coordinate as-is.
    func rawLLMCoordinate(
        label: String,
        llmHintInScreenshotPixels: CGPoint,
        capture: CompanionScreenCapture
    ) -> Resolution {
        let globalPoint = screenshotPixelToGlobalScreen(llmHintInScreenshotPixels, capture: capture)
        print("[ElementResolver] ⚠ using raw LLM coords for \"\(label)\" → screen \(globalPoint)")
        return Resolution(
            globalScreenPoint: globalPoint,
            displayFrame: capture.displayFrame,
            label: label,
            source: .llmRawCoordinates,
            globalScreenRect: nil
        )
    }

    /// Poll the AX tree repeatedly for up to `timeoutSeconds` waiting
    /// for `label` to appear. Returns the first successful resolution.
    /// Used by the workflow runner to wait for a newly-opened menu or
    /// sheet to settle after a click, instead of sleeping a fixed time.
    /// Polling is cheap (~20-40ms per tick) and exits early on match.
    func pollAccessibilityTree(
        label: String,
        targetAppHint: String?,
        timeoutSeconds: Double,
        pollIntervalSeconds: Double = 0.08
    ) async -> Resolution? {
        // Short-circuit for apps we already know don't expose an AX
        // tree (Blender, Unity, games). Saves up to a full `timeoutSeconds`
        // of wasted polling per step AND the CPU churn that causes
        // audio underruns in the Gemini Live output stream.
        if AccessibilityTreeResolver.isAppKnownToLackAXTree(hint: targetAppHint) {
            print("[AX] skipping poll for \"\(label)\" — app \"\(targetAppHint ?? "?")\" flagged as no-AX-tree")
            return nil
        }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let hit = await tryAccessibilityTree(label: label, targetAppHint: targetAppHint) {
                return hit
            }
            try? await Task.sleep(nanoseconds: UInt64(pollIntervalSeconds * 1_000_000_000))
        }
        return nil
    }

    /// Full resolution pipeline: AX → box_2d, tried in order with early
    /// exit.
    ///
    /// Tier order is deliberate:
    ///   1. AX tree first. Pixel-perfect when the app exposes one, and
    ///      it's the only path that gives us a real element rect for
    ///      the click detector to use as a tight hit region.
    ///   2. Gemini's box_2d second. Those coordinates are the model's
    ///      spatial output for the same query that emitted the label
    ///      — one model, one decision. They reflect everything Gemini
    ///      knew about the image at tool-call time: semantic
    ///      understanding, disambiguation between same-text elements,
    ///      and pixel grounding from a model trained natively on
    ///      box_2d output.
    ///
    /// If AX misses and Gemini didn't emit a box_2d, we have nothing
    /// usable and return nil — the caller surfaces this to the user
    /// rather than silently flying the cursor to a wrong location.
    func resolve(
        label: String,
        llmHintInScreenshotPixels: CGPoint?,
        latestCapture: CompanionScreenCapture?,
        targetAppHint: String? = nil,
        proximityAnchorInGlobalScreen: CGPoint? = nil
    ) async -> Resolution? {

        // Staleness check on the screenshot — resolving against a frame
        // >1s old means the cursor is likely to land on an element that
        // has moved or disappeared. Log so it shows up in traces; don't
        // block, because even a stale frame often works.
        if let capture = latestCapture {
            let ageSeconds = Date().timeIntervalSince(capture.captureTimestamp)
            if ageSeconds > 1.0 {
                print("[ElementResolver] ⚠ screenshot is \(String(format: "%.2f", ageSeconds))s old — coords may have drifted for \"\(label)\"")
            }
        }

        // 1. AX tree first — fastest and most reliable for native apps.
        //    Target app hint lets us bypass the system's "frontmost" when
        //    that's a background recorder (Cap) instead of the app the
        //    user is actually working in (e.g. Blender).
        //
        //    Skip the walk entirely when we've already learned this app
        //    has no AX tree (Blender/games/canvas apps). Saves 30-300ms
        //    of wasted IPC on every subsequent pointing call and — more
        //    importantly — the CPU that walk would burn while Gemini's
        //    audio is streaming.
        if !AccessibilityTreeResolver.isAppKnownToLackAXTree(hint: targetAppHint) {
            if let axResolution = await tryAccessibilityTree(label: label, targetAppHint: targetAppHint) {
                return axResolution
            }

            // Multilingual safety net: AX missed because the user's
            // spoken language doesn't match the UI's display language
            // (Gemini sometimes passes "Guardar" to a UI that has
            // "Save", or vice versa). Pull the current AX label list
            // and ask the worker which one matches semantically. Cheap
            // (gemini-flash-lite, ~200ms) and only runs when the
            // strict matcher already failed.
            if let translatedLabel = await translateLabelViaSemanticMatch(
                originalLabel: label,
                targetAppHint: targetAppHint
            ),
               translatedLabel.caseInsensitiveCompare(label) != .orderedSame,
               let axResolution = await tryAccessibilityTree(
                   label: translatedLabel,
                   targetAppHint: targetAppHint
               ) {
                print("[ElementResolver] ✓ multilingual fallback resolved \"\(label)\" → \"\(translatedLabel)\"")
                return axResolution
            }
        }

        guard let capture = latestCapture else {
            print("[ElementResolver] ✗ no AX match and no screenshot capture — giving up on \"\(label)\"")
            return nil
        }

        // 2. Trust the model's box_2d when it gave us one. This is
        //    Gemini's spatial output for the same query that emitted
        //    the label — one model, one decision.
        if let hint = llmHintInScreenshotPixels {
            return rawLLMCoordinate(
                label: label,
                llmHintInScreenshotPixels: hint,
                capture: capture
            )
        }

        print("[ElementResolver] ✗ could not resolve \"\(label)\" — AX missed and no box_2d hint")
        return nil
    }

    // MARK: - Multilingual Fallback

    /// When AX exact-match fails because the user's spoken language
    /// doesn't match the UI's display language (e.g. user said "guardar"
    /// but the UI shows "Save"), pull the current AX label list and ask
    /// the worker which candidate matches the user's intent semantically.
    ///
    /// Returns nil when the worker has nothing confident to suggest, the
    /// network call fails, or no AX labels could be collected.
    private func translateLabelViaSemanticMatch(
        originalLabel: String,
        targetAppHint: String?
    ) async -> String? {
        // Pull the same set-of-marks list we'd send to Gemini. Off-main
        // because the AX walk can take a few hundred ms on complex apps.
        let marks: [AccessibilityTreeResolver.ElementMark]? = await Task.detached(priority: .userInitiated) {
            self.axResolver.setOfMarksForTargetApp(hint: targetAppHint)
        }.value

        guard let marks = marks, !marks.isEmpty else {
            return nil
        }

        // Dedup labels (multiple AX nodes can have the same title) and
        // drop empty/whitespace-only ones.
        let candidateLabels: [String] = {
            var seen = Set<String>()
            var ordered: [String] = []
            for mark in marks {
                let trimmed = mark.label.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                if seen.insert(trimmed).inserted {
                    ordered.append(trimmed)
                }
            }
            return ordered
        }()

        guard !candidateLabels.isEmpty else { return nil }

        guard let workerBaseURL = Self.workerBaseURLOverride
                ?? Self.defaultWorkerBaseURL else {
            return nil
        }
        guard let endpoint = URL(string: "\(workerBaseURL)/match-label") else {
            return nil
        }

        struct MatchLabelRequest: Encodable {
            let query: String
            let candidates: [String]
        }
        struct GeminiEnvelope: Decodable {
            struct Candidate: Decodable {
                struct Content: Decodable {
                    struct Part: Decodable { let text: String? }
                    let parts: [Part]?
                }
                let content: Content?
            }
            let candidates: [Candidate]?
        }
        struct InnerMatch: Decodable { let match: String? }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        do {
            request.httpBody = try JSONEncoder().encode(MatchLabelRequest(
                query: originalLabel,
                candidates: candidateLabels
            ))
        } catch {
            return nil
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                return nil
            }
            let envelope = try JSONDecoder().decode(GeminiEnvelope.self, from: data)
            let innerJSONText = envelope.candidates?.first?.content?.parts?.first?.text ?? "{}"
            guard let innerData = innerJSONText.data(using: .utf8) else { return nil }
            let inner = (try? JSONDecoder().decode(InnerMatch.self, from: innerData)) ?? InnerMatch(match: nil)
            return inner.match
        } catch {
            return nil
        }
    }

    /// Worker base URL — kept in sync with CompanionManager's via the
    /// override hook below. CompanionManager calls
    /// `ElementResolver.workerBaseURLOverride = ...` at launch so we
    /// don't have to re-implement the build-config plumbing here.
    nonisolated(unsafe) static var workerBaseURLOverride: String?
    /// Fallback if no override has been set yet (very early calls).
    /// Matches CompanionManager.workerBaseURL by convention.
    private static let defaultWorkerBaseURL: String? = "https://clicky-proxy.milindsoni201.workers.dev"

    // MARK: - Coordinate Conversion

    /// Convert a point in screenshot pixel space (top-left origin) to
    /// global AppKit screen coordinates (bottom-left origin, spans all displays).
    /// Uses the capture's metadata (display frame, pixel dimensions) to scale.
    private func screenshotPixelToGlobalScreen(_ pixel: CGPoint, capture: CompanionScreenCapture) -> CGPoint {
        let screenshotWidth = CGFloat(capture.screenshotWidthInPixels)
        let screenshotHeight = CGFloat(capture.screenshotHeightInPixels)
        let displayWidth = CGFloat(capture.displayWidthInPoints)
        let displayHeight = CGFloat(capture.displayHeightInPoints)
        let displayFrame = capture.displayFrame

        let clampedX = max(0, min(pixel.x, screenshotWidth))
        let clampedY = max(0, min(pixel.y, screenshotHeight))

        let displayLocalX = clampedX * (displayWidth / screenshotWidth)
        let displayLocalY = clampedY * (displayHeight / screenshotHeight)
        let appKitY = displayHeight - displayLocalY

        return CGPoint(
            x: displayLocalX + displayFrame.origin.x,
            y: appKitY + displayFrame.origin.y
        )
    }

    /// Find the NSScreen whose frame contains the given global AppKit point.
    private func displayFrameContaining(_ globalPoint: CGPoint) -> CGRect? {
        for screen in NSScreen.screens {
            if screen.frame.contains(globalPoint) {
                return screen.frame
            }
        }
        return nil
    }
}
