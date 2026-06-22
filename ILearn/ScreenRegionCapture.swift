//
//  ScreenRegionCapture.swift
//  ILearn
//
//  Lets the user drag-select a region of the screen to ask about, by
//  shelling out to macOS's own interactive screenshot tool (the same one
//  behind Cmd+Shift+4) instead of building a custom selection overlay.
//  This means the selected region's on-screen origin is unknown to us, so
//  the blue-cursor "point at this element" animation isn't available for
//  questions asked this way — Claude's answer is text-only context for
//  whatever region the user selected.
//

import Foundation

enum ScreenRegionCapture {
    /// Launches the system interactive screenshot selection (crosshair,
    /// drag to select, Escape to cancel) and returns the captured region as
    /// PNG data, or nil if the user cancelled without selecting anything.
    static func captureUserSelectedRegion() async throws -> Data? {
        let temporaryFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ILearn-selection-\(UUID().uuidString).png")

        let selectionProcess = Process()
        selectionProcess.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        selectionProcess.arguments = ["-i", "-s", temporaryFileURL.path]

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            selectionProcess.terminationHandler = { _ in
                continuation.resume()
            }
            do {
                try selectionProcess.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }

        defer { try? FileManager.default.removeItem(at: temporaryFileURL) }

        // If the user pressed Escape instead of selecting a region,
        // screencapture exits without ever writing the destination file.
        guard FileManager.default.fileExists(atPath: temporaryFileURL.path) else {
            return nil
        }

        return try Data(contentsOf: temporaryFileURL)
    }
}
