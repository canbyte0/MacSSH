import Foundation
import XCTest
@testable import MacSSH

final class TerminalSuggestionFoundationTests: XCTestCase {
    private let eligible = SuggestionEligibility(
        trustedShellEditing: true,
        editableSnapshotValid: true,
        observedPrefixMatchesSnapshot: true,
        terminalRenderedStateValid: true,
        cursorAtEditableEnd: true,
        rightSideClear: true,
        terminalFocused: true,
        alternateScreen: false,
        imeMarkedText: false,
        settingsEnabled: true,
        historyEnabled: true
    )

    private func request(
        session: UUID = UUID(),
        kind: SuggestionTerminalKind = .local,
        target: UInt64 = 1,
        prompt: UInt64 = 1,
        snapshot: UInt64 = 1,
        prefix: String = "git",
        revision: UInt64 = 1
    ) -> SuggestionRequest {
        SuggestionRequest(
            logicalSessionID: session,
            terminalKind: kind,
            targetGeneration: target,
            promptGeneration: prompt,
            snapshotSequence: snapshot,
            typedPrefix: prefix,
            inputRevision: revision
        )
    }

    func testPendingLoadingShowingAndNoAutomaticTransportAction() throws {
        var machine = TerminalSuggestionStateMachine()
        let current = request()
        let binding = try XCTUnwrap(machine.begin(current, eligibility: eligible))
        XCTAssertEqual(machine.state, .pending(binding))
        machine.loading(binding)
        XCTAssertEqual(machine.state, .loading(binding))
        let candidate = try XCTUnwrap(SuggestionCandidate.make(command: "git status", prefix: "git"))
        machine.receive(candidate, for: binding)
        XCTAssertEqual(machine.state, .showing(binding, candidate))
        XCTAssertEqual(machine.suffixIfCurrent(binding, currentRequest: current, eligibility: eligible), " status")
        // 纯域对象没有 PTY/SSH 句柄；响应只改变状态，不会发出 CR。
        XCTAssertFalse(candidate.suffix.contains("\r"))
    }

    func testDismissAndProviderFailureCannotRestoreLateCandidate() throws {
        var machine = TerminalSuggestionStateMachine()
        let first = try XCTUnwrap(machine.begin(request(), eligibility: eligible))
        machine.dismiss()
        machine.receive(SuggestionCandidate.make(command: "git status", prefix: "git"), for: first)
        XCTAssertEqual(machine.state, .dismissed)
        let second = try XCTUnwrap(machine.begin(request(), eligibility: eligible))
        machine.loading(second)
        machine.providerFailed(for: second)
        machine.receive(SuggestionCandidate.make(command: "git status", prefix: "git"), for: second)
        XCTAssertEqual(machine.state, .idle)
    }

    func testAllInvalidationEventsDiscardShowingCandidate() throws {
        let events: [(String, (inout TerminalSuggestionStateMachine) -> Void)] = [
            ("prefix", { $0.prefixChanged() }),
            ("edit", { $0.backspaceOrEdit() }),
            ("enter", { $0.executed() }),
            ("focus", { $0.focusLost() }),
            ("switch", { $0.sessionSwitched() }),
            ("close", { $0.sessionClosed() }),
            ("reconnect", { $0.remoteReconnected() }),
            ("settings", { $0.settingsDisabled() }),
            ("agent", { $0.agentTerminalMutated() }),
        ]
        for (label, event) in events {
            var machine = TerminalSuggestionStateMachine()
            let current = request()
            let binding = try XCTUnwrap(machine.begin(current, eligibility: eligible))
            machine.receive(SuggestionCandidate.make(command: "git status", prefix: "git"), for: binding)
            event(&machine)
            XCTAssertEqual(machine.state, .stale, label)
            XCTAssertNil(machine.suffixIfCurrent(binding, currentRequest: current, eligibility: eligible), label)
            machine.receive(SuggestionCandidate.make(command: "git status", prefix: "git"), for: binding)
            XCTAssertEqual(machine.state, .stale, label)
        }
    }

    func testWrongSessionTargetPrefixRevisionAndProviderGenerationRejected() throws {
        let session = UUID()
        let original = request(session: session)
        var machine = TerminalSuggestionStateMachine()
        let binding = try XCTUnwrap(machine.begin(original, eligibility: eligible))
        let candidate = SuggestionCandidate.make(command: "git status", prefix: "git")
        let wrong: [SuggestionBinding] = [
            SuggestionBinding(request: request(session: UUID()), providerGeneration: binding.providerGeneration),
            SuggestionBinding(request: request(session: session, target: 2), providerGeneration: binding.providerGeneration),
            SuggestionBinding(request: request(session: session, prompt: 2), providerGeneration: binding.providerGeneration),
            SuggestionBinding(request: request(session: session, snapshot: 2), providerGeneration: binding.providerGeneration),
            SuggestionBinding(request: request(session: session, prefix: "gi"), providerGeneration: binding.providerGeneration),
            SuggestionBinding(request: request(session: session, revision: 2), providerGeneration: binding.providerGeneration),
            SuggestionBinding(request: original, providerGeneration: SuggestionGeneration(value: binding.providerGeneration.value + 1)),
        ]
        for stale in wrong {
            machine.receive(candidate, for: stale)
            XCTAssertEqual(machine.state, .pending(binding))
        }
        machine.receive(candidate, for: binding)
        for stale in wrong {
            XCTAssertNil(machine.suffixIfCurrent(stale, currentRequest: original, eligibility: eligible))
            if stale.request != original {
                XCTAssertNil(machine.suffixIfCurrent(binding, currentRequest: stale.request, eligibility: eligible))
            }
        }
        let ime = SuggestionEligibility(
            trustedShellEditing: true, editableSnapshotValid: true,
            observedPrefixMatchesSnapshot: true, terminalRenderedStateValid: true,
            cursorAtEditableEnd: true, rightSideClear: true, terminalFocused: true,
            alternateScreen: false, imeMarkedText: true, settingsEnabled: true,
            historyEnabled: true
        )
        XCTAssertNil(machine.suffixIfCurrent(binding, currentRequest: original, eligibility: ime))
    }

