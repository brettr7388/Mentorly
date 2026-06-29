//
//  ScreenshotAnnotation.swift
//  ILearn
//
//  Turns Claude's answer into a marked-up screenshot. Claude embeds annotation
//  tags in its reply ([ARROW], [BOX], [STEP]) using a scale-invariant 0–1000
//  normalized grid (0,0 = top-left, 1000,1000 = bottom-right of the image) so we
//  can draw arrows, highlight boxes, and numbered steps directly onto the image
//  and show the user exactly what to look at, rather than only describing it.
//
//  The grid is normalized (not raw pixels) on purpose: the vision model sees a
//  downscaled copy of the screenshot, so pixel coordinates it emits land in the
//  wrong place. A 0–1000 grid is independent of the actual capture resolution —
//  we scale it back to native pixels here at render time — which keeps marks
//  aligned no matter how large the captured region is.
//

import AppKit
import Foundation

/// A single visual mark Claude asked us to draw on the captured screenshot.
/// As parsed, all coordinates are in the 0–1000 normalized grid (origin
/// top-left, x rightward, y downward) that we tell Claude to use; the renderer
/// scales them to native pixels before drawing.
enum ScreenshotAnnotation {
    /// An arrow pointing at a single spot, with a short label.
    case arrow(point: CGPoint, label: String)
    /// A rectangle highlighting a region, with a short label.
    case box(rect: CGRect, label: String)
    /// A numbered step in a how-to sequence, anchored at a spot, with the
    /// instruction text for that step.
    case step(number: Int, point: CGPoint, instruction: String)
}

/// Parses Claude's annotation tags out of its reply and strips them so the
/// user only sees clean prose. See `companionAskResponseSystemPrompt` for the
/// grammar Claude is instructed to emit.
enum ScreenshotAnnotationParser {
    // [ARROW:x,y:label] — the separator between numbers may be a comma or colon
    // (the model sometimes emits one for the other); [,:] tolerates both.
    private static let arrowPattern = #"\[ARROW:\s*(\d+)\s*[,:]\s*(\d+)\s*:\s*([^\]]*)\]"#
    // [BOX:x1,y1,x2,y2:label] — tolerate comma OR colon between any of the four numbers.
    private static let boxPattern = #"\[BOX:\s*(\d+)\s*[,:]\s*(\d+)\s*[,:]\s*(\d+)\s*[,:]\s*(\d+)\s*:\s*([^\]]*)\]"#
    // [STEP:n:x,y:instruction]
    private static let stepPattern = #"\[STEP:\s*(\d+)\s*:\s*(\d+)\s*[,:]\s*(\d+)\s*:\s*([^\]]*)\]"#
    // Catch-all: any [ARROW/BOX/STEP …] bracket, however malformed inside. Used
    // only for stripping so a tag we couldn't parse into a mark still never
    // shows up as raw text in the answer.
    private static let anyTagPattern = #"\[(?:ARROW|BOX|STEP)[^\]]*\]"#

