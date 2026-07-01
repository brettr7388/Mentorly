//
//  AccessibilityElementLocator.swift
//  Mentorly
//
//  Reads the frontmost application's macOS Accessibility (AX) tree and returns
//  the actionable on-screen elements (buttons, links, menu items, fields, …)
//  together with their exact screen frames.
//
//  This is the foundation of the "live arrows" feature: instead of asking the
//  model to estimate pixel coordinates from a downscaled screenshot (which is
//  inaccurate), we hand the model the list of real element NAMES that the OS
//  already knows about, let it pick which one to point at, and then look the
//  exact frame back up here. The frame comes straight from the OS, so the arrow
//  lands precisely on the real control — and it's completely free (no API key,
//  no per-token billing), it only needs Accessibility permission.
//
//  Coordinate spaces:
//  - The AX API reports element positions in the "global flipped" screen space:
//    origin at the TOP-LEFT of the primary display, y growing downward.
//  - The overlay/flight code (OverlayWindow.swift) works in AppKit GLOBAL screen
//    space: origin at the BOTTOM-LEFT of the primary display, y growing upward.
//  - `screenFrame` below is already converted to AppKit global space so it can be
//    fed directly into `detectedElementScreenLocation` / the flight animation.
//

import AppKit
import ApplicationServices

/// One actionable UI element discovered in an application's Accessibility tree,
/// with a human-readable label and its exact on-screen frame.
struct AccessibleElement {
    /// Best human-readable name for the element (title, then description, then
    /// value, then help). This is what the model sees and names.
    let label: String

    /// The AX role string, e.g. "AXButton", "AXLink", "AXMenuItem".
    let role: String

    /// The element's frame in AppKit GLOBAL screen coordinates (bottom-left
    /// origin, y up) — ready to feed into the overlay flight pipeline.
    let screenFrame: CGRect

    /// The center of `screenFrame`, in AppKit global coordinates. This is the
    /// point the blue cursor flies to when pointing at the element.
    var screenCenter: CGPoint {
        CGPoint(x: screenFrame.midX, y: screenFrame.midY)
    }
}

enum AccessibilityElementLocator {
    /// Roles we consider "actionable" — the kinds of controls a beginner would
    /// be told to click, type into, or choose. Other roles (groups, static
    /// text, scroll areas, …) are skipped as point targets but still walked
    /// into so we reach their actionable descendants.
    private static let actionableRoles: Set<String> = [
        kAXButtonRole as String,
        kAXMenuButtonRole as String,
        kAXPopUpButtonRole as String,
        kAXMenuItemRole as String,
        "AXLink",
        kAXCheckBoxRole as String,
        kAXRadioButtonRole as String,
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXTabGroupRole as String,
        kAXToolbarRole as String,
        kAXComboBoxRole as String,
        kAXSliderRole as String,
        kAXIncrementorRole as String,
        kAXDisclosureTriangleRole as String,
        "AXTab",
        "AXToolbarButton",
        "AXSegmentedControl"
    ]

    /// Whether Mentorly currently has Accessibility permission. Without it the AX
    /// tree of other apps is invisible and every scan returns an empty list.
    static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    /// Wakes up an app's web-content / "enhanced" Accessibility tree.
    ///
    /// Browsers (Chrome, Arc, Edge, Brave) and Electron/Chromium apps keep the
    /// accessibility tree for their WEB CONTENT switched OFF by default, because
    /// maintaining it is expensive. Until an assistive client explicitly opts in
    /// by setting `AXManualAccessibility` / `AXEnhancedUserInterface` to true on
    /// the application element, an AX scan only sees the app's native chrome
    /// (toolbar, tabs, address bar) and NONE of the page's buttons, links, or
    /// fields — so the model is handed a control menu that's missing the very
    /// thing the user is asking about (e.g. GitHub's "Star" button).
    ///
    /// Building that tree takes a brief moment, so call this as EARLY as possible
    /// (the instant the hotkey fires) and let unrelated work — capturing the
    /// screenshot — overlap the warm-up before the scan runs.
    static func enableEnhancedAccessibility(forProcessIdentifier processIdentifier: pid_t) {
        guard hasAccessibilityPermission() else { return }
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        setEnhancedAccessibilityAttributes(on: applicationElement)
    }

