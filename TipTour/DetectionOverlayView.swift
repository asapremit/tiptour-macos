import SwiftUI

/// Draws native detector bounding boxes on the overlay.
/// Neon green boxes are CoreML UI detections; cyan boxes are Apple Vision OCR text.
struct DetectionOverlayView: View {
    let elements: [[String: Any]]
    let highlightedLabel: String?
    let screenFrame: CGRect
    let imageSize: [Int]  // [width, height] of the screenshot sent to YOLO

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let animationPhase = timeline.date.timeIntervalSinceReferenceDate
                let pulse = (sin(animationPhase * 2.2) + 1.0) / 2.0
                let imgW = CGFloat(imageSize.count >= 2 ? imageSize[0] : 1512)
                let imgH = CGFloat(imageSize.count >= 2 ? imageSize[1] : 982)
                let scaleX = screenFrame.width / imgW
                let scaleY = screenFrame.height / imgH

                for element in elements {
                    guard let bbox = element["bbox"] as? [Int], bbox.count == 4 else { continue }
                    let label = element["label"] as? String ?? ""
                    let conf = element["conf"] as? Double ?? 0
                    let source = element["source"] as? String ?? "yolo"
                    let isTextElement = source == "ocr"

                    let x1 = CGFloat(bbox[0]) * scaleX
                    let y1 = CGFloat(bbox[1]) * scaleY
                    let x2 = CGFloat(bbox[2]) * scaleX
                    let y2 = CGFloat(bbox[3]) * scaleY

                    let rect = CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
                    guard rect.width > 2, rect.height > 2 else { continue }

                    let isHighlighted = highlightedLabel != nil && label.lowercased().contains(highlightedLabel!.lowercased())
                    let neonGreen = Color(red: 0.22, green: 1.0, blue: 0.18)
                    let neonCyan = Color(red: 0.24, green: 0.92, blue: 1.0)
                    let hotPink = Color(red: 1.0, green: 0.28, blue: 0.42)
                    let defaultBoxColor: Color = isTextElement ? neonCyan : neonGreen
                    let boxColor: Color = isHighlighted ? hotPink : defaultBoxColor
                    let strokeOpacity: Double = isHighlighted ? 0.9 : (isTextElement ? 0.45 : 0.58)
                    let baseLineWidth: CGFloat = isHighlighted ? 2.0 : (isTextElement ? 0.75 : 0.9)
                    let glowOpacity = (isHighlighted ? 0.18 : 0.055) + pulse * 0.045

                    let roundedRectPath = Path(roundedRect: rect, cornerRadius: isTextElement ? 4 : 6)

                    context.stroke(
                        roundedRectPath,
                        with: .color(boxColor.opacity(glowOpacity)),
                        lineWidth: baseLineWidth + 3.8
                    )
                    context.stroke(
                        roundedRectPath,
                        with: .color(boxColor.opacity(glowOpacity + 0.06)),
                        lineWidth: baseLineWidth + 1.6
                    )

                    context.fill(
                        roundedRectPath,
                        with: .color(boxColor.opacity(isHighlighted ? 0.08 : 0.018))
                    )

                    context.stroke(
                        roundedRectPath,
                        with: .color(boxColor.opacity(strokeOpacity)),
                        lineWidth: baseLineWidth
                    )

                    drawCornerBrackets(in: &context, rect: rect, color: boxColor, opacity: strokeOpacity, lineWidth: baseLineWidth + 0.25)

                    if isHighlighted || (!label.isEmpty && rect.width >= 42 && rect.height >= 12) {
                        let displayText = label.isEmpty ? "" : label
                        guard !displayText.isEmpty || isHighlighted else { continue }
                        let fontSize: CGFloat = isHighlighted ? 9.5 : 7.5
                        let textColor: Color = isHighlighted ? .white : boxColor.opacity(0.9)
                        let textWidth = min(CGFloat(displayText.count) * fontSize * 0.58 + 14, max(58, screenFrame.width - x1 - 8))
                        let textSize = CGSize(width: textWidth, height: fontSize + 7)
                        let textRect = CGRect(
                            x: min(x1, max(0, screenFrame.width - textSize.width - 6)),
                            y: max(2, y1 - textSize.height - 4),
                            width: textSize.width,
                            height: textSize.height
                        )

                        context.fill(
                            Path(roundedRect: textRect, cornerRadius: 5),
                            with: .color(.black.opacity(isHighlighted ? 0.72 : 0.48))
                        )
                        context.stroke(
                            Path(roundedRect: textRect, cornerRadius: 5),
                            with: .color(boxColor.opacity(isHighlighted ? 0.76 : 0.28)),
                            lineWidth: 0.55
                        )

                        context.fill(
                            Path(
                                roundedRect: CGRect(x: textRect.minX, y: textRect.minY, width: 4, height: textRect.height),
                                cornerRadius: 2
                            ),
                            with: .color(boxColor.opacity(isHighlighted ? 0.85 : 0.55))
                        )

                        context.draw(
                            Text(displayText)
                                .font(.system(size: fontSize, weight: isHighlighted ? .bold : .semibold, design: .monospaced))
                                .foregroundColor(textColor),
                            at: CGPoint(x: textRect.midX + 3, y: textRect.midY)
                        )
                    }

                    if conf > 0.5 && !isHighlighted {
                        let dotSize: CGFloat = isTextElement ? 2.2 : 3.0
                        context.fill(
                            Path(ellipseIn: CGRect(x: x2 - dotSize - 2, y: y1 + 2, width: dotSize, height: dotSize)),
                            with: .color(boxColor.opacity(0.86))
                        )
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.3), value: elements.count)
    }

    private func drawCornerBrackets(
        in context: inout GraphicsContext,
        rect: CGRect,
        color: Color,
        opacity: Double,
        lineWidth: CGFloat
    ) {
        let bracketLength = min(max(min(rect.width, rect.height) * 0.28, 8), 18)
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY + bracketLength))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + bracketLength, y: rect.minY))

        path.move(to: CGPoint(x: rect.maxX - bracketLength, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + bracketLength))

        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - bracketLength))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - bracketLength, y: rect.maxY))

        path.move(to: CGPoint(x: rect.minX + bracketLength, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - bracketLength))

        context.stroke(path, with: .color(color.opacity(opacity)), lineWidth: lineWidth)
    }
}