    /// Extracts every annotation tag and returns the reply with all tags
    /// removed (so it can be shown as plain text) plus the parsed annotations.
    static func parse(from responseText: String) -> (cleanText: String, annotations: [ScreenshotAnnotation]) {
        var annotations: [ScreenshotAnnotation] = []

        let fullRange = NSRange(responseText.startIndex..., in: responseText)

        if let arrowRegex = try? NSRegularExpression(pattern: arrowPattern) {
            for match in arrowRegex.matches(in: responseText, range: fullRange) {
                guard let x = intGroup(match, 1, responseText),
                      let y = intGroup(match, 2, responseText) else { continue }
                let label = stringGroup(match, 3, responseText)
                annotations.append(.arrow(point: CGPoint(x: x, y: y), label: label))
            }
        }

        if let boxRegex = try? NSRegularExpression(pattern: boxPattern) {
            for match in boxRegex.matches(in: responseText, range: fullRange) {
                guard let x1 = intGroup(match, 1, responseText),
                      let y1 = intGroup(match, 2, responseText),
                      let x2 = intGroup(match, 3, responseText),
                      let y2 = intGroup(match, 4, responseText) else { continue }
                let label = stringGroup(match, 5, responseText)
                let rect = CGRect(
                    x: CGFloat(min(x1, x2)),
                    y: CGFloat(min(y1, y2)),
                    width: CGFloat(abs(x2 - x1)),
                    height: CGFloat(abs(y2 - y1))
                )
                annotations.append(.box(rect: rect, label: label))
            }
        }

        if let stepRegex = try? NSRegularExpression(pattern: stepPattern) {
            for match in stepRegex.matches(in: responseText, range: fullRange) {
                guard let number = intGroup(match, 1, responseText),
                      let x = intGroup(match, 2, responseText),
                      let y = intGroup(match, 3, responseText) else { continue }
                let instruction = stringGroup(match, 4, responseText)
                annotations.append(.step(number: number, point: CGPoint(x: x, y: y), instruction: instruction))
            }
        }

        let cleanText = strippedForDisplay(responseText)
        return (cleanText: cleanText, annotations: annotations)
    }

    /// Removes any complete annotation tags plus a trailing, not-yet-finished
    /// tag fragment, so the answer text reads cleanly even mid-stream while
    /// Claude is still emitting the tag block.
    static func strippedForDisplay(_ responseText: String) -> String {
        var text = responseText
        // anyTagPattern last so it also sweeps up any malformed tag the specific
        // patterns didn't match (e.g. a [BOX] with the wrong separators).
        for pattern in [arrowPattern, boxPattern, stepPattern, anyTagPattern] {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                text = regex.stringByReplacingMatches(
                    in: text,
                    range: NSRange(text.startIndex..., in: text),
                    withTemplate: ""
                )
            }
        }
        // Drop a trailing partial tag the model is still streaming, e.g. "[ARR"
        // or "[STEP:1:120," so it never flashes on screen as raw text.
        if let trailingFragmentRegex = try? NSRegularExpression(pattern: #"\[(?:A|AR|ARR|ARRO|ARROW|B|BO|BOX|S|ST|STE|STEP|P|PO|POI|POIN|POINT)[^\]]*$"#) {
            text = trailingFragmentRegex.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: ""
            )
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func intGroup(_ match: NSTextCheckingResult, _ index: Int, _ text: String) -> Int? {
        guard let range = Range(match.range(at: index), in: text) else { return nil }
        return Int(text[range])
    }

    private static func stringGroup(_ match: NSTextCheckingResult, _ index: Int, _ text: String) -> String {
        guard let range = Range(match.range(at: index), in: text) else { return "" }
        return String(text[range]).trimmingCharacters(in: .whitespaces)
    }
}

