//
//  ViMouseTests.swift
//  ViMouseTests
//
//  Created by TakiuchiGenki on 2015/07/19.
//  Copyright © 2015年 s21g Inc. All rights reserved.
//

import Carbon
import XCTest

class ViMouseTests: XCTestCase {
    func testVoiceShortcutRespectsMouseModeAndLeavesNormalShortcutsAlone() {
        let key = kVK_ANSI_V
        var flags = InputHook.Flags()
        XCTAssertFalse(VoiceInputShortcut.matches(key, flags: flags, mouseMode: false))
        XCTAssertTrue(VoiceInputShortcut.matches(key, flags: flags, mouseMode: true))
        flags.fnc = true
        XCTAssertTrue(VoiceInputShortcut.matches(key, flags: flags, mouseMode: false))
        XCTAssertTrue(VoiceInputShortcut.matches(key, flags: flags, mouseMode: true))
        XCTAssertFalse(VoiceInputShortcut.matches(kVK_ANSI_C, flags: flags, mouseMode: true))
        flags.cmd = true
        XCTAssertFalse(VoiceInputShortcut.matches(key, flags: flags, mouseMode: true))
        flags.cmd = false
        flags.fnc = false
        flags.shift = true
        XCTAssertFalse(VoiceInputShortcut.matches(key, flags: flags, mouseMode: true))
    }

    @MainActor
    func testSplitInputSingleRawCharacterCannotGrowFromLongConvertedCandidate() {
        let client = JapaneseConversionServingStub()
        let controller = SelfConversionWindowController(client: client)
        defer { controller.cancel() }
        controller.begin()
        controller.append("a")
        controller.forceStartCurrentConversion()
        client.complete(at: 0, candidates: [JapaneseConversionCandidate(text: "長い候補", score: 1)])
        runMainLoop(for: 0.1)
        controller.splitInputAfterFirstCharacter()
        XCTAssertEqual(controller.decisionSnapshot().input, "a")
        XCTAssertEqual(controller.selectedText(), "長い候補")
        XCTAssertFalse(controller.hasNextSessionInput)
    }

    @MainActor
    func testSplitInputDoesNotLeakMixedScriptCandidateIntoFollowingRange() {
        let client = JapaneseConversionServingStub()
        let controller = SelfConversionWindowController(client: client)
        defer { controller.cancel() }
        controller.begin()
        controller.append("awspurod")
        controller.forceStartCurrentConversion()
        client.complete(at: 0, candidates: [JapaneseConversionCandidate(text: "あWSプロd", score: 1)])
        runMainLoop(for: 0.1)
        controller.splitInputAfterFirstCharacter()
        XCTAssertEqual(controller.selectedText(), "a")
        controller.backspace()
        XCTAssertEqual(controller.decisionSnapshot().input, "wspurod")
        XCTAssertEqual(client.requests.last?.input, "wspurod")
    }

    @MainActor
    func testBoundaryChangeCancelsSelectionButNoOpEditingKeepsItFrozen() {
        let client = JapaneseConversionServingStub()
        let controller = SelfConversionWindowController(client: client)
        defer { controller.cancel() }
        controller.begin()
        controller.append("Omarchy")
        controller.forceStartCurrentConversion()
        controller.selectPrevious()
        controller.append("")
        controller.moveFirstNextSessionCharacterToInput() // No suffix: no change.
        XCTAssertTrue(controller.decisionSnapshot().explicitSelection)
        controller.moveLastInputCharacterToNextSession()
        XCTAssertFalse(controller.decisionSnapshot().explicitSelection)
        XCTAssertEqual(controller.decisionSnapshot().input, "Omarch")
        runMainLoop(for: 2.2)
        XCTAssertEqual(client.requests.map(\.input), ["Omarchy", "Omarch"])
    }

    @MainActor
    func testCandidateSelectionCancelsDebounceAndTabCommitsLiteralOmarchy() {
        let client = JapaneseConversionServingStub()
        let controller = SelfConversionWindowController(client: client)
        defer { controller.cancel() }
        controller.begin()
        controller.append("Omarc")
        controller.forceStartCurrentConversion()
        controller.append("hy")
        controller.selectPrevious() // Last fallback is literal/direct input.
        XCTAssertEqual(controller.selectedText(), "Omarchy")
        let list = controller.decisionSnapshot().candidates
        runMainLoop(for: 2.2)
        XCTAssertEqual(client.requests.map(\.input), ["Omarc"])
        XCTAssertEqual(controller.decisionSnapshot().candidates, list)
        client.complete(at: 0, candidates: [JapaneseConversionCandidate(text: "古い応答", score: 1)])
        runMainLoop(for: 0.1)
        XCTAssertEqual(controller.selectedText(), "Omarchy")
        let snapshot = controller.commitCurrentCandidateForContinuation()
        XCTAssertEqual(snapshot.selectedCandidate?.text, "Omarchy")
        XCTAssertEqual(controller.composedText(), "Omarchy")
    }

    @MainActor
    func testCandidateSelectionFreezesInFlightListAcrossNavigationAndEnter() {
        let client = JapaneseConversionServingStub()
        let controller = SelfConversionWindowController(client: client)
        defer { controller.cancel() }
        controller.begin()
        controller.append("Omarchy")
        controller.forceStartCurrentConversion()
        controller.selectNext()
        controller.selectPrevious()
        controller.selectPrevious()
        XCTAssertEqual(controller.selectedText(), "Omarchy")
        let list = controller.decisionSnapshot().candidates
        client.complete(at: 0, candidates: [JapaneseConversionCandidate(text: "オマーチー", score: 1)])
        runMainLoop(for: 0.1)
        XCTAssertEqual(controller.decisionSnapshot().candidates, list)
        XCTAssertTrue(controller.decisionSnapshot().explicitSelection)
        XCTAssertEqual(controller.confirmAndClose().composedText, "Omarchy")
    }

    @MainActor
    func testCandidateSelectionKeepsSuffixAndPartialCommitStartsItsConversion() {
        let client = JapaneseConversionServingStub()
        let controller = SelfConversionWindowController(client: client)
        defer { controller.cancel() }
        controller.begin()
        controller.append("Omarchy")
        controller.forceStartCurrentConversion()
        placeSuffixInNextRange(controller, "TAIL")
        controller.selectPrevious()
        XCTAssertEqual(controller.selectedText(), "Omarchy")
        runMainLoop(for: 2.2)
        XCTAssertEqual(client.requests.map(\.input), ["Omarchy"])
        controller.commitCurrentCandidateForContinuation()
        XCTAssertEqual(client.requests.map(\.input), ["Omarchy", "TAIL"])
        XCTAssertEqual(controller.decisionSnapshot().committedText, "Omarchy")
    }

    @MainActor
    func testTypingAndDeleteResumeDebounceAfterCandidateSelection() {
        let client = JapaneseConversionServingStub()
        let controller = SelfConversionWindowController(client: client)
        defer { controller.cancel() }
        controller.begin()
        controller.append("Omarchy")
        controller.forceStartCurrentConversion()
        controller.selectPrevious()
        controller.append("x")
        XCTAssertFalse(controller.decisionSnapshot().explicitSelection)
        runMainLoop(for: 2.2)
        XCTAssertEqual(client.requests.map(\.input), ["Omarchy", "Omarchyx"])
        controller.selectPrevious()
        controller.backspace()
        XCTAssertFalse(controller.decisionSnapshot().explicitSelection)
        runMainLoop(for: 2.2)
        XCTAssertEqual(client.requests.map(\.input), ["Omarchy", "Omarchyx", "Omarchy"])
    }

    @MainActor
    func testExplicitConversionOverridesCandidateSelectionFreeze() {
        let client = JapaneseConversionServingStub()
        let controller = SelfConversionWindowController(client: client)
        defer { controller.cancel() }
        controller.begin()
        controller.append("Omarchy")
        controller.forceStartCurrentConversion()
        controller.selectPrevious()
        controller.forceStartCurrentConversion()
        XCTAssertFalse(controller.decisionSnapshot().explicitSelection)
        XCTAssertEqual(client.requests.map(\.input), ["Omarchy", "Omarchy"])
        client.complete(at: 1, candidates: [JapaneseConversionCandidate(text: "明示変換", score: 1)])
        runMainLoop(for: 0.1)
        XCTAssertEqual(controller.selectedText(), "明示変換")
    }

    @MainActor
    func testTypingTargetIsUnchangedAcrossInitialAndRepeatedRequestStarts() {
        let client = JapaneseConversionServingStub()
        let controller = SelfConversionWindowController(client: client)
        defer { controller.cancel() }
        controller.begin()
        controller.append("ko")
        controller.append("r") // Before animation.
        controller.forceStartCurrentConversion()
        controller.append("e") // Immediately after animation starts.
        XCTAssertEqual(controller.decisionSnapshot().input, "kore")
        XCTAssertFalse(controller.hasNextSessionInput)
        controller.forceStartCurrentConversion()
        controller.append("h") // Immediately after revised request starts.
        controller.append("a")
        XCTAssertEqual(controller.decisionSnapshot().input, "koreha")
        XCTAssertFalse(controller.hasNextSessionInput)
        controller.forceStartCurrentConversion()
        XCTAssertEqual(client.requests.map(\.input), ["kor", "kore", "koreha"])
        client.complete(at: 1, candidates: [JapaneseConversionCandidate(text: "古い", score: 1)])
        client.complete(at: 0, candidates: [JapaneseConversionCandidate(text: "もっと古い", score: 1)])
        runMainLoop(for: 0.1)
        XCTAssertFalse(controller.decisionSnapshot().candidates.contains { $0.text.contains("古い") })
        client.complete(at: 2, candidates: [JapaneseConversionCandidate(text: "これは", score: 1)])
        runMainLoop(for: 0.1)
        XCTAssertEqual(controller.confirmAndClose().composedText, "これは")
    }

    @MainActor
    func testTypingAtAnimationStartKeepsOverflowAndPreservesAllTypedCharacters() {
        let client = JapaneseConversionServingStub()
        let controller = SelfConversionWindowController(client: client)
        defer { controller.cancel() }
        let input = String(repeating: "a", count: 256)
        controller.begin()
        controller.append(input)
        controller.forceStartCurrentConversion()
        controller.append("h")
        controller.append("a")
        XCTAssertEqual(controller.decisionSnapshot().input, input + "ha")
        XCTAssertFalse(controller.hasNextSessionInput)
        controller.forceStartCurrentConversion()
        XCTAssertTrue(controller.hasNextSessionInput) // API-limit overflow only.
        XCTAssertEqual(client.requests.map(\.input), [input, input])
        controller.commitCurrentCandidateForContinuation()
        XCTAssertEqual(client.requests.last?.input, "ha")
        XCTAssertTrue(client.requests.allSatisfy { $0.input.unicodeScalars.count <= 256 })
    }

    // Build an explicit boundary through the real UI operation, not through
    // the former bug that sent in-flight typed characters to the next range.
    @MainActor
    private func placeSuffixInNextRange(_ controller: SelfConversionWindowController, _ suffix: String) {
        controller.append(suffix)
        for _ in suffix { controller.moveLastInputCharacterToNextSession() }
    }

    @MainActor
    func testSplitInputKeepsRawCaseWithoutReconversion() {
        let client = JapaneseConversionServingStub()
        let controller = SelfConversionWindowController(client: client)
        defer { controller.cancel() }
        controller.begin()
        controller.append("ViMouse")
        controller.forceStartCurrentConversion()
        placeSuffixInNextRange(controller, "tail")
        controller.forceStartCurrentConversion()
        client.complete(at: 1, candidates: [JapaneseConversionCandidate(text: "ViMouse", score: 0.999, isNative: true)])
        runMainLoop(for: 0.1)
        controller.splitInputAfterFirstCharacter()
        XCTAssertEqual(controller.selectedText(), "V")
        runMainLoop(for: 2.2)
        XCTAssertEqual(controller.selectedText(), "V")
        XCTAssertEqual(client.requests.map(\.input), ["ViMouse", "ViMouse"])
        controller.commitCurrentCandidateForContinuation()
        XCTAssertEqual(client.requests.last?.input, "iMousetail")
    }

    @MainActor
    func testSplitInputNeverCopiesSelectedConvertedTextAndPrependsRawRest() {
        let client = JapaneseConversionServingStub()
        let controller = SelfConversionWindowController(client: client)
        defer { controller.cancel() }
        controller.begin()
        controller.append("nihongo")
        controller.forceStartCurrentConversion()
        placeSuffixInNextRange(controller, "abc")
        controller.forceStartCurrentConversion()
        client.complete(at: 1, candidates: [JapaneseConversionCandidate(text: "にほんご", score: 0.999, isNative: true),
                                          JapaneseConversionCandidate(text: "日本語", score: 0.998, isNative: true)])
        runMainLoop(for: 0.1)
        controller.selectNext()
        controller.splitInputAfterFirstCharacter()
        XCTAssertEqual(controller.decisionSnapshot().input, "n")
        XCTAssertEqual(controller.selectedText(), "n")
        XCTAssertFalse(controller.decisionSnapshot().explicitSelection)
        controller.splitInputAfterFirstCharacter() // Key repeat is idempotent.
        controller.commitCurrentCandidateForContinuation()
        XCTAssertEqual(client.requests.map(\.input), ["nihongo", "nihongo", "ihongoabc"])
    }

    @MainActor
    func testSplitInputPreservesGraphemeAndIgnoresOldResponse() {
        let client = JapaneseConversionServingStub()
        let controller = SelfConversionWindowController(client: client)
        defer { controller.cancel() }
        let emoji = "👨‍👩‍👧‍👦"
        controller.begin()
        controller.append(emoji + "日本語")
        controller.forceStartCurrentConversion()
        controller.splitInputAfterFirstCharacter()
        XCTAssertEqual(controller.decisionSnapshot().input, emoji)
        client.complete(at: 0, candidates: [JapaneseConversionCandidate(text: "旧候補", score: 1)])
        runMainLoop(for: 0.1)
        XCTAssertEqual(controller.decisionSnapshot().input, emoji)
        XCTAssertFalse(controller.decisionSnapshot().candidates.contains { $0.text == "旧候補" })
        controller.commitCurrentCandidateForContinuation()
        XCTAssertEqual(client.requests.last?.input, "日本語")
    }