    /// Sets the two opt-in attributes that turn on web-content accessibility.
    /// Chrome responds to both; Electron responds to `AXManualAccessibility`.
    /// Setting both is harmless on native apps that don't recognize them.
    private static func setEnhancedAccessibilityAttributes(on applicationElement: AXUIElement) {
        AXUIElementSetAttributeValue(applicationElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(applicationElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    /// Scans the frontmost (active) application's window hierarchy and returns
    /// its actionable elements. Returns an empty array if there is no frontmost
    /// app, Mentorly lacks Accessibility permission, or the app exposes nothing.
    static func actionableElementsForFrontmostApp(maxElements: Int = 250) -> [AccessibleElement] {
        guard hasAccessibilityPermission() else { return [] }
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else { return [] }
        return actionableElements(forProcessIdentifier: frontmostApp.processIdentifier,
                                  maxElements: maxElements)
    }

    /// Scans a specific application (by pid) and returns its actionable elements.
    static func actionableElements(forProcessIdentifier processIdentifier: pid_t,
                                   maxElements: Int = 250) -> [AccessibleElement] {
        guard hasAccessibilityPermission() else { return [] }

        let applicationElement = AXUIElementCreateApplication(processIdentifier)

        // Make sure web-content accessibility is on for browsers/Electron apps.
        // Ideally this was already done earlier (so the tree had time to build),
        // but setting it again here is cheap and guarantees the standalone path
        // (e.g. `actionableElementsForFrontmostApp`) also opts in.
        setEnhancedAccessibilityAttributes(on: applicationElement)

        var collectedElements: [AccessibleElement] = []
        var visitedElementCount = 0
        // Hard cap on total nodes visited so a pathological/huge tree can never
        // hang the scan. 4000 nodes is plenty to reach every visible control.
        let maxNodesToVisit = 4000

        // Walk the application's windows. Reading kAXWindowsAttribute (rather
        // than starting from the app element itself) keeps us inside on-screen
        // window content and out of the app-level menu bar noise.
        let windowElements = childElements(of: applicationElement, attribute: kAXWindowsAttribute as String)
        let rootsToWalk = windowElements.isEmpty ? [applicationElement] : windowElements

        for rootElement in rootsToWalk {
            walkElementTree(
                rootElement,
                depth: 0,
                collectedElements: &collectedElements,
                visitedElementCount: &visitedElementCount,
                maxNodesToVisit: maxNodesToVisit,
                maxElements: maxElements
            )
            if collectedElements.count >= maxElements { break }
        }

        return collectedElements
    }

    /// Finds the actionable element whose label best matches a model-supplied
    /// target name. Matching is case-insensitive and tolerant: exact match wins,
    /// then "label contains name" / "name contains label", then a loose
    /// token-overlap score. Returns nil if nothing reasonably matches.
    static func bestMatch(forTargetName targetName: String,
                          in elements: [AccessibleElement]) -> AccessibleElement? {
        let normalizedTarget = normalize(targetName)
        guard !normalizedTarget.isEmpty else { return nil }

        // 1. Exact (normalized) match.
        if let exactMatch = elements.first(where: { normalize($0.label) == normalizedTarget }) {
            return exactMatch
        }

        // 2. Containment match — prefer the shortest containing label so we get
        //    the most specific control rather than a giant container's title.
        let containmentMatches = elements.filter { element in
            let normalizedLabel = normalize(element.label)
            return normalizedLabel.contains(normalizedTarget) || normalizedTarget.contains(normalizedLabel)
        }
        if let bestContainmentMatch = containmentMatches.min(by: { $0.label.count < $1.label.count }) {
            return bestContainmentMatch
        }

        // 3. Token-overlap fallback — score by how many target words appear in
        //    the label. Require at least one shared word.
        let targetTokens = Set(normalizedTarget.split(separator: " ").map(String.init))
        guard !targetTokens.isEmpty else { return nil }

        var bestScore = 0
        var bestScoredElement: AccessibleElement?
        for element in elements {
            let labelTokens = Set(normalize(element.label).split(separator: " ").map(String.init))
            let sharedTokenCount = targetTokens.intersection(labelTokens).count
            if sharedTokenCount > bestScore {
                bestScore = sharedTokenCount
                bestScoredElement = element
            }
        }
        return bestScore > 0 ? bestScoredElement : nil
    }

    // MARK: - Tree Walking

    private static func walkElementTree(
        _ element: AXUIElement,
        depth: Int,
        collectedElements: inout [AccessibleElement],
        visitedElementCount: inout Int,
        maxNodesToVisit: Int,
        maxElements: Int
    ) {
        if visitedElementCount >= maxNodesToVisit { return }
        if collectedElements.count >= maxElements { return }
        // Guard against accidental deep/cyclic trees.
        if depth > 60 { return }

        visitedElementCount += 1

        let role = stringAttribute(of: element, attribute: kAXRoleAttribute as String) ?? ""

        // Record this element if it's an actionable, labeled, on-screen control.
        if actionableRoles.contains(role) {
            if let label = bestLabel(for: element), !label.isEmpty,
               let screenFrame = appKitScreenFrame(of: element),
               screenFrame.width >= 4, screenFrame.height >= 4 {
                collectedElements.append(
                    AccessibleElement(label: label, role: role, screenFrame: screenFrame)
                )
            }
        }

        // Recurse into children regardless of this element's role so we reach
        // actionable descendants nested inside groups, toolbars, lists, etc.
        let children = childElements(of: element, attribute: kAXChildrenAttribute as String)
        for childElement in children {
            walkElementTree(
                childElement,
                depth: depth + 1,
                collectedElements: &collectedElements,
                visitedElementCount: &visitedElementCount,
                maxNodesToVisit: maxNodesToVisit,
                maxElements: maxElements
            )
            if collectedElements.count >= maxElements { return }
            if visitedElementCount >= maxNodesToVisit { return }
        }
    }

    // MARK: - Label Resolution

    /// Resolves the best human-readable label for an element, trying the most
    /// descriptive attributes first.
    private static func bestLabel(for element: AXUIElement) -> String? {
        if let title = stringAttribute(of: element, attribute: kAXTitleAttribute as String),
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let description = stringAttribute(of: element, attribute: kAXDescriptionAttribute as String),
           !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return description.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let help = stringAttribute(of: element, attribute: kAXHelpAttribute as String),
           !help.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return help.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // A text field's current value is a reasonable label of last resort
        // (e.g. a search field showing its placeholder/contents).
        if let value = stringAttribute(of: element, attribute: kAXValueAttribute as String),
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    // MARK: - Geometry

    /// Reads an element's position + size and converts them from the AX global
    /// flipped space (top-left origin) into AppKit global space (bottom-left
    /// origin), so the result can drive the overlay flight directly.
    private static func appKitScreenFrame(of element: AXUIElement) -> CGRect? {
        guard let axPosition = pointAttribute(of: element, attribute: kAXPositionAttribute as String),
              let axSize = sizeAttribute(of: element, attribute: kAXSizeAttribute as String) else {
            return nil
        }

        // The AX flipped space has its origin at the top-left of the primary
        // display — the first screen in NSScreen.screens (the one whose AppKit
        // frame origin is (0,0)). Its maxY equals its pixel-independent height.
        guard let primaryScreen = NSScreen.screens.first else {
            return CGRect(origin: axPosition, size: axSize)
        }
        let primaryScreenTopInAppKit = primaryScreen.frame.maxY

        // Flip the y axis: AppKit y of the frame's bottom edge.
        let appKitBottomY = primaryScreenTopInAppKit - (axPosition.y + axSize.height)

        return CGRect(x: axPosition.x, y: appKitBottomY, width: axSize.width, height: axSize.height)
    }

    // MARK: - AX Attribute Helpers

    /// Returns the child AXUIElements stored under `attribute` (e.g. children or
    /// windows). Returns an empty array if the attribute is missing or empty.
    private static func childElements(of element: AXUIElement, attribute: String) -> [AXUIElement] {
        var rawValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue)
        guard result == .success, let array = rawValue as? [AXUIElement] else { return [] }
        return array
    }

    private static func stringAttribute(of element: AXUIElement, attribute: String) -> String? {
        var rawValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue)
        guard result == .success else { return nil }
        return rawValue as? String
    }

    private static func pointAttribute(of element: AXUIElement, attribute: String) -> CGPoint? {
        var rawValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue)
        guard result == .success, let axValue = rawValue else { return nil }
        // CFTypeRef carrying an AXValue of type .cgPoint.
        let axValueRef = axValue as! AXValue
        guard AXValueGetType(axValueRef) == .cgPoint else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(axValueRef, .cgPoint, &point) else { return nil }
        return point
    }

    private static func sizeAttribute(of element: AXUIElement, attribute: String) -> CGSize? {
        var rawValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue)
        guard result == .success, let axValue = rawValue else { return nil }
        let axValueRef = axValue as! AXValue
        guard AXValueGetType(axValueRef) == .cgSize else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValueRef, .cgSize, &size) else { return nil }
        return size
    }

    // MARK: - Normalization

    /// Lowercases, strips punctuation to spaces, and collapses whitespace so
    /// label matching ignores cosmetic differences ("Star ⭐" vs "star").
    private static func normalize(_ text: String) -> String {
        let lowercased = text.lowercased()
        let cleanedScalars = lowercased.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            } else {
                return " "
            }
        }
        let cleaned = String(cleanedScalars)
        return cleaned.split(separator: " ").joined(separator: " ")
    }
}