/// Draws parsed annotations onto the captured screenshot at full pixel
/// resolution, producing a new image to show as the centerpiece of the answer.
enum AnnotatedScreenshotRenderer {
    private static let highlightColor = NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.18, alpha: 1.0)
    private static let pointerColor = NSColor(calibratedRed: 0.30, green: 0.61, blue: 0.94, alpha: 1.0)
    private static let labelBackgroundColor = NSColor(calibratedWhite: 0.07, alpha: 0.85)

    /// Returns the pixel dimensions of encoded image data (PNG/JPEG), or nil if
    /// it can't be decoded. Used both to tell Claude the coordinate space and
    /// to render at native resolution.
    static func pixelDimensions(of imageData: Data) -> (width: Int, height: Int)? {
        guard let bitmap = NSBitmapImageRep(data: imageData) else { return nil }
        return (width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
    }

    /// The longest edge (in pixels) of the gridded copy sent to the model. The
    /// vision model already downsamples large images to roughly this size, and
    /// Anthropic's image limits are ~1568px / under 5MB — so sending a full
    /// Retina capture (many MB of lossless PNG) just risks the request hanging or
    /// being rejected. We cap and JPEG-encode the model's copy here; the user's
    /// marked-up image is still rendered from the clean full-resolution capture.
    private static let modelImageMaxLongEdge: CGFloat = 1500

    /// Produces a downscaled, JPEG-encoded copy of the screenshot with a faint
    /// labeled 0–1000 coordinate grid drawn over it. This gridded copy is sent to
    /// the vision model ONLY (never shown to the user) so it can READ a mark's
    /// position off the nearest labeled gridline instead of estimating — which is
    /// what keeps the arrows landing on target. Lines and numbers run 0…1000
    /// across and down, matching the grammar in `companionAskResponseSystemPrompt`.
    /// Returns nil if the image can't be decoded (caller falls back to the
    /// ungridded image).
    static func renderCoordinateGridOverlay(baseImageData: Data) -> Data? {
        guard let baseBitmap = NSBitmapImageRep(data: baseImageData) else { return nil }
        let sourceWidth = baseBitmap.pixelsWide
        let sourceHeight = baseBitmap.pixelsHigh
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }

        // Cap the long edge so the image we hand the model stays small and well
        // within API limits (never upscale — only shrink oversized captures).
        let longEdge = CGFloat(max(sourceWidth, sourceHeight))
        let scale = longEdge > modelImageMaxLongEdge ? modelImageMaxLongEdge / longEdge : 1.0
        let pixelWidth = max(1, Int((CGFloat(sourceWidth) * scale).rounded()))
        let pixelHeight = max(1, Int((CGFloat(sourceHeight) * scale).rounded()))

        guard let outputBitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        outputBitmap.size = NSSize(width: pixelWidth, height: pixelHeight)

        guard let graphicsContext = NSGraphicsContext(bitmapImageRep: outputBitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        graphicsContext.imageInterpolation = .high

        // Draw the (possibly downscaled) base image to fill the output bitmap.
        let fullRect = NSRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
        baseBitmap.draw(in: fullRect)

        let scaleReference = CGFloat(max(pixelWidth, pixelHeight))
        let lineWidth = max(1.0, scaleReference * 0.0014)
        let fontSize = max(11.0, scaleReference * 0.013)
        let gridColor = NSColor(calibratedRed: 1.0, green: 0.05, blue: 0.85, alpha: 0.5)
        // Magenta text with a white outline reads on top of any UI underneath.
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: fontSize),
            .foregroundColor: NSColor(calibratedRed: 1.0, green: 0.05, blue: 0.85, alpha: 1.0),
            .strokeColor: NSColor.white,
            .strokeWidth: -3.5
        ]

        gridColor.setStroke()
        // Lines every 100 normalized units (11 lines per axis: 0,100,…,1000).
        for gridValue in stride(from: 0, through: 1000, by: 100) {
            let fraction = CGFloat(gridValue) / 1000

            // Vertical line at this x (same in flipped/unflipped space).
            let lineX = fraction * CGFloat(pixelWidth)
            let verticalPath = NSBezierPath()
            verticalPath.move(to: NSPoint(x: lineX, y: 0))
            verticalPath.line(to: NSPoint(x: lineX, y: CGFloat(pixelHeight)))
            verticalPath.lineWidth = lineWidth
            verticalPath.stroke()

            // Horizontal line at this y. y is top-left in the grid, but the
            // context is bottom-left origin, so flip it.
            let lineYFromTop = fraction * CGFloat(pixelHeight)
            let lineYFlipped = CGFloat(pixelHeight) - lineYFromTop
            let horizontalPath = NSBezierPath()
            horizontalPath.move(to: NSPoint(x: 0, y: lineYFlipped))
            horizontalPath.line(to: NSPoint(x: CGFloat(pixelWidth), y: lineYFlipped))
            horizontalPath.lineWidth = lineWidth
            horizontalPath.stroke()

            // x-axis number along the top edge of the image.
            let xLabel = "\(gridValue)" as NSString
            let xLabelSize = xLabel.size(withAttributes: labelAttributes)
            let xLabelX = min(max(lineX + 2, 2), CGFloat(pixelWidth) - xLabelSize.width - 2)
            xLabel.draw(
                at: NSPoint(x: xLabelX, y: CGFloat(pixelHeight) - xLabelSize.height - 2),
                withAttributes: labelAttributes
            )

            // y-axis number along the left edge (skip 0 — it overlaps x's 0).
            if gridValue != 0 {
                let yLabel = "\(gridValue)" as NSString
                let yLabelSize = yLabel.size(withAttributes: labelAttributes)
                let yLabelY = min(max(lineYFlipped - yLabelSize.height - 1, 2), CGFloat(pixelHeight) - yLabelSize.height - 2)
                yLabel.draw(at: NSPoint(x: 2, y: yLabelY), withAttributes: labelAttributes)
            }
        }

        NSGraphicsContext.restoreGraphicsState()
        // JPEG (not PNG) so the model's copy is a few hundred KB, not multiple
        // MB — fast to write, read, and stay under API size limits.
        return outputBitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.8]
        )
    }

    /// The size of the normalized coordinate grid Claude marks against. Marks
    /// come in as 0...`normalizedGridSize` on each axis and are scaled to the
    /// image's true pixel dimensions here so they're resolution-independent.
    private static let normalizedGridSize: CGFloat = 1000

    /// Renders `annotations` over the screenshot. Returns nil (caller falls
    /// back to the plain screenshot) if the image can't be decoded.
    static func render(baseImageData: Data, annotations: [ScreenshotAnnotation]) -> NSImage? {
        guard let baseBitmap = NSBitmapImageRep(data: baseImageData) else { return nil }
        let pixelWidth = baseBitmap.pixelsWide
        let pixelHeight = baseBitmap.pixelsHigh
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        // Convert every mark from the 0–1000 normalized grid into native pixels
        // for this specific capture before drawing.
        let scaleX = CGFloat(pixelWidth) / normalizedGridSize
        let scaleY = CGFloat(pixelHeight) / normalizedGridSize
        let annotations = annotations.map { annotation -> ScreenshotAnnotation in
            switch annotation {
            case .arrow(let point, let label):
                return .arrow(point: CGPoint(x: point.x * scaleX, y: point.y * scaleY), label: label)
            case .box(let rect, let label):
                return .box(
                    rect: CGRect(
                        x: rect.minX * scaleX,
                        y: rect.minY * scaleY,
                        width: rect.width * scaleX,
                        height: rect.height * scaleY
                    ),
                    label: label
                )
            case .step(let number, let point, let instruction):
                return .step(number: number, point: CGPoint(x: point.x * scaleX, y: point.y * scaleY), instruction: instruction)
            }
        }

        guard let outputBitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        outputBitmap.size = NSSize(width: pixelWidth, height: pixelHeight)

        guard let graphicsContext = NSGraphicsContext(bitmapImageRep: outputBitmap) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext

        let fullImageRect = NSRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
        baseBitmap.draw(in: fullImageRect)

        // Scale stroke widths / fonts to the image so marks read at any capture size.
        let scaleReference = CGFloat(max(pixelWidth, pixelHeight))
        let strokeWidth = max(2.0, scaleReference * 0.004)
        let fontSize = max(11.0, scaleReference * 0.018)

        for annotation in annotations {
            switch annotation {
            case .box(let rect, let label):
                drawHighlightBox(rect, label: label, imageSize: CGSize(width: pixelWidth, height: pixelHeight), strokeWidth: strokeWidth, fontSize: fontSize)
            case .arrow(let point, let label):
                drawArrow(at: point, label: label, imageSize: CGSize(width: pixelWidth, height: pixelHeight), strokeWidth: strokeWidth, fontSize: fontSize)
            case .step(let number, let point, let instruction):
                drawStep(number: number, at: point, instruction: instruction, imageSize: CGSize(width: pixelWidth, height: pixelHeight), fontSize: fontSize)
            }
        }

        NSGraphicsContext.restoreGraphicsState()

        // Report the image at its LOGICAL (point) size, not its raw pixel count.
        // A Retina screen capture is a PNG whose pixel dimensions are 2x its
        // point size (the DPI metadata says so, which is what `baseBitmap.size`
        // reflects). If we instead labeled the result as `pixelWidth` POINTS, the
        // OS would treat the full-resolution capture as a 1x image and upscale it
        // when drawn on a Retina display — which is exactly what made the answer
        // screenshot look blurry. Relabeling the rep to the logical size (drawing
        // already happened in pixel space, so this only changes the point size,
        // not the pixels) keeps every captured pixel available, so the image
        // stays crisp at its natural size.
        let logicalSize: NSSize
        if baseBitmap.size.width > 0, baseBitmap.size.height > 0 {
            logicalSize = baseBitmap.size
        } else {
            logicalSize = NSSize(width: pixelWidth, height: pixelHeight)
        }
        outputBitmap.size = logicalSize

        let outputImage = NSImage(size: logicalSize)
        outputImage.addRepresentation(outputBitmap)
        return outputImage
    }

    // MARK: - Drawing primitives (coordinates are top-left origin; the context
    // is bottom-left origin, so y is flipped via `imageHeight - y`).

    private static func drawHighlightBox(_ rect: CGRect, label: String, imageSize: CGSize, strokeWidth: CGFloat, fontSize: CGFloat) {
        let flippedRect = NSRect(
            x: rect.minX,
            y: CGFloat(imageSize.height) - rect.maxY,
            width: rect.width,
            height: rect.height
        )
        let roundedPath = NSBezierPath(roundedRect: flippedRect, xRadius: 6, yRadius: 6)
        highlightColor.withAlphaComponent(0.18).setFill()
        roundedPath.fill()
        highlightColor.setStroke()
        roundedPath.lineWidth = strokeWidth
        roundedPath.stroke()

        if !label.isEmpty {
            // Label sits just above the box's top edge (top-left in image space).
            drawLabel(label, topLeftInImageSpace: CGPoint(x: rect.minX, y: rect.minY - fontSize * 2.0), imageSize: imageSize, fontSize: fontSize)
        }
    }

    private static func drawArrow(at point: CGPoint, label: String, imageSize: CGSize, strokeWidth: CGFloat, fontSize: CGFloat) {
        let tip = NSPoint(x: point.x, y: CGFloat(imageSize.height) - point.y)

        // Shaft approaches the tip from whichever diagonal keeps it on-image.
        let shaftLength = max(48.0, CGFloat(max(imageSize.width, imageSize.height)) * 0.07)
        let goingRight = point.x < imageSize.width / 2
        let goingDown = point.y < imageSize.height / 2
        let shaftDeltaX = (goingRight ? -1.0 : 1.0) * shaftLength
        let shaftDeltaY = (goingDown ? 1.0 : -1.0) * shaftLength  // already in flipped space
        let shaftStart = NSPoint(x: tip.x + shaftDeltaX, y: tip.y + shaftDeltaY)

        let shaftPath = NSBezierPath()
        shaftPath.move(to: shaftStart)
        shaftPath.line(to: tip)
        shaftPath.lineWidth = strokeWidth
        shaftPath.lineCapStyle = .round
        pointerColor.setStroke()
        shaftPath.stroke()

        // Arrowhead: a small filled triangle at the tip, pointing along the shaft.
        let angle = atan2(tip.y - shaftStart.y, tip.x - shaftStart.x)
        let headLength = max(12.0, strokeWidth * 5)
        let headWidth = headLength * 0.7
        let leftWing = NSPoint(
            x: tip.x - headLength * cos(angle) + headWidth * sin(angle),
            y: tip.y - headLength * sin(angle) - headWidth * cos(angle)
        )
        let rightWing = NSPoint(
            x: tip.x - headLength * cos(angle) - headWidth * sin(angle),
            y: tip.y - headLength * sin(angle) + headWidth * cos(angle)
        )
        let headPath = NSBezierPath()
        headPath.move(to: tip)
        headPath.line(to: leftWing)
        headPath.line(to: rightWing)
        headPath.close()
        pointerColor.setFill()
        headPath.fill()

        if !label.isEmpty {
            // Anchor the label near the shaft start, converted back to top-left space.
            let labelTopLeft = CGPoint(x: shaftStart.x, y: CGFloat(imageSize.height) - shaftStart.y)
            drawLabel(label, topLeftInImageSpace: labelTopLeft, imageSize: imageSize, fontSize: fontSize)
        }
    }

    private static func drawStep(number: Int, at point: CGPoint, instruction: String, imageSize: CGSize, fontSize: CGFloat) {
        let center = NSPoint(x: point.x, y: CGFloat(imageSize.height) - point.y)
        let radius = max(14.0, fontSize * 1.3)
        let circleRect = NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        let circlePath = NSBezierPath(ovalIn: circleRect)
        pointerColor.setFill()
        circlePath.fill()
        NSColor.white.setStroke()
        circlePath.lineWidth = max(1.5, radius * 0.12)
        circlePath.stroke()

        let numberString = "\(number)"
        let numberAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: radius, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let numberSize = numberString.size(withAttributes: numberAttributes)
        numberString.draw(
            at: NSPoint(x: center.x - numberSize.width / 2, y: center.y - numberSize.height / 2),
            withAttributes: numberAttributes
        )

        if !instruction.isEmpty {
            // Instruction label to the right of the circle (top-left image space).
            let labelTopLeft = CGPoint(x: point.x + radius + 6, y: point.y - radius)
            drawLabel(instruction, topLeftInImageSpace: labelTopLeft, imageSize: imageSize, fontSize: fontSize)
        }
    }

    /// Draws a short text label on a rounded dark pill. `topLeftInImageSpace`
    /// is the desired visual top-left of the pill in top-left image coordinates;
    /// it's clamped so the whole pill stays on-image (including the right and
    /// bottom edges, since marks often sit near a corner of the screenshot).
    private static func drawLabel(_ text: String, topLeftInImageSpace: CGPoint, imageSize: CGSize, fontSize: CGFloat) {
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let textSize = text.size(withAttributes: textAttributes)
        let horizontalPadding = fontSize * 0.5
        let verticalPadding = fontSize * 0.3
        let pillWidth = textSize.width + horizontalPadding * 2
        let pillHeight = textSize.height + verticalPadding * 2

        // Clamp both corners so the pill never runs off any edge of the image.
        let edgeInset: CGFloat = 2
        let maxTopLeftX = max(edgeInset, imageSize.width - pillWidth - edgeInset)
        let maxTopLeftY = max(edgeInset, imageSize.height - pillHeight - edgeInset)
        let clampedTopLeftX = min(max(edgeInset, topLeftInImageSpace.x), maxTopLeftX)
        let clampedTopLeftY = min(max(edgeInset, topLeftInImageSpace.y), maxTopLeftY)

        // Convert the pill's top-left (image space) to a bottom-left-origin rect.
        let pillRect = NSRect(
            x: clampedTopLeftX,
            y: imageSize.height - clampedTopLeftY - pillHeight,
            width: pillWidth,
            height: pillHeight
        )
        let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: pillHeight * 0.3, yRadius: pillHeight * 0.3)
        labelBackgroundColor.setFill()
        pillPath.fill()

        text.draw(
            at: NSPoint(x: pillRect.minX + horizontalPadding, y: pillRect.minY + verticalPadding),
            withAttributes: textAttributes
        )
    }
}