    @MainActor
    func testSplitInputUsesRawLengthRatherThanCandidateLength() {
        let client = JapaneseConversionServingStub()
        let controller = SelfConversionWindowController(client: client)
        defer { controller.cancel() }
        controller.begin()
        controller.splitInputAfterFirstCharacter()
        controller.append("raw")
        controller.splitInputAfterFirstCharacter()
        XCTAssertEqual(controller.decisionSnapshot().input, "raw")
        XCTAssertFalse(controller.hasNextSessionInput)
        controller.forceStartCurrentConversion()
        placeSuffixInNextRange(controller, "next")
        controller.forceStartCurrentConversion()
        client.complete(at: 1, candidates: [JapaneseConversionCandidate(text: "日", score: 1)])
        runMainLoop(for: 0.1)
        controller.splitInputAfterFirstCharacter()
        XCTAssertEqual(controller.decisionSnapshot().input, "r")
        XCTAssertEqual(controller.selectedText(), "r")
        controller.commitCurrentCandidateForContinuation()
        XCTAssertEqual(client.requests.last?.input, "awnext")
    }

    @MainActor
    func testSplitInputPreservesCommittedPrefixAndDeletePromotesRawRemainder() {
        let client = JapaneseConversionServingStub()
        let controller = SelfConversionWindowController(client: client)
        defer { controller.cancel() }
        controller.begin()
        controller.append("mae")
        controller.forceStartCurrentConversion()
        client.complete(at: 0, candidates: [JapaneseConversionCandidate(text: "前", score: 1)])
        runMainLoop(for: 0.1)
        controller.commitCurrentCandidateForContinuation()
        controller.append("nihongo")
        controller.forceStartCurrentConversion()
        client.complete(at: 1, candidates: [JapaneseConversionCandidate(text: "日本語", score: 1)])
        runMainLoop(for: 0.1)
        controller.splitInputAfterFirstCharacter()
        XCTAssertEqual(controller.decisionSnapshot().committedText, "前")
        controller.backspace()
        XCTAssertEqual(controller.decisionSnapshot().input, "ihongo")
        XCTAssertEqual(controller.decisionSnapshot().committedText, "前")
        XCTAssertEqual(client.requests.last?.input, "ihongo")
    }

    @MainActor
    func testTypingInSplitRangeEditsCurrentInputAndPreservesNextRangeDuringRequest() {
        let client = JapaneseConversionServingStub()
        let controller = SelfConversionWindowController(client: client)
        defer { controller.cancel() }
        controller.begin()
        controller.append("kore")
        controller.forceStartCurrentConversion()
        placeSuffixInNextRange(controller, "ha")
        controller.append("x") // Append to current range, with suffix already moved.
        controller.append("y")
        XCTAssertEqual(controller.decisionSnapshot().input, "korexy")
        XCTAssertTrue(controller.hasNextSessionInput)
        client.complete(at: 0, candidates: [JapaneseConversionCandidate(text: "旧候補", score: 1)])
        runMainLoop(for: 0.1)
        XCTAssertFalse(controller.decisionSnapshot().candidates.contains { $0.text == "旧候補" })
        controller.forceStartCurrentConversion()
        XCTAssertEqual(client.requests.map(\.input), ["kore", "korexy"])
        client.complete(at: 1, candidates: [JapaneseConversionCandidate(text: "修正", score: 1)])
        runMainLoop(for: 0.1)
        controller.commitCurrentCandidateForContinuation()
        XCTAssertEqual(client.requests.map(\.input), ["kore", "korexy", "ha"])
    }

    @MainActor
    func testTypingInCompletedSplitRangeDebouncesAndInvalidatesSelectedCandidate() {
        let client = JapaneseConversionServingStub()
        let controller = SelfConversionWindowController(client: client)
        defer { controller.cancel() }
        controller.begin()
        controller.append("kore")
        controller.forceStartCurrentConversion()
        placeSuffixInNextRange(controller, "ha")
        controller.forceStartCurrentConversion()
        client.complete(at: 1, candidates: [JapaneseConversionCandidate(text: "これ", score: 0.999, isNative: true),
                                          JapaneseConversionCandidate(text: "此れ", score: 0.998, isNative: true)])
        runMainLoop(for: 0.1)
        controller.selectNext()
        XCTAssertTrue(controller.decisionSnapshot().explicitSelection)
        controller.append("de")
        XCTAssertEqual(controller.decisionSnapshot().input, "korede")
        XCTAssertFalse(controller.decisionSnapshot().explicitSelection)
        controller.backspace()
        controller.append("s")
        XCTAssertEqual(controller.decisionSnapshot().input, "koreds")
        runMainLoop(for: 2.2)
        XCTAssertEqual(client.requests.map(\.input), ["kore", "kore", "koreds"])
        client.complete(at: 2, candidates: [JapaneseConversionCandidate(text: "新", score: 1)])
        runMainLoop(for: 0.1)
        controller.commitCurrentCandidateForContinuation()
        XCTAssertEqual(client.requests.last?.input, "ha")
    }

    @MainActor
    func testTypingAtManuallyMovedBoundaryAppendsBeforeUnchangedSuffix() {
        let client = JapaneseConversionServingStub()
        let controller = SelfConversionWindowController(client: client)
        defer { controller.cancel() }
        controller.begin()
        controller.append("abcdef")
        controller.forceStartCurrentConversion()
        controller.moveLastInputCharacterToNextSession()
        controller.moveLastInputCharacterToNextSession()
        controller.append("XY")
        controller.forceStartCurrentConversion()
        XCTAssertEqual(client.requests.map(\.input), ["abcdef", "abcdXY"])
        client.complete(at: 1, candidates: [JapaneseConversionCandidate(text: "前", score: 1)])
        runMainLoop(for: 0.1)
        controller.commitCurrentCandidateForContinuation()
        XCTAssertEqual(client.requests.last?.input, "ef")
    }

    @MainActor
    func testTypingInSplitRangeRetainsOverflowAheadOfExistingSuffix() {
        let client = JapaneseConversionServingStub()
        let controller = SelfConversionWindowController(client: client)
        defer { controller.cancel() }
        let prefix = String(repeating: "a", count: 256)
        controller.begin()
        controller.append(prefix)
        controller.forceStartCurrentConversion()
        placeSuffixInNextRange(controller, "tail")
        controller.append("ha")
        controller.forceStartCurrentConversion()
        XCTAssertEqual(client.requests.map(\.input), [prefix, prefix])
        client.complete(at: 1, candidates: [JapaneseConversionCandidate(text: "前", score: 1)])
        runMainLoop(for: 0.1)
        controller.commitCurrentCandidateForContinuation()
        XCTAssertEqual(client.requests.last?.input, "hatail")
        XCTAssertTrue(client.requests.allSatisfy { $0.input.unicodeScalars.count <= 256 })
    }

    @MainActor
    func testDeleteEditsActiveRangeAndRetainsQueuedInputDuringRequest() {
        let client = JapaneseConversionServingStub()
        let controller = SelfConversionWindowController(client: client)
        defer { controller.cancel() }
        controller.begin()
        controller.append("kore")
        controller.forceStartCurrentConversion()
        placeSuffixInNextRange(controller, "ha")
        controller.backspace()
        XCTAssertEqual(controller.decisionSnapshot().input, "kor")
        XCTAssertTrue(controller.hasNextSessionInput)
        client.complete(at: 0, candidates: [JapaneseConversionCandidate(text: "古い候補", score: 1)])
        runMainLoop(for: 0.1)
        XCTAssertEqual(controller.decisionSnapshot().input, "kor")
        XCTAssertFalse(controller.decisionSnapshot().candidates.contains { $0.text == "古い候補" })
        controller.forceStartCurrentConversion()
        XCTAssertEqual(client.requests.map(\.input), ["kore", "kor"])
        client.complete(at: 1, candidates: [JapaneseConversionCandidate(text: "新候補", score: 1)])
        runMainLoop(for: 0.1)
        controller.commitCurrentCandidateForContinuation()
        XCTAssertEqual(client.requests.map(\.input), ["kore", "kor", "ha"])
    }

    @MainActor
    func testDeleteCompletedRangeRevisesWithDebounceAndLeavesNextRangeIntact() {
        let client = JapaneseConversionServingStub()
        let controller = SelfConversionWindowController(client: client)
        defer { controller.cancel() }
        controller.begin()
        controller.append("kore")
        controller.forceStartCurrentConversion()
        placeSuffixInNextRange(controller, "ha")
        controller.forceStartCurrentConversion()
        client.complete(at: 1, candidates: [JapaneseConversionCandidate(text: "これ", score: 1)])
        runMainLoop(for: 0.1)
        controller.backspace()
        XCTAssertEqual(controller.decisionSnapshot().input, "kor")
        runMainLoop(for: 2.2)
        XCTAssertEqual(client.requests.map(\.input), ["kore", "kore", "kor"])
        XCTAssertTrue(controller.hasNextSessionInput)
        client.complete(at: 2, candidates: [JapaneseConversionCandidate(text: "新候補", score: 1)])
        runMainLoop(for: 0.1)
        controller.commitCurrentCandidateForContinuation()
        XCTAssertEqual(client.requests.map(\.input), ["kore", "kore", "kor", "ha"])
    }

    @MainActor
    func testDeleteLastActiveCharacterPromotesNextRangeAndRejectsOldResponse() {
        let client = JapaneseConversionServingStub()
        let controller = SelfConversionWindowController(client: client)
        defer { controller.cancel() }
        controller.begin()
        controller.append("a")
        controller.forceStartCurrentConversion()
        placeSuffixInNextRange(controller, "tsugi")
        controller.backspace()
        XCTAssertEqual(client.requests.map(\.input), ["a", "tsugi"])
        XCTAssertEqual(controller.decisionSnapshot().input, "tsugi")
        XCTAssertFalse(controller.hasNextSessionInput)
        client.complete(at: 0, candidates: [JapaneseConversionCandidate(text: "旧", score: 1)])
        runMainLoop(for: 0.1)
        XCTAssertEqual(controller.decisionSnapshot().input, "tsugi")
        XCTAssertFalse(controller.decisionSnapshot().candidates.contains { $0.text == "旧" })
        client.complete(at: 1, candidates: [JapaneseConversionCandidate(text: "次", score: 1)])
        runMainLoop(for: 0.1)
        XCTAssertEqual(controller.confirmAndClose().composedText, "次")
    }

    @MainActor
    func testDeleteDoesNotSplitGraphemeAndEmptyRangeRemainsEditable() {
        let client = JapaneseConversionServingStub()
        let controller = SelfConversionWindowController(client: client)
        defer { controller.cancel() }
        controller.begin()
        controller.append("a👨‍👩‍👧‍👦")
        controller.forceStartCurrentConversion()
        controller.backspace()
        XCTAssertEqual(controller.decisionSnapshot().input, "a")
        controller.backspace()
        XCTAssertEqual(controller.composedText(), "")
        XCTAssertNil(controller.decisionSnapshot().selectedCandidate)
        controller.append("b")
        controller.forceStartCurrentConversion()
        XCTAssertEqual(client.requests.map(\.input), ["a👨‍👩‍👧‍👦", "b"])
    }

    @MainActor
    func testDeletePreservesRemainingWhitespaceUntilRangeIsActuallyEmpty() {
        let client = JapaneseConversionServingStub()
        let controller = SelfConversionWindowController(client: client)
        defer { controller.cancel() }
        controller.begin()
        controller.append(" a")
        controller.forceStartCurrentConversion()
        placeSuffixInNextRange(controller, "next")
        controller.backspace()
        XCTAssertEqual(controller.decisionSnapshot().input, " ")
        XCTAssertEqual(client.requests.map(\.input), [" a"])
        XCTAssertTrue(controller.hasNextSessionInput)
        controller.backspace()
        XCTAssertEqual(controller.decisionSnapshot().input, "next")
        XCTAssertEqual(client.requests.map(\.input), [" a", "next"])
    }

    @MainActor
    func testDeletePromotionPreservesCommittedPrefixAndLongNextRangeOverflow() {
        let client = JapaneseConversionServingStub()
        let controller = SelfConversionWindowController(client: client)
        defer { controller.cancel() }
        controller.begin()
        controller.append("kakutei")
        controller.forceStartCurrentConversion()
        client.complete(at: 0, candidates: [JapaneseConversionCandidate(text: "確定", score: 1)])
        runMainLoop(for: 0.1)
        controller.commitCurrentCandidateForContinuation()
        controller.append("a")
        controller.forceStartCurrentConversion()
        let next = String(repeating: "n", count: 257)
        placeSuffixInNextRange(controller, next)
        controller.backspace()
        XCTAssertEqual(controller.decisionSnapshot().committedText, "確定")
        XCTAssertLessThanOrEqual(client.requests[2].input.unicodeScalars.count, 256)
        XCTAssertTrue(controller.hasNextSessionInput)
        client.complete(at: 2, candidates: [JapaneseConversionCandidate(text: "次", score: 1)])
        runMainLoop(for: 0.1)
        controller.commitCurrentCandidateForContinuation()
        XCTAssertEqual(client.requests[2].input + client.requests[3].input, next)
        XCTAssertTrue(controller.decisionSnapshot().committedText.contains("確定"))
    }

    func testPersonalLearningIsExplicitBoundedAndPreservesTopFive() {
        let suite = "ViMouse.LearningTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var enabled = true
        var date = Date(timeIntervalSince1970: 1_700_000_000)
        let learner = SelfConversionPersonalizer(defaults: defaults, enabled: { enabled }, now: { date })
        let native = (0..<6).map { JapaneseConversionCandidate(text: "候補\($0)", score: 1 - Double($0) / 1000, isNative: true) }
        let candidates = native + [JapaneseConversionCandidate(text: "kouho", score: 0.05)]
        func event(_ index: Int = 3, explicit: Bool = true, output: String? = nil) -> SelfConversionDecisionEvent {
            let selected = candidates[index]
            return SelfConversionDecisionEvent(action: "final_commit", snapshot: SelfConversionDecisionSnapshot(
                input: "kouho", context: "文脈", committedText: "", composedText: selected.text,
                selectedIndex: index, selectedCandidate: selected, candidates: candidates,
                explicitSelection: explicit), committedOutput: output ?? selected.text)
        }
        learner.record(event(explicit: false))
        learner.record(event(output: "不一致"))
        learner.record(event(5)) // Outside top five: never promote into the set.
        learner.record(event(6)) // Original input: not evidence of conversion.
        XCTAssertEqual(learner.rerank(candidates, input: "kouho", context: "文脈"), candidates)
        learner.record(event())
        XCTAssertEqual(learner.rerank(candidates, input: "kouho", context: "文脈"), candidates)
        date += 1
        learner.record(event())
        let ranked = learner.rerank(candidates, input: "kouho", context: "文脈")
        XCTAssertEqual(ranked.first, candidates[3])
        XCTAssertEqual(Set(ranked.prefix(5).map(\.text)), Set(candidates.prefix(5).map(\.text)))
        XCTAssertEqual(Array(ranked.dropFirst(5)), Array(candidates.dropFirst(5)))
        XCTAssertEqual(learner.rerank(candidates, input: "other", context: "文脈"), candidates)
        XCTAssertEqual(learner.rerank(candidates, input: "kouho", context: "別文脈"), candidates)
        let restored = SelfConversionPersonalizer(defaults: defaults, enabled: { enabled }, now: { date })
        XCTAssertEqual(restored.rerank(candidates, input: "kouho", context: "文脈"), ranked)
        enabled = false
        learner.record(event())
        XCTAssertEqual(learner.rerank(candidates, input: "kouho", context: "文脈"), candidates)
        enabled = true
        learner.undoLastLearning()
        XCTAssertEqual(learner.rerank(candidates, input: "kouho", context: "文脈"), candidates)
        learner.record(event())
        date += 91 * 86400
        XCTAssertEqual(learner.rerank(candidates, input: "kouho", context: "文脈"), candidates)
        learner.clear()
        learner.undoLastLearning()
        XCTAssertNil(defaults.data(forKey: "preferences.v1"))
    }

