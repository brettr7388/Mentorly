//
//  ILearnTests.swift
//  ILearnTests
//
//  Created by thorfinn on 3/2/26.
//

import Testing
import Foundation
@testable import ILearn

struct ILearnTests {

    @Test func firstPermissionRequestUsesSystemPromptOnly() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: false
        )

        #expect(presentationDestination == .systemPrompt)
    }

    @Test func repeatedPermissionRequestOpensSystemSettings() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: true
        )

        #expect(presentationDestination == .systemSettings)
    }

    @Test func knownGrantedScreenRecordingPermissionSkipsTheGate() async throws {
        let shouldTreatPermissionAsGranted = WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: false,
            hasPreviouslyConfirmedScreenRecordingPermission: true
        )

        #expect(shouldTreatPermissionAsGranted)
    }

}

// MARK: - Live pointing tag parsing

/// `LivePointingParser` turns Claude's `[POINT:…]` / `[STEP:n:…]` tags into an
/// ordered list of named targets and strips the tags from the prose the user
/// reads. It's pure string logic, so it's exercised directly here.
struct LivePointingParserTests {

    @Test func singlePointIsParsedAndStrippedFromProse() {
        let result = LivePointingParser.parse(from: "that's the bookmark control. [POINT:Star]")

        #expect(result.pointings.count == 1)
        #expect(result.pointings.first?.targetName == "Star")
        #expect(result.pointings.first?.stepNumber == nil)
        #expect(result.cleanText == "that's the bookmark control.")
    }

    @Test func numberedStepsAreReturnedInStepOrder() {
        // Tags given out of order — the parser must sort by step number.
        let result = LivePointingParser.parse(from: "[STEP:2:Choose production][STEP:1:Open the deploy menu]")

        #expect(result.pointings.count == 2)
        #expect(result.pointings[0].stepNumber == 1)
        #expect(result.pointings[0].targetName == "Open the deploy menu")
        #expect(result.pointings[1].stepNumber == 2)
        #expect(result.pointings[1].targetName == "Choose production")
    }

    @Test func numberedStepsSortAheadOfPlainPoints() {
        let result = LivePointingParser.parse(from: "[POINT:Star][STEP:1:Open the deploy menu]")

        #expect(result.pointings.count == 2)
        #expect(result.pointings[0].stepNumber == 1)
        #expect(result.pointings[1].stepNumber == nil)
        #expect(result.pointings[1].targetName == "Star")
    }

    @Test func halfTypedTrailingTagNeverLeaksIntoProse() {
        // Mid-stream the model may have only emitted part of a tag.
        let stripped = LivePointingParser.strippedForDisplay("press the save button [POINT:Sav")

        #expect(stripped == "press the save button")
    }

    @Test func emptyTagYieldsNoTargetButIsStillStripped() {
        let result = LivePointingParser.parse(from: "click here [POINT:]")

        #expect(result.pointings.isEmpty)
        #expect(result.cleanText == "click here")
    }

    @Test func whitespaceAroundTargetNameIsTrimmed() {
        let result = LivePointingParser.parse(from: "[POINT:   Star Button   ]")

        #expect(result.pointings.first?.targetName == "Star Button")
    }
}

// MARK: - Accessibility control matching

/// `AccessibilityElementLocator.bestMatch` resolves a model-named control to a
/// real on-screen element: exact match first, then containment (shortest label),
/// then loose token overlap. Frames are irrelevant to matching, so `.zero` is fine.
struct AccessibilityBestMatchTests {

    private func control(_ label: String) -> AccessibleElement {
        AccessibleElement(label: label, role: "AXButton", screenFrame: .zero)
    }

    @Test func exactMatchIsCaseInsensitive() {
        let match = AccessibilityElementLocator.bestMatch(
            forTargetName: "star",
            in: [control("Star"), control("Fork")]
        )

        #expect(match?.label == "Star")
    }

    @Test func containmentPrefersTheShortestContainingLabel() {
        let match = AccessibilityElementLocator.bestMatch(
            forTargetName: "Sav",
            in: [control("Save As…"), control("Save")]
        )

        #expect(match?.label == "Save")
    }

    @Test func tokenOverlapIsTheFallbackWhenNothingContains() {
        let match = AccessibilityElementLocator.bestMatch(
            forTargetName: "blue settings",
            in: [control("Settings panel"), control("Blue widget")]
        )

        #expect(match?.label == "Settings panel")
    }

    @Test func nothingReasonableReturnsNil() {
        let match = AccessibilityElementLocator.bestMatch(
            forTargetName: "xyzzy",
            in: [control("Star"), control("Fork")]
        )

        #expect(match == nil)
    }
}

// MARK: - Claude Code CLI stream parsing

/// `ClaudeCodeBackend.interpretStreamLine` turns one JSONL line from
/// `claude --output-format stream-json` into an event the streaming loop acts on.
struct ClaudeCodeStreamParsingTests {

    @Test func textDeltaChunkIsExtracted() {
        let line = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}}"#

        #expect(ClaudeCodeBackend.interpretStreamLine(line) == .textDelta("Hi"))
    }

    @Test func terminalResultIsTreatedAsAuthoritative() {
        let line = #"{"type":"result","result":"All done."}"#

        #expect(ClaudeCodeBackend.interpretStreamLine(line) == .finalResult("All done."))
    }

    @Test func errorResultSurfacesTheMessage() {
        let line = #"{"type":"result","is_error":true,"result":"rate limited"}"#

        #expect(ClaudeCodeBackend.interpretStreamLine(line) == .modelError("rate limited"))
    }

    @Test func nonTextStreamEventsAreIgnored() {
        // A stream event that isn't an assistant text delta (e.g. a tool-call
        // block) carries no answer text for the user.
        let line = #"{"type":"stream_event","event":{"type":"message_start"}}"#

        #expect(ClaudeCodeBackend.interpretStreamLine(line) == .ignored)
    }

    @Test func blankAndMalformedLinesAreIgnored() {
        #expect(ClaudeCodeBackend.interpretStreamLine("") == .ignored)
        #expect(ClaudeCodeBackend.interpretStreamLine("not json at all") == .ignored)
    }
}