    func testEligibilityVetoesAlternateScreenIMEUnfocusedAndUnknownShell() {
        let cases = [
            SuggestionEligibility(trustedShellEditing: false, editableSnapshotValid: true,
                observedPrefixMatchesSnapshot: true, terminalRenderedStateValid: true,
                cursorAtEditableEnd: true, rightSideClear: true, terminalFocused: true,
                alternateScreen: false, imeMarkedText: false, settingsEnabled: true, historyEnabled: true),
            SuggestionEligibility(trustedShellEditing: true, editableSnapshotValid: false,
                observedPrefixMatchesSnapshot: true, terminalRenderedStateValid: true,
                cursorAtEditableEnd: true, rightSideClear: true, terminalFocused: true,
                alternateScreen: false, imeMarkedText: false, settingsEnabled: true, historyEnabled: true),
            SuggestionEligibility(trustedShellEditing: true, editableSnapshotValid: true,
                observedPrefixMatchesSnapshot: true, terminalRenderedStateValid: true,
                cursorAtEditableEnd: true, rightSideClear: true, terminalFocused: false,
                alternateScreen: false, imeMarkedText: false, settingsEnabled: true, historyEnabled: true),
            SuggestionEligibility(trustedShellEditing: true, editableSnapshotValid: true,
                observedPrefixMatchesSnapshot: true, terminalRenderedStateValid: true,
                cursorAtEditableEnd: true, rightSideClear: true, terminalFocused: true,
                alternateScreen: true, imeMarkedText: false, settingsEnabled: true, historyEnabled: true),
            SuggestionEligibility(trustedShellEditing: true, editableSnapshotValid: true,
                observedPrefixMatchesSnapshot: true, terminalRenderedStateValid: true,
                cursorAtEditableEnd: true, rightSideClear: true, terminalFocused: true,
                alternateScreen: false, imeMarkedText: false, settingsEnabled: false, historyEnabled: true),
        ]
        for veto in cases {
            var machine = TerminalSuggestionStateMachine()
            XCTAssertNil(machine.begin(request(), eligibility: veto))
            XCTAssertEqual(machine.state, .stale)
        }
    }

    func testHistoryUsesLatestEligibleLocalExactPrefixAndFiltersControls() {
        let records = [
            SuggestionHistoryRecord(command: "git\nstatus", sessionKind: "local", hostDisplayName: nil),
            SuggestionHistoryRecord(command: "git remote", sessionKind: "remoteSSH", hostDisplayName: "web"),
            SuggestionHistoryRecord(command: "git status", sessionKind: "local", hostDisplayName: nil),
            SuggestionHistoryRecord(command: "git log", sessionKind: "local", hostDisplayName: nil),
        ]
        let match = HistorySuggestionProvider.match(request: request(), historyEnabled: true, records: records)
        XCTAssertEqual(match?.command, "git status")
        XCTAssertNil(HistorySuggestionProvider.match(request: request(), historyEnabled: false, records: records))
        XCTAssertNil(HistorySuggestionProvider.match(request: request(kind: .remote), historyEnabled: true, records: records))
        XCTAssertNil(HistorySuggestionProvider.match(request: request(prefix: "unknown"), historyEnabled: true, records: records))
    }

    func testHistoryRejectsEqualPrefixCRNULAndOtherControls() {
        for command in ["git", "git\rstatus", "git\0status", "git\u{1b}status", "git\u{7f}status"] {
            XCTAssertNil(SuggestionCandidate.make(command: command, prefix: "git"))
        }
        XCTAssertNil(SuggestionCandidate.make(command: "git status", prefix: ""))
    }

    func testCandidateSuffixRespectsWholeGraphemesAndExactUTF8() {
        let cases: [(String, String, String)] = [
            ("git status", "git", " status"),
            ("中文 文件", "中文", " 文件"),
            ("🙂 done", "🙂", " done"),
            ("e\u{301}cho ok", "e\u{301}", "cho ok"),
            ("⚠️ done", "⚠️", " done"),
        ]
        for (command, prefix, suffix) in cases {
            XCTAssertEqual(SuggestionCandidate.make(command: command, prefix: prefix)?.suffix, suffix)
        }
        XCTAssertNil(SuggestionCandidate.make(command: "⚠️ done", prefix: "⚠"))
        XCTAssertNil(SuggestionCandidate.make(command: "e\u{301}cho", prefix: "e"))
    }
}