    func testPersonalLearningRejectsFallbackAndMalformedStorageAndSupportsShortNativeLists() {
        let suite = "ViMouse.LearningTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not JSON".utf8), forKey: "preferences.v1")
        let learner = SelfConversionPersonalizer(defaults: defaults, enabled: { true })
        let candidates = [JapaneseConversionCandidate(text: "最初", score: 0.999, isNative: true),
                          JapaneseConversionCandidate(text: "選択", score: 0.998, isNative: true),
                          JapaneseConversionCandidate(text: "input", score: 0.05)]
        for _ in 0..<2 {
            learner.record(SelfConversionDecisionEvent(action: "partial_commit", snapshot: SelfConversionDecisionSnapshot(
                input: "input", context: "", committedText: "", composedText: "選択next",
                selectedIndex: 1, selectedCandidate: candidates[1], candidates: candidates,
                explicitSelection: true), committedOutput: "選択"))
        }
        XCTAssertEqual(learner.rerank(candidates, input: "input", context: "").map(\.text), ["選択", "最初", "input"])
        let fallback = candidates.map { JapaneseConversionCandidate(text: $0.text, score: $0.score) }
        XCTAssertEqual(learner.rerank(fallback, input: "input", context: ""), fallback)
        learner.clear()
        for _ in 0..<2 {
            learner.record(SelfConversionDecisionEvent(action: "final_commit", snapshot: SelfConversionDecisionSnapshot(
                input: "input", context: "", committedText: "", composedText: "選択",
                selectedIndex: 1, selectedCandidate: fallback[1], candidates: fallback,
                explicitSelection: true), committedOutput: "選択"))
        }
        XCTAssertEqual(learner.rerank(candidates, input: "input", context: ""), candidates)
    }

    func testNativeConversionBackendKeepsItsRankingAndDoesNotStripHistory() {
        let texts = ["NEWギャラリーの会館", "都内(", "日本語", "日本語を入力"]
        let root: [String: Any] = ["ok": true, "kind": "vimouse-mozc-v2", "ranking": "native-top5-v1",
                                   "candidates": texts.map { ["text": $0, "score": 0.01] }]
        let parsed = SelfConversionCandidateBuilder.parseCandidates(from: root, input: "nyuugyararii")
        let result = SelfConversionCandidateBuilder.mergeResponse(
            root: root, parsed: parsed,
            fallback: [JapaneseConversionCandidate(text: "ローカル推測", score: 1)],
            context: "日本語", requiredText: "nyuugyararii")
        XCTAssertEqual(Array(result.prefix(4)).map(\.text), texts)
        XCTAssertEqual(result.last?.text, "nyuugyararii")
        XCTAssertTrue(zip(result, result.dropFirst()).allSatisfy { $0.score > $1.score })
    }

    func testNativeConversionBackendStillRejectsInvalidCandidateText() {
        let root: [String: Any] = ["ok": true, "kind": "vimouse-mozc-v2", "ranking": "native-top5-v1",
                                   "candidates": [["text": ""], ["text": "bad\ntext"],
                                                  ["text": "\u{FFFD}"], ["text": String(repeating: "a", count: 1025)],
                                                  ["text": "日本語"]]]
        XCTAssertEqual(SelfConversionCandidateBuilder.parseCandidates(from: root, input: "nihongo").map(\.text), ["日本語"])
    }

    func testNativeConversionFlagDoesNotBypassLegacyBackendFilters() {
        for kind in ["ogura2", "unknown"] {
            let root: [String: Any] = ["ok": true, "kind": kind, "ranking": "native-top5-v1",
                                       "candidates": [["text": "NEWギャラリー", "score": 1]]]
            XCTAssertEqual(SelfConversionCandidateBuilder.parseCandidates(from: root, input: "nyuugyararii"), [])
        }
    }

    @MainActor
    func testRemoteAgentSettingsToggleDisplayAndRotateURL() throws {
        let suite = "ViMouse.AgentSettingsTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        var token = String(repeating: "a", count: 64)
        let api = RemoteAgentAPI(defaults: defaults, tokenStore: { replacement in
            if let replacement { token = replacement }; return token
        }, actionOverride: { _, _ in ["test": true] })
        defer { api.stop(); defaults.removePersistentDomain(forName: suite) }
        let controller = SettingsWindowController(remoteAgent: api)
        defer { controller.close() }
        let tabs = try XCTUnwrap(controller.window?.contentView?.subviews.compactMap { $0 as? NSTabView }.first)
        tabs.selectTabViewItem(withIdentifier: "remoteAgent")
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(try XCTUnwrap(tabs.selectedTabViewItem?.view))
        let buttons = views.compactMap { $0 as? NSButton }
        let toggle = try XCTUnwrap(buttons.first { $0.action == NSSelectorFromString("toggleRemoteAgent:") })
        let rotate = try XCTUnwrap(buttons.first { $0.action == NSSelectorFromString("rotateRemoteAgentToken:") })
        let copy = try XCTUnwrap(buttons.first { $0.action == NSSelectorFromString("copyRemoteAgentURL:") })
        let field = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first { $0.stringValue.contains("/agent/docs?token=") })
        XCTAssertFalse(api.enabled)
        XCTAssertTrue(copy.isEnabled)
        XCTAssertTrue(field.stringValue.hasSuffix(token))
        toggle.performClick(nil)
        XCTAssertTrue(api.enabled, api.status)
        XCTAssertEqual(toggle.state, .on)
        let oldURL = field.stringValue
        rotate.performClick(nil)
        XCTAssertNotEqual(field.stringValue, oldURL)
        XCTAssertTrue(field.stringValue.hasSuffix(token))
        api.setEnabled(false)
        XCTAssertEqual(toggle.state, .off)
        XCTAssertTrue(copy.isEnabled)
    }

    func testViMouseLaunchAgentUsesTheApplicationExecutableAndRunsAtLogin() {
        let executablePath = "/Applications/ViMouse.app/Contents/MacOS/ViMouse"
        let propertyList = ViMouseLaunchAgent.propertyList(executablePath: executablePath)

        XCTAssertEqual(propertyList["Label"] as? String, ViMouseLaunchAgent.label)
        XCTAssertEqual(propertyList["ProgramArguments"] as? [String], [executablePath])
        XCTAssertEqual(propertyList["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(propertyList["KeepAlive"] as? Bool, false)
        XCTAssertEqual(propertyList["ProcessType"] as? String, "Interactive")
        XCTAssertEqual(propertyList["LimitLoadToSessionType"] as? String, "Aqua")
    }

    func testViMouseLaunchAgentURLIsUserScoped() {
        let homeDirectory = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

        XCTAssertEqual(
            ViMouseLaunchAgent.launchAgentURL(homeDirectory: homeDirectory).path,
            "/Users/tester/Library/LaunchAgents/com.s21g.ViMouse.plist"
        )
    }

    func testAllowsMovementAcrossAdjacentDisplays() {
        let displays = [
            CGRect(x: 0, y: 0, width: 100, height: 100),
            CGRect(x: 100, y: 0, width: 100, height: 100),
        ]

        let position = MouseMovementBounds.nextPosition(
            current: CGPoint(x: 99, y: 50),
            delta: CGVector(dx: 2, dy: 0),
            displays: displays
        )

        XCTAssertEqual(position, CGPoint(x: 101, y: 50))
    }

    func testClampsToCurrentDisplayWhenMovingIntoGapBetweenDisplays() {
        let displays = [
            CGRect(x: 0, y: 0, width: 100, height: 100),
            CGRect(x: 120, y: 0, width: 100, height: 100),
        ]

        let position = MouseMovementBounds.nextPosition(
            current: CGPoint(x: 99, y: 50),
            delta: CGVector(dx: 2, dy: 0),
            displays: displays
        )

        XCTAssertEqual(position, CGPoint(x: 99, y: 50))
    }

    func testInputHookPassesThroughKeysTheDelegateDoesNotConsume() {
        let hook = InputHook()
        let delegate = InputHookDelegateStub(results: [false, false])
        hook.delegate = delegate

        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)!

        XCTAssertFalse(hook.keyDown(down))
        XCTAssertFalse(hook.keyUp(up))
        XCTAssertEqual(delegate.calls.map(\.pressed), [true, false])
    }

    func testInputHookKeepsRepeatKeyEventsConsistentWithInitialDecision() {
        let hook = InputHook()
        let delegate = InputHookDelegateStub(results: [false, false])
        hook.delegate = delegate

        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!

        XCTAssertFalse(hook.keyDown(down))
        XCTAssertFalse(hook.keyDown(down))
        XCTAssertEqual(delegate.calls.map(\.pressed), [true])
        XCTAssertEqual(delegate.repeatCalls.count, 0)
    }

    func testInputHookForwardsConsumedRepeatKeyEventsSeparately() {
        let hook = InputHook()
        let delegate = InputHookDelegateStub(results: [true, false])
        hook.delegate = delegate

        let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Delete), keyDown: true)!

        XCTAssertTrue(hook.keyDown(down))
        XCTAssertTrue(hook.keyDown(down))
        XCTAssertEqual(delegate.calls.map(\.pressed), [true])
        XCTAssertEqual(delegate.repeatCalls.map(\.keycode), [Int64(kVK_Delete)])
    }

    func testKeyMappingStoresAndResetsCustomKeyCodes() {
        KeyMapping.resetDefaults()
        XCTAssertEqual(KeyMapping.keyCode(for: .selfConversionToggle), kVK_JIS_Kana)
        XCTAssertEqual(KeyMapping.keyCode(for: .moveLeft), kVK_ANSI_H)

        KeyMapping.setKeyCode(kVK_ANSI_B, for: .selfConversionToggle)
        XCTAssertEqual(KeyMapping.keyCode(for: .selfConversionToggle), kVK_ANSI_B)

        KeyMapping.setKeyCode(kVK_ANSI_A, for: .moveLeft)
        XCTAssertEqual(KeyMapping.keyCode(for: .moveLeft), kVK_ANSI_A)

        KeyMapping.resetDefaults()
        XCTAssertEqual(KeyMapping.keyCode(for: .selfConversionToggle), kVK_JIS_Kana)
        XCTAssertEqual(KeyMapping.keyCode(for: .moveLeft), kVK_ANSI_H)
    }

    func testCursorRippleDefaultsToMAndCanBeRemapped() {
        KeyMapping.resetDefaults()
        XCTAssertEqual(KeyMapping.keyCode(for: .cursorRipple), kVK_ANSI_M)

        KeyMapping.setKeyCode(kVK_ANSI_O, for: .cursorRipple)
        XCTAssertEqual(KeyMapping.keyCode(for: .cursorRipple), kVK_ANSI_O)

        KeyMapping.resetDefaults()
        XCTAssertEqual(KeyMapping.keyCode(for: .cursorRipple), kVK_ANSI_M)
    }

    func testWindowNavigationActionMapping() {
        XCTAssertEqual(WindowNavigationAction.action(for: kVK_ANSI_H), .previousSpace)
        XCTAssertEqual(WindowNavigationAction.action(for: kVK_ANSI_L), .nextSpace)
        XCTAssertEqual(WindowNavigationAction.action(for: kVK_ANSI_J), .frontApplicationWindows)
        XCTAssertEqual(WindowNavigationAction.action(for: kVK_ANSI_K), .allWindows)
        XCTAssertNil(WindowNavigationAction.action(for: kVK_ANSI_B))
    }

    func testTrackpadEdgeSwipeRecognizesBothDirectionsOncePerTouch() {
        var detector = TrackpadEdgeSwipeDetector()
        XCTAssertNil(detector.record(.finger(id: 1, position: CGPoint(x: 1.02, y: 0.5), began: true), at: 1))
        XCTAssertNil(detector.record(.finger(id: 1, position: CGPoint(x: 0.90, y: 0.52), began: false), at: 1.08))
        XCTAssertEqual(detector.record(.finger(id: 1, position: CGPoint(x: 0.78, y: 0.52), began: false), at: 1.16), .left)
        XCTAssertNil(detector.record(.finger(id: 1, position: CGPoint(x: 0.53, y: 0.53), began: false), at: 1.25))
        XCTAssertNil(detector.record(.idle, at: 1.3))
        XCTAssertNil(detector.record(.finger(id: 2, position: CGPoint(x: 0.003, y: 0.4), began: false), at: 1.4))
        XCTAssertEqual(detector.record(.finger(id: 2, position: CGPoint(x: 0.25, y: 0.43), began: false), at: 1.55), .right)
    }

    func testTrackpadSlideOutUsesStartingDisplayAndRequiresExit() {
        let session = TrackpadEdgeSwipeSession()
        typealias Frame = TrackpadEdgeSwipeDetector.Frame
        func finger(_ x: CGFloat, began: Bool = false) -> Frame {
            .finger(id: 7, position: CGPoint(x: x, y: 0.5), began: began)
        }
        for (start, edge, expected) in [(0.82, 0.998, TrackpadEdgeSwipeDetector.Direction.right),
                                        (0.18, 0.002, .left)] {
            XCTAssertNil(session.record(device: 1, frame: finger(CGFloat(start), began: true), at: 1) { 3 })
            XCTAssertNil(session.record(device: 1, frame: finger(CGFloat(edge)), at: 1.1) { 8 })
            let result = session.record(device: 1, frame: .idle, at: 1.2) { 8 }
            XCTAssertEqual(result?.0, expected)
            XCTAssertEqual(result?.1, 3)
            XCTAssertNil(session.record(device: 1, frame: .idle, at: 1.21) { 8 })
        }
        XCTAssertNil(session.record(device: 1, frame: finger(0.82, began: true), at: 2) { 3 })
        XCTAssertNil(session.record(device: 1, frame: finger(0.995), at: 2.1) { 8 })
        XCTAssertNil(session.record(device: 1, frame: finger(0.9), at: 2.2) { 8 })
        XCTAssertNil(session.record(device: 1, frame: .idle, at: 2.3) { 8 })
        XCTAssertNil(session.record(device: 1, frame: finger(0.03, began: true), at: 3) { 4 })
        XCTAssertNil(session.record(device: 1, frame: finger(0.015), at: 3.05) { 8 })
        let end = Frame.ended(id: 7, position: CGPoint(x: 0, y: 0.5))
        XCTAssertEqual(session.record(device: 1, frame: end, at: 3.1) { 8 }?.0, .left)
    }

    func testTrackpadEdgeSwipeRecognizesSparseAndShortenedEdgeTraces() {
        typealias Detector = TrackpadEdgeSwipeDetector
        // Mirror each trace so both sides exercise the same recognition rules.
        for mirrored in [false, true] {
            func point(_ x: CGFloat, _ y: CGFloat = 0.5) -> CGPoint {
                CGPoint(x: mirrored ? 1 - x : x, y: y)
            }
            let inward: Detector.Direction = mirrored ? .left : .right
            let outward: Detector.Direction = mirrored ? .right : .left
            var d = Detector()
            XCTAssertNil(d.record(.finger(id: 1, position: point(0.002), began: true), at: 0))
            XCTAssertNil(d.record(.finger(id: 1, position: point(0.10, 0.53), began: false), at: 0.44))
            XCTAssertEqual(d.record(.ended(id: 1, position: point(0.22, 0.57)), at: 0.55), inward)
            XCTAssertNil(d.record(.idle, at: 0.56))

            XCTAssertNil(d.record(.finger(id: 2, position: point(0.18), began: true), at: 1))
            XCTAssertNil(d.record(.finger(id: 2, position: point(0.003), began: false), at: 1.25))
            XCTAssertEqual(d.record(.ended(id: 2, position: CGPoint(x: 0, y: 0)), at: 1.30), outward)
            XCTAssertNil(d.record(.idle, at: 1.31))

            // Lifting after a small movement near the edge is an ordinary tap.
            XCTAssertNil(d.record(.finger(id: 3, position: point(0.055), began: true), at: 2))
            XCTAssertNil(d.record(.finger(id: 3, position: point(0.035), began: false), at: 2.1))
            XCTAssertNil(d.record(.ended(id: 3, position: point(0.035)), at: 2.12))
        }
    }

    func testTrackpadAcceptsNextContactWithoutInterveningLiftFrame() {
        var detector = TrackpadEdgeSwipeDetector()
        func contact(_ id: Int32, _ x: CGFloat, _ began: Bool = false) -> TrackpadEdgeSwipeDetector.Frame {
            .finger(id: id, position: CGPoint(x: x, y: 0.5), began: began)
        }
        XCTAssertNil(detector.record(contact(1, 0.998, true), at: 0))
        XCTAssertEqual(detector.record(contact(1, 0.75), at: 0.1), .left)
        XCTAssertNil(detector.record(contact(1, 0.55), at: 0.15))
        XCTAssertNil(detector.record(contact(2, 0.002), at: 0.25))
        XCTAssertNil(detector.record(.ended(id: 1, position: CGPoint(x: 0.5, y: 0.5)), at: 0.26))
        XCTAssertEqual(detector.record(contact(2, 0.24), at: 0.35), .right)
        XCTAssertNil(detector.record(contact(2, 0.998, true), at: 0.55))
        XCTAssertEqual(detector.record(contact(2, 0.73), at: 0.65), .left)
    }

    func testTrackpadEdgeSwipeRejectsLateEntryAndOtherPointerMotion() {
        let tracks: [[(CGFloat, CGFloat, TimeInterval)]] = [
            [(0.5, 0.5, 0), (0.97, 0.5, 0.1), (0.72, 0.5, 0.2)], // 中央から端を横切る
            [(0.998, 0.5, 0), (0.94, 0.68, 0.1), (0.71, 0.5, 0.2)], // 縦方向の移動
            [(0.001, 0.5, 0), (0.25, 0.5, 0.5)], // 長い静止
            [(0.95, 0.5, 0), (0.99, 0.5, 0.1), (0.72, 0.5, 0.2)], // 先に外側へ向かう
            [(0.003, 0.5, 0), (0.12, 0.5, 0.15)], // 移動が短い
        ]
        for track in tracks {
            var detector = TrackpadEdgeSwipeDetector()
            for (index, point) in track.enumerated() {
                XCTAssertNil(detector.record(.finger(id: 1, position: CGPoint(x: point.0, y: point.1),
                                                     began: index == 0), at: 1 + point.2))
            }
        }
    }

    func testTrackpadEdgeSwipeWaitsForNewContactAfterMonitoringStartsOrMultitouch() {
        var detector = TrackpadEdgeSwipeDetector()
        let edge = CGPoint(x: 0.998, y: 0.5)
        let inside = CGPoint(x: 0.74, y: 0.5)
        XCTAssertNil(detector.record(.finger(id: 1, position: edge, began: false), at: 0))
        XCTAssertNil(detector.record(.finger(id: 1, position: inside, began: false), at: 0.1))
        XCTAssertNil(detector.record(.idle, at: 1))
        XCTAssertNil(detector.record(.finger(id: 2, position: edge, began: true), at: 1.1))
        XCTAssertNil(detector.record(.multipleOrInvalid, at: 1.2))
        XCTAssertNil(detector.record(.finger(id: 2, position: inside, began: false), at: 1.25))
        XCTAssertNil(detector.record(.finger(id: 3, position: edge, began: true), at: 1.3))
        XCTAssertEqual(detector.record(.finger(id: 3, position: inside, began: false), at: 1.4), .left)
        XCTAssertNil(detector.record(.idle, at: 2))
        XCTAssertNil(detector.record(.finger(id: 4, position: edge, began: true), at: 2.1))
        XCTAssertNil(detector.record(.finger(id: 5, position: inside, began: false), at: 2.2))
        XCTAssertNil(detector.record(.idle, at: 3))
        XCTAssertNil(detector.record(.finger(id: 6, position: edge, began: true), at: 3.1))
        XCTAssertEqual(detector.record(.finger(id: 6, position: inside, began: false), at: 3.2), .left)
    }

    func testTrackpadInfersAnOutwardCrossingOnlyOnPromptRelease() {
        for mirrored in [false, true] {
            func point(_ x: CGFloat) -> CGPoint { CGPoint(x: mirrored ? 1 - x : x, y: 0.5) }
            func approaching() -> TrackpadEdgeSwipeDetector {
                var d = TrackpadEdgeSwipeDetector()
                for (x,t) in [(0.17,0.0), (0.09,0.07), (0.031,0.12)] {
                    XCTAssertNil(d.record(.finger(id: 4, position: point(CGFloat(x)), began: t == 0), at: t))
                }
                return d
            }
            let expected: TrackpadEdgeSwipeDetector.Direction = mirrored ? .right : .left
            for release: TrackpadEdgeSwipeDetector.Frame in [.idle, .ended(id: 4, position: point(0.031)),
                                                             .ended(id: 4, position: CGPoint(x: 0, y: 0))] {
                var d = approaching()
                XCTAssertEqual(d.record(release, at: 0.14), expected)
                XCTAssertNil(d.record(.idle, at: 0.15))
            }
            let still = TrackpadEdgeSwipeDetector.Frame.finger(id: 4, position: point(0.031), began: false)
            var repeated = approaching()
            XCTAssertNil(repeated.record(still, at: 0.13))
            XCTAssertEqual(repeated.record(.idle, at: 0.15), expected)
            var paused = approaching()
            XCTAssertNil(paused.record(still, at: 0.25))
            XCTAssertNil(paused.record(.idle, at: 0.30))
            var reversed = approaching()
            XCTAssertNil(reversed.record(.ended(id: 4, position: point(0.085)), at: 0.14))
            var multi = approaching()
            XCTAssertNil(multi.record(.multipleOrInvalid, at: 0.13))
            XCTAssertNil(multi.record(.idle, at: 0.14))
        }
    }

    func testTrackpadNewFingerNeverCompletesPreviousSwipe() {
        typealias Frame = TrackpadEdgeSwipeDetector.Frame
        func finger(_ x: CGFloat, _ id: Int32, _ began: Bool = false) -> Frame {
            .finger(id: id, position: CGPoint(x: x, y: 0.5), began: began)
        }
        // No lift between the unfinished swipe and a tap; the device can reuse its ID.
        for nextID: Int32 in [1, 2] {
            var d = TrackpadEdgeSwipeDetector()
            XCTAssertNil(d.record(finger(0.002, 1, true), at: 0))
            XCTAssertNil(d.record(finger(0.09, 1), at: 0.07))
            XCTAssertNil(d.record(finger(0.23, nextID, true), at: 0.13))
            XCTAssertNil(d.record(.ended(id: nextID, position: CGPoint(x: 0.23, y: 0.5)), at: 0.16))
            // A rejected interior touch also cannot swallow the next rim entry.
            XCTAssertNil(d.record(finger(0.5, 1, true), at: 1))
            XCTAssertNil(d.record(finger(0.52, 1), at: 1.03))
            XCTAssertNil(d.record(finger(0.998, nextID, true), at: 1.1))
            XCTAssertEqual(d.record(finger(0.75, nextID), at: 1.17), .left)
        }
        var afterMultitouch = TrackpadEdgeSwipeDetector()
        XCTAssertNil(afterMultitouch.record(.multipleOrInvalid, at: 0))
        XCTAssertNil(afterMultitouch.record(finger(0.002, 1), at: 0.02))
        XCTAssertNil(afterMultitouch.record(finger(0.25, 1), at: 0.05))
        XCTAssertNil(afterMultitouch.record(finger(0.002, 2, true), at: 0.08))
        XCTAssertEqual(afterMultitouch.record(finger(0.25, 2), at: 0.13), .right)
        var twoBegins = TrackpadEdgeSwipeDetector()
        XCTAssertNil(twoBegins.record(finger(0.002, 1, true), at: 0))
        XCTAssertNil(twoBegins.record(finger(0.3, 1, true), at: 0.1))
        XCTAssertNil(twoBegins.record(.idle, at: 0.15))
        for boundary: Frame in [.approaching(id: 1, position: CGPoint(x: 0.4, y: 0.5)), .idle] {
            var d = TrackpadEdgeSwipeDetector()
            XCTAssertNil(d.record(finger(0.12, 1, true), at: 0))
            XCTAssertNil(d.record(finger(0.002, 1), at: 0.08))
            XCTAssertNil(d.record(boundary, at: 0.35))
            XCTAssertNil(d.record(finger(0.4, 1, true), at: 0.36))
            XCTAssertNil(d.record(.idle, at: 0.40))
        }
    }

    func testFastSlideInPreservesRimAcrossApproachAndRepeatedBegin() {
        typealias Frame = TrackpadEdgeSwipeDetector.Frame
        func point(_ x: CGFloat) -> CGPoint { CGPoint(x: x, y: 0.5) }
        func touch(_ x: CGFloat, _ began: Bool = false) -> Frame {
            .finger(id: 7, position: point(x), began: began)
        }
        for initial: Frame in [.approaching(id: 7, position: point(0.998)), touch(0.998, true)] {
            var d = TrackpadEdgeSwipeDetector()
            XCTAssertNil(d.record(initial, at: 0))
            XCTAssertNil(d.record(touch(0.91, true), at: 0.02))
            XCTAssertEqual(d.record(touch(0.84), at: 0.04), .left)
            XCTAssertNil(d.record(.idle, at: 0.05))
        }
        for (id, startTime) in [(Int32(6), 0.02), (7, 0.2)] {
            var d = TrackpadEdgeSwipeDetector()
            XCTAssertNil(d.record(.approaching(id: id, position: point(0.998)), at: 0))
            XCTAssertNil(d.record(touch(0.91, true), at: startTime))
            XCTAssertNil(d.record(touch(0.74), at: startTime + 0.04))
        }
        var tap = TrackpadEdgeSwipeDetector()
        XCTAssertNil(tap.record(.approaching(id: 7, position: point(0.998)), at: 0))
        XCTAssertNil(tap.record(touch(0.80, true), at: 0.02))
        XCTAssertNil(tap.record(.ended(id: 7, position: point(0.80)), at: 0.04))
        var fast = TrackpadEdgeSwipeDetector()
        XCTAssertNil(fast.record(touch(0.998, true), at: 0))
        XCTAssertNil(fast.record(touch(0.93), at: 0.02))
        XCTAssertEqual(fast.record(.ended(id: 7, position: point(0.62)), at: 0.045), .left)
    }

    func testFastSlideInKeepsDisplayFromFirstRimSample() {
        let session = TrackpadEdgeSwipeSession()
        typealias Frame = TrackpadEdgeSwipeDetector.Frame
        var sampled: [UInt32] = []
        func send(_ frame: Frame, _ time: Double, _ screen: UInt32) -> UInt32? {
            session.record(device: 1, frame: frame, at: time) {
                sampled.append(screen)
                return screen
            }?.1
        }
        func p(_ x: CGFloat) -> CGPoint { CGPoint(x: x, y: 0.5) }
        XCTAssertNil(send(.approaching(id: 9, position: p(0.998)), 0, 2))
        XCTAssertNil(send(.approaching(id: 9, position: p(0.997)), 0.004, 1))
        XCTAssertNil(send(.finger(id: 9, position: p(0.91), began: true), 0.015, 1))
        XCTAssertEqual(send(.finger(id: 9, position: p(0.84), began: false), 0.025, 1), 2)
        XCTAssertEqual(sampled, [2])
        XCTAssertNil(send(.idle, 0.03, 1))

        // An expired approach must not route a later independent swipe to the old screen.
        XCTAssertNil(send(.approaching(id: 10, position: p(0.998)), 1, 2))
        XCTAssertNil(send(.finger(id: 10, position: p(0.998), began: true), 1.3, 1))
        XCTAssertEqual(send(.finger(id: 10, position: p(0.75), began: false), 1.4, 1), 1)
    }

    func testTrackpadInteriorMotionNeverQualifiesAsRimEntry() {
        var corner = TrackpadEdgeSwipeDetector()
        XCTAssertNil(corner.record(.finger(id: 1, position: CGPoint(x: 0.12, y: 0.03), began: true), at: 0))
        XCTAssertNil(corner.record(.finger(id: 1, position: CGPoint(x: 0.035, y: 0.03), began: false), at: 0.1))
        XCTAssertNil(corner.record(.ended(id: 1, position: CGPoint(x: 0, y: 0)), at: 0.15))

        for mirror in [false, true] {
            for start: CGFloat in [0.006, 0.02, 0.04, 0.08] {
                var d = TrackpadEdgeSwipeDetector()
                func finger(_ x: CGFloat, _ began: Bool) -> TrackpadEdgeSwipeDetector.Frame {
                    .finger(id: 8, position: CGPoint(x: mirror ? 1 - x : x, y: 0.5), began: began)
                }
                XCTAssertNil(d.record(finger(start, true), at: 0))
                XCTAssertNil(d.record(finger(start + 0.20, false), at: 0.12))
                XCTAssertNil(d.record(.idle, at: 0.14))
                XCTAssertNil(d.record(finger(0.20, true), at: 1))
                XCTAssertNil(d.record(finger(start, false), at: 1.12))
                XCTAssertNil(d.record(.idle, at: 1.14))
                XCTAssertNil(d.record(finger(start, true), at: 2))
                XCTAssertNil(d.record(finger(0.001, false), at: 2.1))
                XCTAssertNil(d.record(finger(0.24, false), at: 2.2))
                XCTAssertNil(d.record(.idle, at: 2.3))
            }
        }
    }

    func testCursorRippleIgnoresModifiedKeysAndKeyUp() {
        KeyMapping.resetDefaults()

        XCTAssertTrue(CursorRippleTrigger.shouldTrigger(
            keycode: kVK_ANSI_M,
            flags: InputHook.Flags(),
            pressed: true
        ))
        XCTAssertFalse(CursorRippleTrigger.shouldTrigger(
            keycode: kVK_ANSI_M,
            flags: InputHook.Flags(ctrl: true),
            pressed: true
        ))
        XCTAssertFalse(CursorRippleTrigger.shouldTrigger(
            keycode: kVK_ANSI_M,
            flags: InputHook.Flags(),
            pressed: false
        ))
    }

    func testCursorShakeWaitsForThirdReturnAcrossDifferentAxes() {
        for angle in [0.0, Double.pi / 2, Double.pi * 1.25] {
            let points = [0.0, 38, 2, 35, 3, 39, 23, 5].map { distance in
                CGPoint(x: -300 + distance * cos(angle), y: 700 + distance * sin(angle))
            }
            var detector = CursorShakeDetector()
            let triggers = points.enumerated().compactMap { index, point in
                detector.record(point, at: 1 + Double(index) * 0.08) ? point : nil
            }
            XCTAssertEqual(triggers, [points[points.count - 1]])
        }
    }

    func testCursorShakeHandlesSmallJitterAndSuppressesRepeatedRipples() {
        let offsets: [CGFloat] = [0, 7, 17, 27, 25, 30, 25, 18, 12, 5, 1,
                                  10, 20, 30, 20, 10, 0, 10, 20, 30, 20, 10, 0]
        var detector = CursorShakeDetector()
        func recordTrip(at start: TimeInterval) -> Int {
            var count = 0
            for (index, x) in offsets.enumerated() {
                let point = CGPoint(x: x, y: CGFloat(index % 3) - 1)
                if detector.record(point, at: start + Double(index) * 0.025) { count += 1 }
            }
            return count
        }
        XCTAssertEqual(recordTrip(at: 1), 1)
        detector.reset() // A scroll or button event must not clear the cooldown.
        XCTAssertEqual(recordTrip(at: 1.6), 0)
        XCTAssertEqual(recordTrip(at: 3), 1)
    }

    func testCursorShakeRejectsNormalPointerMotion() {
        let tinyJitter = (0..<20).map { CGPoint(x: $0 % 2 * 4, y: $0 % 3) }
        let longGlide = (0..<30).map { CGPoint(x: $0 * 20, y: 0) }
        let wideShakes = (0..<11).map { CGPoint(x: $0 % 2 * 150, y: 0) }
        let circle = (0...80).map { index in
            let angle = Double(index) * .pi / 8
            return CGPoint(x: 10 * cos(angle), y: 10 * sin(angle))
        }
        let slowShakes = (0..<11).map { CGPoint(x: $0 % 2 * 30, y: 0) }
        for (points, interval) in [(tinyJitter, 0.02), (longGlide, 0.02),
                                    (wideShakes, 0.08), (circle, 0.01),
                                    (slowShakes, 0.35), (slowShakes, 0.3)] {
            var detector = CursorShakeDetector()
            for (index, point) in points.enumerated() {
                XCTAssertFalse(detector.record(point, at: 1 + Double(index) * interval))
            }
        }
    }

    func testCursorShakeDoesNotCombineMotionAcrossAnInterruption() {
        var detector = CursorShakeDetector()
        let offsets = [0, 30, 0, 30, 0, 30, 0]
        for (index, x) in offsets.enumerated() {
            if index == 4 { detector.reset() }
            XCTAssertFalse(detector.record(CGPoint(x: x, y: 0), at: 1 + Double(index) * 0.08))
        }
    }

    func testMovementSettingsStoreClampAndResetValues() {
        MovementSettings.resetDefaults()
        XCTAssertEqual(MovementSettings.value(for: .baseSpeed), MovementSetting.baseSpeed.defaultValue, accuracy: 0.0001)

        MovementSettings.setValue(2.5, for: .baseSpeed)
        XCTAssertEqual(MovementSettings.value(for: .baseSpeed), 2.5, accuracy: 0.0001)

        MovementSettings.setValue(-1.0, for: .baseSpeed)
        XCTAssertEqual(MovementSettings.value(for: .baseSpeed), MovementSetting.baseSpeed.minimumValue, accuracy: 0.0001)

        MovementSettings.resetDefaults()
        XCTAssertEqual(MovementSettings.value(for: .baseSpeed), MovementSetting.baseSpeed.defaultValue, accuracy: 0.0001)
    }

    func testSelfConversionSettingsStoreAndResetEnabledFlag() {
        SelfConversionSettings.resetDefaults()
        XCTAssertFalse(SelfConversionSettings.enabled)
        XCTAssertTrue(SelfConversionSettings.hasAPIEndpoint)

        SelfConversionSettings.enabled = true
        XCTAssertTrue(SelfConversionSettings.enabled)

        SelfConversionSettings.resetDefaults()
        XCTAssertFalse(SelfConversionSettings.enabled)
    }

    func testSelfConversionSettingsStoresNormalizedAPIEndpoint() {
        SelfConversionSettings.resetDefaults()

        SelfConversionSettings.apiEndpoint = "  http://127.0.0.1:8767/convert  "

        XCTAssertEqual(SelfConversionSettings.apiEndpoint, "http://127.0.0.1:8767/convert")
        XCTAssertEqual(SelfConversionSettings.apiEndpointURL, URL(string: "http://127.0.0.1:8767/convert"))
        XCTAssertTrue(SelfConversionSettings.hasAPIEndpoint)

        SelfConversionSettings.apiEndpoint = "http://127.0.0.1:11434/api/generate"
        XCTAssertEqual(SelfConversionSettings.apiEndpoint, "http://127.0.0.1:8767/convert")

        SelfConversionSettings.apiEndpoint = "http://127.0.0.1:8766/api/generate"
        XCTAssertEqual(SelfConversionSettings.apiEndpoint, "http://127.0.0.1:8767/convert")

        SelfConversionSettings.apiEndpoint = "http://127.0.0.1:8767/convert"
        XCTAssertEqual(SelfConversionSettings.apiEndpoint, "http://127.0.0.1:8767/convert")

        SelfConversionSettings.resetDefaults()
        XCTAssertEqual(SelfConversionSettings.apiEndpoint, "http://127.0.0.1:8767/convert")
        XCTAssertEqual(SelfConversionSettings.apiEndpointURL, URL(string: "http://127.0.0.1:8767/convert"))
        XCTAssertEqual(SelfConversionSettings.feedbackEndpointURL, URL(string: "http://127.0.0.1:8767/feedback"))
        XCTAssertEqual(SelfConversionSettings.requestTimeout, 10.0, accuracy: 0.0001)
        XCTAssertTrue(SelfConversionSettings.hasAPIEndpoint)
    }

    func testSelfConversionSettingsClampsRequestTimeout() {
        SelfConversionSettings.resetDefaults()

        SelfConversionSettings.setRequestTimeout(0.1)
        XCTAssertEqual(SelfConversionSettings.requestTimeout, 0.4, accuracy: 0.0001)

        SelfConversionSettings.setRequestTimeout(20)
        XCTAssertEqual(SelfConversionSettings.requestTimeout, 10.0, accuracy: 0.0001)

        SelfConversionSettings.resetDefaults()
    }

    func testSelfConversionSettingsMigratesLegacyWinVRTimeout() {
        SelfConversionSettings.resetDefaults()

        SelfConversionSettings.apiEndpoint = "http://127.0.0.1:8767/convert"
        SelfConversionSettings.setRequestTimeout(5.0)

        XCTAssertEqual(SelfConversionSettings.requestTimeout, 10.0, accuracy: 0.0001)

        SelfConversionSettings.resetDefaults()
    }

    func testJapaneseConversionRequestBodyUsesVMCConvertShape() {
        let body = JapaneseConversionRequestBuilder.requestBody(for: "tesutowositeimasu.", context: "これは")

        XCTAssertEqual(body["input"] as? String, "tesutowositeimasu.")
        XCTAssertEqual(body["context"] as? String, "これは")
        XCTAssertEqual(body["max_len"] as? Int, 16)
        XCTAssertEqual(body["max_new_tokens"] as? Int, 16)
        XCTAssertEqual(body["num_beams"] as? Int, 5)
        XCTAssertNil(body["model"])
        XCTAssertNil(body["prompt"])
        XCTAssertNil(body["options"])
    }

    func testJapaneseConversionRequestBodyExpandsTokenBudgetForLongInput() {
        let body = JapaneseConversionRequestBuilder.requestBody(
            for: "ta-gettonoitinomojishokuwoakanisitekudasai"
        )

        XCTAssertGreaterThan(body["max_new_tokens"] as? Int ?? 0, 16)
        XCTAssertEqual(body["max_len"] as? Int, body["max_new_tokens"] as? Int)
        XCTAssertEqual(body["num_beams"] as? Int, 3)
        XCTAssertEqual(
            JapaneseConversionRequestBuilder.requestTimeout(for: "ta-gettonoitinomojishokuwoakanisitekudasai"),
            18.0,
            accuracy: 0.0001
        )
    }

    func testSelfConversionKeyInterpreterMapsAsciiKeys() {
        XCTAssertEqual(SelfConversionKeyInterpreter.asciiCharacter(for: kVK_ANSI_K, shift: false), "k")
        XCTAssertEqual(SelfConversionKeyInterpreter.asciiCharacter(for: kVK_ANSI_K, shift: true), "K")
        XCTAssertEqual(SelfConversionKeyInterpreter.asciiCharacter(for: kVK_ANSI_1, shift: false), "1")
        XCTAssertEqual(SelfConversionKeyInterpreter.asciiCharacter(for: kVK_ANSI_1, shift: true), "!")
        XCTAssertEqual(SelfConversionKeyInterpreter.asciiCharacter(for: kVK_Space, shift: false), " ")
    }

    func testSelfConversionKeyInterpreterRecognizesPartialCommitKey() {
        XCTAssertTrue(SelfConversionKeyInterpreter.isPartialCommitKey(for: kVK_Tab))
        XCTAssertFalse(SelfConversionKeyInterpreter.isPartialCommitKey(for: kVK_Return))
    }

    func testSelfConversionCandidateBuilderUsesCommittedContext() {
        let withoutContext = SelfConversionCandidateBuilder.fallbackCandidates(for: "osietekudasai")
        let withContext = SelfConversionCandidateBuilder.fallbackCandidates(
            for: "osietekudasai",
            context: "天気について"
        )

        XCTAssertTrue(withoutContext.contains(JapaneseConversionCandidate(text: "教えてください", score: 0.56)))
        XCTAssertEqual(withContext.first, JapaneseConversionCandidate(text: "教えてください", score: 0.82))
    }

    func testSelfConversionStartsOnlyFromKanaKey() {
        XCTAssertTrue(SelfConversionKeyInterpreter.startsConversion(for: kVK_JIS_Kana))
        XCTAssertFalse(SelfConversionKeyInterpreter.startsConversion(for: kVK_JIS_Eisu))
        XCTAssertFalse(SelfConversionKeyInterpreter.startsConversion(for: kVK_ANSI_I))
    }

    func testSelfConversionToggleShortcutUsesConfigurableKeyWithControl() {
        KeyMapping.resetDefaults()
        defer { KeyMapping.resetDefaults() }

        XCTAssertTrue(SelfConversionKeyInterpreter.isSelfConversionToggleShortcut(
            for: kVK_JIS_Kana,
            flags: InputHook.Flags(ctrl: true)
        ))
        XCTAssertFalse(SelfConversionKeyInterpreter.isSelfConversionToggleShortcut(
            for: kVK_JIS_Kana,
            flags: InputHook.Flags()
        ))
        XCTAssertFalse(SelfConversionKeyInterpreter.isSelfConversionToggleShortcut(
            for: kVK_JIS_Kana,
            flags: InputHook.Flags(ctrl: true, shift: true)
        ))

        KeyMapping.setKeyCode(kVK_ANSI_B, for: .selfConversionToggle)

        XCTAssertTrue(SelfConversionKeyInterpreter.isSelfConversionToggleShortcut(
            for: kVK_ANSI_B,
            flags: InputHook.Flags(ctrl: true)
        ))
        XCTAssertFalse(SelfConversionKeyInterpreter.isSelfConversionToggleShortcut(
            for: kVK_JIS_Kana,
            flags: InputHook.Flags(ctrl: true)
        ))
    }

    func testSelfConversionPassesThroughCommandShortcuts() {
        XCTAssertTrue(SelfConversionKeyInterpreter.shouldPassThroughActiveConversion(InputHook.Flags(shift: true, cmd: true)))
        XCTAssertTrue(SelfConversionKeyInterpreter.shouldPassThroughActiveConversion(InputHook.Flags(cmd: true)))
        XCTAssertFalse(SelfConversionKeyInterpreter.shouldPassThroughActiveConversion(InputHook.Flags(ctrl: true)))
        XCTAssertFalse(SelfConversionKeyInterpreter.shouldPassThroughActiveConversion(InputHook.Flags()))
    }

    func testSelfConversionIgnoresOnlyTheReleaseOfTheStartKey() {
        var filter = SelfConversionStartKeyReleaseFilter()

        filter.rememberStartKey(kVK_JIS_Eisu)

        XCTAssertFalse(filter.shouldIgnoreRelease(for: kVK_JIS_Kana))
        XCTAssertTrue(filter.shouldIgnoreRelease(for: kVK_JIS_Eisu))
        XCTAssertFalse(filter.shouldIgnoreRelease(for: kVK_JIS_Eisu))
    }

    func testRomajiKanaConverterBuildsLocalFallbackText() {
        XCTAssertEqual(RomajiKanaConverter.hiragana("korehahenkanmodedesu"), "これはへんかんもでです")
        XCTAssertEqual(RomajiKanaConverter.hiragana("kitte"), "きって")
        XCTAssertEqual(RomajiKanaConverter.hiragana("nihon"), "にほん")
        XCTAssertEqual(RomajiKanaConverter.hiragana("tesutodesu."), "てすとです。")
    }

    func testSelfConversionCandidateBuilderParsesAndSortsJsonCandidates() {
        let candidates = SelfConversionCandidateBuilder.parseCandidates(from: """
        {"candidates":[{"text":"これは変換モードです","score":0.91},{"text":"これは変換です","score":0.62}]}
        """)

        XCTAssertEqual(candidates.map(\.text), ["これは変換モードです", "これは変換です"])
        XCTAssertEqual(candidates[0].score, 0.91, accuracy: 0.0001)
        XCTAssertEqual(candidates[1].score, 0.62, accuracy: 0.0001)
    }

    func testSelfConversionCandidateBuilderParsesJsonArrayCandidates() {
        let candidates = SelfConversionCandidateBuilder.parseCandidates(from: """
        [{"text":"第一候補","score":0.4},{"output":"第二候補","score":"0.8"}]
        """)

        XCTAssertEqual(candidates, [
            JapaneseConversionCandidate(text: "第二候補", score: 0.8),
            JapaneseConversionCandidate(text: "第一候補", score: 0.4),
        ])
    }

    func testSelfConversionCandidateBuilderParsesFencedJsonArrayCandidates() {
        let candidates = SelfConversionCandidateBuilder.parseCandidates(from: """
        ```json
        [{"text":"第一候補","score":0.4},{"output":"第二候補","score":"0.8"}]
        ```
        """)

        XCTAssertEqual(candidates, [
            JapaneseConversionCandidate(text: "第二候補", score: 0.8),
            JapaneseConversionCandidate(text: "第一候補", score: 0.4),
        ])
    }

    func testSelfConversionCandidateBuilderParsesFirstValidJsonWhenTrailingTextContainsBraces() {
        let candidates = SelfConversionCandidateBuilder.parseCandidates(from: """
        {"candidates":[{"text":"第一候補","score":0.8}]}
        note: {not json}
        """)

        XCTAssertEqual(candidates, [JapaneseConversionCandidate(text: "第一候補", score: 0.8)])
    }

    func testSelfConversionCandidateBuilderParsesDirectVmcResponses() {
        let candidates = SelfConversionCandidateBuilder.parseCandidates(
            from: [
                "ok": true,
                "output": "UIを改善してください",
                "score": 0.82,
            ],
            input: "uiwokaizensitekudasai"
        )

        XCTAssertEqual(candidates, [JapaneseConversionCandidate(text: "UIを改善してください", score: 0.82)])
    }

    func testSelfConversionCandidateBuilderParsesOpenAIChoicesResponse() {
        let candidates = SelfConversionCandidateBuilder.parseCandidates(
            from: [
                "choices": [
                    [
                        "message": [
                            "content": "{\"candidates\":[{\"text\":\"UIを改善してください\",\"score\":0.61}]}",
                        ],
                    ],
                    [
                        "text": "別候補です",
                        "score": 0.5,
                    ],
                ],
            ],
            input: "uiwokaizensitekudasai"
        )

        XCTAssertEqual(candidates, [
            JapaneseConversionCandidate(text: "UIを改善してください", score: 0.61),
        ])
    }

    func testSelfConversionCandidateBuilderParsesPlainTextResponse() {
        let candidates = SelfConversionCandidateBuilder.parseCandidates(
            from: "食い物を食べる",
            input: "kuimonowotaberu"
        )

        XCTAssertEqual(candidates, [JapaneseConversionCandidate(text: "食い物を食べる", score: 0.7)])
    }

    func testSelfConversionCandidateBuilderRejectsUnsafePlainTextResponse() {
        let multiline = SelfConversionCandidateBuilder.parseCandidates(
            from: "候補1\n候補2",
            input: "kouho"
        )
        let uppercase = SelfConversionCandidateBuilder.parseCandidates(
            from: "しにんしにくUI状態",
            input: "sininnsinikuijoutai"
        )
        let romajiResidue = SelfConversionCandidateBuilder.parseCandidates(
            from: "hitotusikanaku,miatarimasenndesita",
            input: "hitotusikanaku,miatarimasenndesita"
        )
        let promptEcho = SelfConversionCandidateBuilder.parseCandidates(
            from: "Input: kuimonowotaberu",
            input: "kuimonowotaberu"
        )

        XCTAssertTrue(multiline.isEmpty)
        XCTAssertTrue(uppercase.isEmpty)
        XCTAssertTrue(romajiResidue.isEmpty)
        XCTAssertTrue(promptEcho.isEmpty)
    }

    func testSelfConversionCandidateBuilderPrefersVmcCandidateScoresOverTopLevelOutput() {
        let candidates = SelfConversionCandidateBuilder.parseCandidates(
            from: [
                "ok": true,
                "output": "fallback扱いの出力",
                "score": 1.0,
                "candidates": [
                    ["text": "UIを改善してください", "score": 0.73, "avg_logprob": -0.31],
                ],
            ],
            input: "uiwokaizensitekudasai"
        )

        XCTAssertEqual(candidates, [JapaneseConversionCandidate(text: "UIを改善してください", score: 0.73)])
    }

    func testSelfConversionCandidateBuilderParsesFlexibleVmcCandidateShapes() {
        let candidates = SelfConversionCandidateBuilder.parseCandidates(
            from: [
                "ok": true,
                "candidates": [
                    ["output": "変換候補です", "score": "0.64"],
                    ["candidate": "別候補です", "score": 2.0],
                ],
            ],
            input: "hennkankouhodesu"
        )

        XCTAssertEqual(candidates, [
            JapaneseConversionCandidate(text: "別候補です", score: 1.0),
            JapaneseConversionCandidate(text: "変換候補です", score: 0.64),
        ])
    }

    func testSelfConversionCandidateBuilderMergeKeepsBestDuplicateScore() {
        let candidates = SelfConversionCandidateBuilder.merge(
            parsed: [
                JapaneseConversionCandidate(text: "これは変換モードです", score: 0.1),
                JapaneseConversionCandidate(text: "別候補", score: 0.3),
            ],
            fallback: [
                JapaneseConversionCandidate(text: "これは変換モードです", score: 0.62),
            ]
        )

        XCTAssertEqual(candidates.first, JapaneseConversionCandidate(text: "これは変換モードです", score: 0.62))
        XCTAssertEqual(candidates.map(\.text), ["これは変換モードです", "別候補"])
    }

    func testSelfConversionCandidateBuilderStripsEchoedContextFromServerCandidate() {
        let candidates = SelfConversionCandidateBuilder.merge(
            parsed: [
                JapaneseConversionCandidate(text: "北海道ですね北海道はでっかい道", score: 1.0),
            ],
            fallback: [
                JapaneseConversionCandidate(text: "ほっかいどうはでっかいどう", score: 0.2),
            ],
            context: "北海道ですね"
        )

        XCTAssertEqual(candidates.first, JapaneseConversionCandidate(text: "北海道はでっかい道", score: 1.0))
        XCTAssertEqual(candidates.map(\.text), ["北海道はでっかい道", "ほっかいどうはでっかいどう"])
    }

    func testSelfConversionCandidateBuilderRejectsUnexpectedUppercaseLatinFromLowercaseRomaji() {
        let candidates = SelfConversionCandidateBuilder.parseCandidates(from: """
        {"candidates":[{"text":"視認しにくい状態","score":0.45},{"text":"しにんしにくUI状態","score":0.9},{"text":"Temperature を見ました","score":0.8}]}
        """, input: "sininnsinikuijoutai")

        XCTAssertEqual(candidates.map(\.text), ["視認しにくい状態"])
    }

    func testSelfConversionCandidateBuilderRejectsLowQualityJsonCandidates() {
        let candidates = SelfConversionCandidateBuilder.parseCandidates(from: """
        {"candidates":[{"text":"hitotusikanaku,miatarimasenndesita","score":0.9},{"text":"Input: kuimonowokurau","score":0.8},{"text":"くいものをくらう","score":0.4}]}
        """, input: "kuimonowokurau")

        XCTAssertEqual(candidates.map(\.text), ["くいものをくらう"])
    }

    func testSelfConversionCandidateBuilderRejectsReplacementCharacterCandidates() {
        let candidates = SelfConversionCandidateBuilder.parseCandidates(
            from: [
                "ok": true,
                "output": "�します。といよいよ。といよ。と",
                "raw_output": "�します。といよいよ。といよ。と",
                "candidates": [
                    ["text": "�します。といよいよ。といよ。と", "score": 1.0],
                ],
            ],
            input: "toiiyo"
        )

        XCTAssertTrue(candidates.isEmpty)
    }

    func testSelfConversionCandidateBuilderRejectsUngroundedDomainCandidates() {
        let candidates = SelfConversionCandidateBuilder.parseCandidates(from: """
        {"candidates":[{"text":"収集系に異常がないか確認してください","score":1.0},{"text":"今日は天気がいいです","score":0.7}]}
        """, input: "kyouhatennkigaiidesu")

        XCTAssertEqual(candidates.map(\.text), ["今日は天気がいいです"])
    }

    func testSelfConversionCandidateBuilderDoesNotAllowAccidentalUiFromRomajiFragment() {
        let candidates = SelfConversionCandidateBuilder.parseCandidates(from: """
        {"candidates":[{"text":"UI","score":0.9},{"text":"くいものをくらう","score":0.4}]}
        """, input: "kuimonowokurau")

        XCTAssertEqual(candidates.map(\.text), ["くいものをくらう"])
    }

    func testSelfConversionCandidateBuilderAllowsExplicitUppercaseLatinInput() {
        let candidates = SelfConversionCandidateBuilder.parseCandidates(from: """
        {"candidates":[{"text":"UIを確認してください","score":0.9}]}
        """, input: "UIwokakuninsitekudasai")

        XCTAssertEqual(candidates.map(\.text), ["UIを確認してください"])
    }

    func testSelfConversionCandidateBuilderAllowsProtectedLatinTermsFromVmc() {
        let uiCandidates = SelfConversionCandidateBuilder.parseCandidates(from: """
        {"candidates":[{"text":"UIを改善してください","score":1.0}]}
        """, input: "uiwokaizensitekudasai")
        XCTAssertEqual(uiCandidates.map(\.text), ["UIを改善してください"])

        let appStoreConnectCandidates = SelfConversionCandidateBuilder.parseCandidates(from: """
        {"candidates":[{"text":"App Store Connect","score":1.0}]}
        """, input: "appstoreconnect")
        XCTAssertEqual(appStoreConnectCandidates.map(\.text), ["App Store Connect"])

        let searchConsoleCandidates = SelfConversionCandidateBuilder.parseCandidates(from: """
        {"candidates":[{"text":"Search Consoleを再申請してください","score":1.0}]}
        """, input: "searchconsolewosaisinseisitekudasai")
        XCTAssertEqual(searchConsoleCandidates.map(\.text), ["Search Consoleを再申請してください"])
    }

    func testSelfConversionCandidateBuilderRejectsUngroundedTrailingPunctuation() {
        let addedPeriod = SelfConversionCandidateBuilder.parseCandidates(from: """
        {"candidates":[{"text":"こんにちは。","score":1.0}]}
        """, input: "konnichiha")
        XCTAssertEqual(addedPeriod, [])

        let matchingPeriod = SelfConversionCandidateBuilder.parseCandidates(from: """
        {"candidates":[{"text":"こんにちは。","score":1.0}]}
        """, input: "konnichiha.")
        XCTAssertEqual(matchingPeriod, [
            JapaneseConversionCandidate(text: "こんにちは。", score: 1.0)
        ])

        let mismatchedPunctuation = SelfConversionCandidateBuilder.parseCandidates(from: """
        {"candidates":[{"text":"こんにちは！","score":1.0}]}
        """, input: "konnichiha.")
        XCTAssertEqual(mismatchedPunctuation, [])
    }

    func testSelfConversionCandidateBuilderRejectsContextDriftForStandalonePleaseDo() {
        let candidates = SelfConversionCandidateBuilder.parseCandidates(from: """
        {"candidates":[
          {"text":"確認していますだししましします","score":1.0},
          {"text":"してください","score":0.8}
        ]}
        """, input: "sitekudasai")

        XCTAssertEqual(candidates, [
            JapaneseConversionCandidate(text: "してください", score: 0.8),
        ])
    }

    func testSelfConversionCandidateBuilderRejectsCandidatesStartingWithContextFragments() {
        let parsed = [
            JapaneseConversionCandidate(text: "下のようにて内容を整いされており", score: 1.0),
            JapaneseConversionCandidate(text: "下のようにて内容を整整されており", score: 0.99),
            JapaneseConversionCandidate(text: "同じ内容のニュースが生成されており", score: 0.86),
        ]

        let candidates = SelfConversionCandidateBuilder.merge(
            parsed: parsed,
            fallback: [],
            context: "補助探について以下のように",
            requiredText: "onajinaiyounonyu-sugaseiseisareteori"
        )

        XCTAssertFalse(candidates.map(\.text).contains("下のようにて内容を整いされており"))
        XCTAssertFalse(candidates.map(\.text).contains("下のようにて内容を整整されており"))
        XCTAssertEqual(candidates.first?.text, "同じ内容のニュースが生成されており")
        XCTAssertTrue(candidates.map(\.text).contains("onajinaiyounonyu-sugaseiseisareteori"))
    }

    func testSelfConversionCandidateBuilderKeepsLongTargetColorCandidates() {
        let candidates = SelfConversionCandidateBuilder.parseCandidates(from: [
            "ok": true,
            "output": "Targetの位置の文字色を赤にしてください",
            "candidates": [
                ["text": "Targetの位置の文字色を赤にしてください", "score": 1.0],
                ["text": "targetの位置の文字色を赤にしてください", "score": 0.998],
                ["text": "ターゲットの位置の文字色を赤にしてください", "score": 0.997],
            ],
        ], input: "ta-gettonoitinomojishokuwoakanisitekudasai")

        XCTAssertFalse(candidates.contains { $0.text == "Targetの位置の文字色を赤にしてください" })
        XCTAssertTrue(candidates.contains { $0.text == "targetの位置の文字色を赤にしてください" })
        XCTAssertTrue(candidates.contains { $0.text == "ターゲットの位置の文字色を赤にしてください" })
    }

    func testSelfConversionCandidateBuilderKeepsRawInputCandidatePastDefaultLimit() {
        let parsed = (0..<5).map { index in
            JapaneseConversionCandidate(text: "候補\(index)", score: 0.95 - Double(index) * 0.01)
        }
        let raw = JapaneseConversionCandidate(text: "rawinput", score: 0.05)
        let candidates = SelfConversionCandidateBuilder.merge(
            parsed: parsed,
            fallback: [],
            requiredText: raw.text
        )

        XCTAssertEqual(candidates.count, 6)
        XCTAssertEqual(candidates.last, raw)
    }

    func testSelfConversionCandidateBuilderExpandsWhenHighScoreCandidatesRemain() {
        let parsed = (0..<7).map { index in
            JapaneseConversionCandidate(text: "候補\(index)", score: 0.95 - Double(index) * 0.01)
        }

        let candidates = SelfConversionCandidateBuilder.merge(parsed: parsed, fallback: [])

        XCTAssertEqual(candidates.count, 7)
        XCTAssertEqual(candidates.last?.text, "候補6")
        XCTAssertEqual(candidates.last?.score ?? 0, 0.89, accuracy: 0.0001)
    }

    func testSelfConversionCandidateBuilderAddsSemanticFallbackForNoisyRomaji() {
        let candidates = SelfConversionCandidateBuilder.fallbackCandidates(for: "korehahenkanmodedesu")

        XCTAssertEqual(candidates.first?.text, "これは変換モードです")
        XCTAssertTrue(candidates.contains(JapaneseConversionCandidate(text: "これはへんかんもでです", score: 0.2)))
    }

    func testSelfConversionCandidateBuilderAddsOperationalFallbacks() {
        let confirm = SelfConversionCandidateBuilder.fallbackCandidates(for: "kakuninsitekudasai")
        let improve = SelfConversionCandidateBuilder.fallbackCandidates(for: "kaizensitekudasai")
        let execute = SelfConversionCandidateBuilder.fallbackCandidates(for: "jikkousitekudasai")
        let add = SelfConversionCandidateBuilder.fallbackCandidates(for: "tuikasitekudasai")

        XCTAssertTrue(confirm.map(\.text).contains("確認してください"))
        XCTAssertTrue(improve.map(\.text).contains("改善してください"))
        XCTAssertTrue(execute.map(\.text).contains("実行してください"))
        XCTAssertTrue(add.map(\.text).contains("追加してください"))
    }

    func testSelfConversionCandidateBuilderAddsLightweightPhraseFallbacks() {
        let test = SelfConversionCandidateBuilder.fallbackCandidates(for: "tesutodesu.")
        XCTAssertEqual(test.first, JapaneseConversionCandidate(text: "テストです。", score: 0.56))
        XCTAssertTrue(test.contains(JapaneseConversionCandidate(text: "てすとです。", score: 0.2)))

        let greetingWithoutPunctuation = SelfConversionCandidateBuilder.fallbackCandidates(for: "konnichiha")
        XCTAssertEqual(greetingWithoutPunctuation.first, JapaneseConversionCandidate(text: "こんにちは", score: 0.56))
        XCTAssertFalse(greetingWithoutPunctuation.map(\.text).contains("こんにちは。"))

        let greetingWithPunctuation = SelfConversionCandidateBuilder.fallbackCandidates(for: "konnichiha.")
        XCTAssertEqual(greetingWithPunctuation.first, JapaneseConversionCandidate(text: "こんにちは。", score: 0.56))

        let animation = SelfConversionCandidateBuilder.fallbackCandidates(for: "anime-shon")
        XCTAssertEqual(animation.first, JapaneseConversionCandidate(text: "アニメーション", score: 0.56))

        let weather = SelfConversionCandidateBuilder.fallbackCandidates(for: "kyouhatennkigaiidesu")
        XCTAssertEqual(weather.first, JapaneseConversionCandidate(text: "今日は天気がいいです", score: 0.56))
    }

    func testJapaneseConversionRequestBuilderIncludesContext() {
        let body = JapaneseConversionRequestBuilder.requestBody(
            for: "sininnsinikuijoutai",
            context: "背景が白系の場合、"
        )

        XCTAssertEqual(body["input"] as? String, "sininnsinikuijoutai")
        XCTAssertEqual(body["context"] as? String, "背景が白系の場合、")
        XCTAssertEqual(body["max_len"] as? Int, 16)
        XCTAssertEqual(body["max_new_tokens"] as? Int, 16)
        XCTAssertEqual(body["num_beams"] as? Int, 5)
        XCTAssertNil(body["options"])
        XCTAssertNil(body["prompt"])
    }

    func testSelfConversionWindowCenteredOriginUsesVisibleScreenCenter() {
        let origin = SelfConversionWindowController.centeredOrigin(
            windowSize: NSSize(width: 420, height: 180),
            visibleFrame: NSRect(x: 100, y: 50, width: 1200, height: 800)
        )

        XCTAssertEqual(origin.x, 490, accuracy: 0.0001)
        XCTAssertEqual(origin.y, 360, accuracy: 0.0001)
    }

    func testSelfConversionWindowOutsideMouseDownUsesSmallWindowInset() {
        let frame = NSRect(x: 100, y: 100, width: 240, height: 120)

        XCTAssertFalse(SelfConversionWindowController.shouldCancelForMouseDown(
            at: NSPoint(x: 97, y: 160),
            windowFrame: frame
        ))
        XCTAssertTrue(SelfConversionWindowController.shouldCancelForMouseDown(
            at: NSPoint(x: 95, y: 160),
            windowFrame: frame
        ))
    }

    func testSelfConversionWindowResizeCanKeepTopEdgeFixed() {
        let current = NSRect(x: 120, y: 200, width: 420, height: 180)
        let resized = SelfConversionWindowController.frameResizedKeepingTop(
            currentFrame: current,
            targetSize: NSSize(width: 520, height: 260),
            visibleFrame: NSRect(x: 0, y: 0, width: 1200, height: 900)
        )

        XCTAssertEqual(resized.maxY, current.maxY, accuracy: 0.0001)
        XCTAssertEqual(resized.minY, 120, accuracy: 0.0001)
        XCTAssertEqual(resized.minX, 340, accuracy: 0.0001)
    }

    func testSelfConversionWindowKeepsSupportedLongInputTogether() {
        let input = "nagaibunshounohennkanndematubigatogirerukyodougamadaarimasita"
        let split = SelfConversionWindowController.initialSessionSplit(for: input)

        XCTAssertEqual(split.current, input)
        XCTAssertEqual(split.next, "")
        let atLimit = String(repeating: "a", count: 256)
        XCTAssertEqual(SelfConversionWindowController.initialSessionSplit(for: atLimit).current, atLimit)
        XCTAssertEqual(SelfConversionWindowController.initialSessionSplit(for: atLimit).next, "")
    }

    func testSelfConversionWindowSplitsOnlyAtAPIInputLimitWithoutLosingText() {
        let input = String(repeating: "koreha", count: 60)
        let split = SelfConversionWindowController.initialSessionSplit(
            for: input
        )

        XCTAssertLessThanOrEqual(split.current.unicodeScalars.count, 256)
        XCTAssertGreaterThan(split.current.count, 250)
        XCTAssertFalse(split.next.isEmpty)
        XCTAssertEqual(split.current + split.next, input)
    }

    func testSelfConversionWindowInputLimitCountsUnicodeScalarsNotGraphemes() {
        let input = String(repeating: "か\u{3099}", count: 200)
        let split = SelfConversionWindowController.initialSessionSplit(for: input)

        XCTAssertEqual(split.current.unicodeScalars.count, 256)
        XCTAssertEqual(split.current.count, 128)
        XCTAssertEqual(split.current + split.next, input)
    }

    func testSelfConversionLoadingWaveUsesFixedPointPeriod() {
        let period = SelfConversionWindowController.loadingWavePeriod
        let phase: CGFloat = 11
        let x: CGFloat = 18

        XCTAssertEqual(
            SelfConversionWindowController.loadingWaveWhiteValue(atX: x, phase: phase),
            SelfConversionWindowController.loadingWaveWhiteValue(atX: x + period, phase: phase),
            accuracy: 0.0001
        )
        XCTAssertEqual(
            SelfConversionWindowController.loadingWaveWhiteValue(atX: x, phase: phase),
            SelfConversionWindowController.loadingWaveWhiteValue(atX: x + period * 4, phase: phase),
            accuracy: 0.0001
        )

        let bright = SelfConversionWindowController.loadingWaveWhiteValue(atX: 0, phase: 0)
        let dark = SelfConversionWindowController.loadingWaveWhiteValue(atX: period / 2, phase: 0)
        XCTAssertGreaterThan(bright - dark, 0.7)
    }

    func testSelfConversionDecisionEventRecordsSelectedAndUnselectedCandidates() {
        let snapshot = SelfConversionDecisionSnapshot(
            input: "sitekudasai",
            context: "確認しています",
            committedText: "確認しています",
            composedText: "確認していますしてください",
            selectedIndex: 1,
            selectedCandidate: JapaneseConversionCandidate(text: "してください", score: 0.8),
            candidates: [
                JapaneseConversionCandidate(text: "確認していますだししましします", score: 1.0),
                JapaneseConversionCandidate(text: "してください", score: 0.8),
                JapaneseConversionCandidate(text: "sitekudasai", score: 0.05),
            ]
        )
        let body = SelfConversionDecisionEvent(
            action: "partial_commit",
            snapshot: snapshot,
            committedOutput: "してください"
        ).requestBody()

        XCTAssertTrue(JSONSerialization.isValidJSONObject(body))
        XCTAssertEqual(body["action"] as? String, "partial_commit")
        XCTAssertEqual(body["selected_text"] as? String, "してください")
        XCTAssertEqual(body["selected_score"] as? Double ?? 0, 0.8, accuracy: 0.0001)
        XCTAssertEqual(body["committed_output"] as? String, "してください")
        XCTAssertEqual((body["candidates"] as? [[String: Any]])?.count, 3)
        let unselected = body["unselected_candidates"] as? [[String: Any]]
        XCTAssertEqual(unselected?.count, 2)
        XCTAssertEqual(unselected?.first?["text"] as? String, "確認していますだししましします")
        XCTAssertEqual(unselected?.first?["score"] as? Double ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertEqual(unselected?.last?["text"] as? String, "sitekudasai")
        XCTAssertEqual(unselected?.last?["score"] as? Double ?? 0, 0.05, accuracy: 0.0001)
    }

    @MainActor
    func testSelfConversionWindowPartialCommitStaysInConversionWindow() {
        SelfConversionSettings.resetDefaults()
        defer { SelfConversionSettings.resetDefaults() }
        let controller = SelfConversionWindowController(client: JapaneseConversionServingStub())
        defer { controller.cancel() }

        controller.begin()
        controller.append("tesutodesu.")
        controller.forceStartCurrentConversion()
        XCTAssertEqual(controller.selectedText(), "テストです。")

        controller.commitCurrentCandidateForContinuation()
        XCTAssertEqual(controller.composedText(), "テストです。")

        controller.append("osietekudasai")
        controller.forceStartCurrentConversion()
        XCTAssertEqual(controller.selectedText(), "教えてください")
        XCTAssertEqual(controller.composedText(), "テストです。教えてください")
    }

    @MainActor
    func testSelfConversionWindowMultiplePartialCommitsComposeFinalText() {
        SelfConversionSettings.resetDefaults()
        defer { SelfConversionSettings.resetDefaults() }
        let controller = SelfConversionWindowController(client: JapaneseConversionServingStub())
        defer { controller.cancel() }

        controller.begin()
        controller.append("tesutodesu.")
        controller.forceStartCurrentConversion()
        controller.commitCurrentCandidateForContinuation()

        controller.append("osietekudasai")
        controller.forceStartCurrentConversion()
        controller.commitCurrentCandidateForContinuation()
        XCTAssertEqual(controller.composedText(), "テストです。教えてください")

        controller.append("yoroshiku")
        controller.forceStartCurrentConversion()
        XCTAssertEqual(controller.composedText(), "テストです。教えてくださいよろしくお願いします")
    }

    @MainActor
    func testSelfConversionWindowDebouncesConversionForTwoSeconds() {
        SelfConversionSettings.resetDefaults()
        defer { SelfConversionSettings.resetDefaults() }
        let client = JapaneseConversionServingStub()
        let controller = SelfConversionWindowController(client: client)
        defer { controller.cancel() }

        controller.begin()
        controller.append("kore")
        runMainLoop(for: 1.5)

        XCTAssertEqual(client.requests.map(\.input), [])

        runMainLoop(for: 0.7)

        XCTAssertEqual(client.requests.map(\.input), ["kore"])
    }

    @MainActor
    func testSelfConversionWindowExpandsForLongCandidateText() {
        SelfConversionSettings.resetDefaults()
        defer { SelfConversionSettings.resetDefaults() }
        let client = JapaneseConversionServingStub()
        let controller = SelfConversionWindowController(client: client)
        defer { controller.cancel() }

        controller.begin()
        let initialWidth = controller.window?.frame.width ?? 0
        controller.append("nagaihenkankouhowohyouzishimasu")
        controller.forceStartCurrentConversion()
        client.complete(
            at: 0,
            candidates: [
                JapaneseConversionCandidate(
                    text: "これはかなり長い変換候補を省略せずに表示するための確認文です",
                    score: 1.0
                ),
            ]
        )
        runMainLoop(for: 0.2)

        XCTAssertGreaterThan(controller.window?.frame.width ?? 0, initialWidth + 40)
    }

    @MainActor
    func testSelfConversionWindowForceStartsCurrentConversion() {
        SelfConversionSettings.resetDefaults()
        defer { SelfConversionSettings.resetDefaults() }
        let client = JapaneseConversionServingStub()
        let controller = SelfConversionWindowController(client: client)
        defer { controller.cancel() }

        controller.begin()
        controller.append("kore")
        controller.forceStartCurrentConversion()

        XCTAssertEqual(client.requests.map(\.input), ["kore"])
    }

    @MainActor
    func testSelfConversionTypingImmediatelyAfterAnimationStartsStaysInCurrentRange() {
        SelfConversionSettings.resetDefaults()
        defer { SelfConversionSettings.resetDefaults() }
        let client = JapaneseConversionServingStub()
        let controller = SelfConversionWindowController(client: client)
        defer { controller.cancel() }

        controller.begin()
        controller.append("kore")
        controller.forceStartCurrentConversion()

        controller.append("ha")
        runMainLoop(for: 1.2)

        XCTAssertEqual(client.requests.map(\.input), ["kore"])
        XCTAssertEqual(controller.decisionSnapshot().input, "koreha")
        XCTAssertFalse(controller.hasNextSessionInput)

        client.complete(
            at: 0,
            candidates: [JapaneseConversionCandidate(text: "これ", score: 1.0)]
        )
        runMainLoop(for: 0.3)

        XCTAssertEqual(client.requests.map(\.input), ["kore"])
        XCTAssertFalse(controller.decisionSnapshot().candidates.contains { $0.text == "これ" })
        runMainLoop(for: 0.8)
        XCTAssertEqual(client.requests.map(\.input), ["kore", "koreha"])
        client.complete(at: 1, candidates: [JapaneseConversionCandidate(text: "これは", score: 1)])
        runMainLoop(for: 0.1)
        XCTAssertEqual(controller.confirmAndClose().composedText, "これは")
    }

    @MainActor
    func testSelfConversionWindowEditsCompletedSessionInputAndReconverts() {
        SelfConversionSettings.resetDefaults()
        defer { SelfConversionSettings.resetDefaults() }
        let client = JapaneseConversionServingStub()
        let controller = SelfConversionWindowController(client: client)
        defer { controller.cancel() }

        controller.begin()
        controller.append("kore")
        controller.forceStartCurrentConversion()
        client.complete(
            at: 0,
            candidates: [JapaneseConversionCandidate(text: "これ", score: 1.0)]
        )
        runMainLoop(for: 0.3)

        controller.backspace()
        controller.append("ha")
        runMainLoop(for: 2.2)

        XCTAssertEqual(client.requests.map(\.input), ["kore", "korha"])
    }

    @MainActor
    func testSelfConversionWindowCanForceReconvertsCompletedSession() {
        SelfConversionSettings.resetDefaults()
        defer { SelfConversionSettings.resetDefaults() }
        let client = JapaneseConversionServingStub()
        let controller = SelfConversionWindowController(client: client)
        defer { controller.cancel() }

        controller.begin()
        controller.append("shuuseiwojisshisitekudasai")
        controller.forceStartCurrentConversion()
        client.complete(at: 0, candidates: [])
        runMainLoop(for: 0.3)

        controller.forceStartCurrentConversion()

        XCTAssertEqual(client.requests.map(\.input), [
            "shuuseiwojisshisitekudasai",
            "shuuseiwojisshisitekudasai",
        ])
    }

    @MainActor
    func testSelfConversionWindowMovesInputBoundaryLeftWithDebounce() {
        SelfConversionSettings.resetDefaults()
        defer { SelfConversionSettings.resetDefaults() }
        let client = JapaneseConversionServingStub()
        let controller = SelfConversionWindowController(client: client)
        defer { controller.cancel() }

        controller.begin()
        controller.append("abcdef")
        controller.forceStartCurrentConversion()
        client.complete(at: 0, candidates: [JapaneseConversionCandidate(text: "abcdef", score: 1.0)])
        runMainLoop(for: 0.3)

        controller.moveLastInputCharacterToNextSession()
        controller.moveLastInputCharacterToNextSession()
        runMainLoop(for: 1.5)

        XCTAssertEqual(client.requests.map(\.input), ["abcdef"])
        XCTAssertTrue(controller.hasNextSessionInput)

        runMainLoop(for: 0.8)

        XCTAssertEqual(client.requests.map(\.input), ["abcdef", "abcd"])
    }

    @MainActor
    func testSelfConversionWindowMovesInputBoundaryRightAndForceStarts() {
        SelfConversionSettings.resetDefaults()
        defer { SelfConversionSettings.resetDefaults() }
        let client = JapaneseConversionServingStub()
        let controller = SelfConversionWindowController(client: client)
        defer { controller.cancel() }

        controller.begin()
        controller.append("abcdef")
        controller.forceStartCurrentConversion()
        client.complete(at: 0, candidates: [JapaneseConversionCandidate(text: "abcdef", score: 1.0)])
        runMainLoop(for: 0.3)

        controller.moveLastInputCharacterToNextSession()
        controller.moveLastInputCharacterToNextSession()
        controller.moveFirstNextSessionCharacterToInput()
        controller.forceStartCurrentConversion()

        XCTAssertEqual(client.requests.map(\.input), ["abcdef", "abcde"])
        XCTAssertTrue(controller.hasNextSessionInput)
    }

    @MainActor
    func testSelfConversionWindowConvertsReportedLongInputInOneRequest() {
        SelfConversionSettings.resetDefaults()
        defer { SelfConversionSettings.resetDefaults() }
        let client = JapaneseConversionServingStub()
        let controller = SelfConversionWindowController(client: client)
        defer { controller.cancel() }

        controller.begin()
        let input = "choubunnohenkangahairutotochuudekiretesimaufugaiagaruyoudesu"
        controller.append(input)
        controller.forceStartCurrentConversion()

        XCTAssertEqual(client.requests.map(\.input), [input])
        XCTAssertFalse(controller.hasNextSessionInput)
    }

    @MainActor
    func testSelfConversionEditedSessionRetainsOverflowAtAPIInputLimit() {
        let client = JapaneseConversionServingStub()
        let controller = SelfConversionWindowController(client: client)
        defer { controller.cancel() }
        let input = String(repeating: "a", count: 256)
        controller.begin()
        controller.append(input)
        controller.forceStartCurrentConversion()
        client.complete(at: 0, candidates: [JapaneseConversionCandidate(text: "先頭", score: 1)])
        runMainLoop(for: 0.1)
        controller.append("ha")
        controller.forceStartCurrentConversion()

        XCTAssertEqual(client.requests.map(\.input), [input, input])
        XCTAssertTrue(controller.hasNextSessionInput)
        controller.commitCurrentCandidateForContinuation()
        XCTAssertEqual(client.requests.last?.input, "ha")
        XCTAssertTrue(client.requests.allSatisfy { $0.input.unicodeScalars.count <= 256 })
    }

    @MainActor
    func testSelfConversionBoundaryMoveRetainsOverflowAtAPIInputLimit() {
        let client = JapaneseConversionServingStub()
        let controller = SelfConversionWindowController(client: client)
        defer { controller.cancel() }
        let input = String(repeating: "a", count: 256)
        controller.begin()
        controller.append(input)
        controller.forceStartCurrentConversion()
        placeSuffixInNextRange(controller, "ha")
        client.complete(at: 0, candidates: [JapaneseConversionCandidate(text: "先頭", score: 1)])
        runMainLoop(for: 0.1)
        controller.moveFirstNextSessionCharacterToInput()
        controller.forceStartCurrentConversion()

        XCTAssertEqual(client.requests.map(\.input), [input, input])
        XCTAssertTrue(controller.hasNextSessionInput)
        controller.commitCurrentCandidateForContinuation()
        XCTAssertEqual(client.requests.last?.input, "ha")
        XCTAssertTrue(client.requests.allSatisfy { $0.input.unicodeScalars.count <= 256 })
    }

    @MainActor
    func testSelfConversionEnterBeforeCandidatesConfirmsRawInput() {
        let client = JapaneseConversionServingStub()
        let controller = SelfConversionWindowController(client: client)
        defer { controller.cancel() }
        controller.begin()
        controller.append("ViMouse")

        XCTAssertNil(controller.decisionSnapshot().selectedCandidate)
        XCTAssertEqual(controller.selectedText(), "ViMouse")
        let final = controller.confirmAndClose()
        XCTAssertEqual(final.composedText, "ViMouse")
        XCTAssertTrue(client.requests.isEmpty)
        XCTAssertFalse(controller.isActive)
        runMainLoop(for: 2.1)
        XCTAssertTrue(client.requests.isEmpty)
    }

    @MainActor
    func testSelfConversionTabBeforeCandidatesConfirmsRawInputForContinuation() {
        let client = JapaneseConversionServingStub()
        let controller = SelfConversionWindowController(client: client)
        defer { controller.cancel() }
        controller.begin()
        controller.append("ViMouse")

        let partial = controller.commitCurrentCandidateForContinuation()
        XCTAssertEqual(partial.selectedCandidate?.text ?? partial.input, "ViMouse")

        XCTAssertEqual(controller.composedText(), "ViMouse")
        XCTAssertTrue(controller.isActive)
        XCTAssertTrue(client.requests.isEmpty)
        let final = controller.confirmAndClose()
        XCTAssertEqual(final.composedText, "ViMouse")
    }

    @MainActor
    func testSelfConversionEnterConfirmsTheSelectedDisplayedCandidate() {
        let client = JapaneseConversionServingStub()
        let controller = SelfConversionWindowController(client: client)
        defer { controller.cancel() }
        controller.begin()
        controller.append("vimouse")
        controller.forceStartCurrentConversion()
        client.complete(at: 0, candidates: [
            JapaneseConversionCandidate(text: "ゔぃもうせ", score: 1),
            JapaneseConversionCandidate(text: "ViMouse", score: 0.9),
        ])
        runMainLoop(for: 0.1)
        XCTAssertFalse(controller.decisionSnapshot().explicitSelection)
        controller.selectNext()
        XCTAssertEqual(controller.selectedText(), "ViMouse")

        let final = controller.confirmAndClose()
        XCTAssertEqual(final.selectedCandidate?.text, "ViMouse")
        XCTAssertEqual(final.composedText, "ViMouse")
        XCTAssertTrue(final.explicitSelection)
    }

    @MainActor
    func testPersonalLearningSelectionIsResetForNewConversionResponse() {
        let client = JapaneseConversionServingStub()
        let controller = SelfConversionWindowController(client: client)
        defer { controller.cancel() }
        controller.begin()
        controller.append("kouho")
        controller.forceStartCurrentConversion()
        let native = [JapaneseConversionCandidate(text: "広報", score: 0.999, isNative: true),
                      JapaneseConversionCandidate(text: "候補", score: 0.998, isNative: true)]
        client.complete(at: 0, candidates: native)
        runMainLoop(for: 0.1)
        controller.selectNext()
        XCTAssertTrue(controller.decisionSnapshot().explicitSelection)
        controller.forceStartCurrentConversion()
        XCTAssertFalse(controller.decisionSnapshot().explicitSelection)
        controller.selectNext() // Selection freezes even a provisional list.
        let frozen = controller.decisionSnapshot().candidates
        client.complete(at: 1, candidates: native)
        runMainLoop(for: 0.1)
        XCTAssertTrue(controller.decisionSnapshot().explicitSelection)
        XCTAssertEqual(controller.decisionSnapshot().candidates, frozen)
        controller.forceStartCurrentConversion()
        XCTAssertFalse(controller.decisionSnapshot().explicitSelection)
        client.complete(at: 2, candidates: native)
        runMainLoop(for: 0.1)
        XCTAssertEqual(controller.decisionSnapshot().candidates, native)
    }

    @MainActor
    func testSelfConversionRawConfirmIsNotAKeywordSpecificWorkaround() {
        let controller = SelfConversionWindowController(client: JapaneseConversionServingStub())
        defer { controller.cancel() }
        for input in ["nihongo", "GitHub", "ViMouse", "日本語", "API_v2"] {
            controller.begin()
            controller.append(input)
            XCTAssertEqual(controller.selectedText(), input)
            XCTAssertEqual(controller.decisionSnapshot().composedText, input)
        }
    }

    @MainActor
    func testSettingsWindowClosesWithoutModalLoop() {
        let controller = SettingsWindowController()
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        XCTAssertNotNil(controller.window)
    }

    @MainActor
    func testMouseModeTimerFiresWhileRunLoopIsInEventTrackingMode() {
        var didFire = false
        let probe = TimerProbe {
            didFire = true
        }
        let timer = MouseModeScheduler.scheduleTimer(
            timeInterval: 0.01,
            target: probe,
            selector: #selector(TimerProbe.fire)
        )
        defer { timer.invalidate() }

        let deadline = Date().addingTimeInterval(0.3)
        while !didFire && Date() < deadline {
            RunLoop.current.run(mode: .eventTracking, before: Date().addingTimeInterval(0.03))
        }

        XCTAssertTrue(didFire)
    }
}

private func runMainLoop(for interval: TimeInterval) {
    RunLoop.current.run(until: Date().addingTimeInterval(interval))
}

private final class JapaneseConversionServingStub: JapaneseConversionServing {
    struct Request {
        let input: String
        let context: String
        let completion: ([JapaneseConversionCandidate]) -> Void
    }

    private(set) var requests: [Request] = []

    func convert(
        _ input: String,
        context: String,
        callbackQueue: DispatchQueue,
        completion: @escaping ([JapaneseConversionCandidate]) -> Void
    ) {
        requests.append(Request(input: input, context: context) { candidates in
            callbackQueue.async {
                completion(candidates)
            }
        })
    }

    func complete(at index: Int, candidates: [JapaneseConversionCandidate]) {
        requests[index].completion(candidates)
    }
}

private final class InputHookDelegateStub: InputHookDelegate {
    struct Call {
        let keycode: Int64
        let pressed: Bool
    }

    private var results: [Bool]
    private(set) var calls: [Call] = []
    private(set) var repeatCalls: [Call] = []

    init(results: [Bool]) {
        self.results = results
    }

    func handleInput(_ keycode: Int64, _ flags: InputHook.Flags, _ pressed: Bool) -> Bool {
        calls.append(Call(keycode: keycode, pressed: pressed))
        return results.removeFirst()
    }

    func handleRepeatedInput(_ keycode: Int64, _ flags: InputHook.Flags) -> Bool {
        repeatCalls.append(Call(keycode: keycode, pressed: true))
        return true
    }
}

private final class TimerProbe: NSObject {
    private let onFire: () -> Void

    init(onFire: @escaping () -> Void) {
        self.onFire = onFire
    }

    @objc func fire() {
        onFire()
    }
}
