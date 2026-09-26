import AppKit
import Foundation
import SwiftTerm

/// 仅保存本会话当前一行的瞬态输入；任一无法证明的编辑都锁定至下一次 prompt。
@MainActor
final class TerminalEditableInputTracker {
    private(set) var promptGeneration: UInt64?
    private(set) var inputRevision: UInt64 = 0
    private(set) var observedPrefix = ""
    private(set) var snapshot: ZLEEditSnapshot?
    private var snapshotUptime: TimeInterval?
    private(set) var invalidated = true

    func promptReady(_ generation: UInt64) {
        guard generation > (promptGeneration ?? 0) else { invalidate(); return }
        promptGeneration = generation
        observedPrefix = ""
        snapshot = nil
        snapshotUptime = nil
        invalidated = false
        inputRevision &+= 1
    }

    func observeInsertText(_ text: String) {
        guard !invalidated, !text.isEmpty,
              !text.unicodeScalars.contains(where: { $0.value < 0x20 || (0x7f...0x9f).contains($0.value) }),
              observedPrefix.utf8.count + text.utf8.count <= ZLEEditSnapshotCodec.maxFieldBytes
        else { invalidate(); return }
        observedPrefix += text
        snapshot = nil
        snapshotUptime = nil
        inputRevision &+= 1
    }

    func accept(_ newSnapshot: ZLEEditSnapshot) {
        guard !invalidated,
              newSnapshot.promptGeneration == promptGeneration,
              snapshot == nil || newSnapshot.sequence > snapshot!.sequence,
              newSnapshot.buffer.utf8.elementsEqual(observedPrefix.utf8),
              newSnapshot.leftBuffer.utf8.elementsEqual(newSnapshot.buffer.utf8),
              newSnapshot.rightBuffer.isEmpty,
              newSnapshot.postDisplay.isEmpty,
              !newSnapshot.buffer.contains("\n"), !newSnapshot.buffer.contains("\r")
        else { invalidate(); return }
        snapshot = newSnapshot
        snapshotUptime = ProcessInfo.processInfo.systemUptime
    }

    func invalidate() {
        invalidated = true
        observedPrefix = ""
        snapshot = nil
        snapshotUptime = nil
        inputRevision &+= 1
    }

    var snapshotMatches: Bool {
        guard !invalidated, snapshot != nil, let snapshotUptime else { return false }
        let age = ProcessInfo.processInfo.systemUptime - snapshotUptime
        return age >= 0 && age <= 5
    }
}

/// SwiftTerm 的当前屏幕只支持可证明的单行 ASCII 尾部编辑几何。
enum TerminalRenderedInputValidator {
    static func validate(terminal: Terminal, prefix: String) -> Bool {
        guard !terminal.isCurrentBufferAlternate,
              !prefix.isEmpty,
              prefix.utf8.allSatisfy({ (0x20...0x7e).contains($0) }),
              terminal.buffer.y >= 0, terminal.buffer.y < terminal.rows,
              terminal.buffer.x >= prefix.utf8.count,
              terminal.buffer.x < terminal.cols,
              let line = terminal.getLine(row: terminal.buffer.y), !line.isWrapped,
              line.count >= terminal.cols
        else { return false }
        let start = terminal.buffer.x - prefix.utf8.count
        for (offset, byte) in prefix.utf8.enumerated() {
            guard terminal.getCharacter(for: line[start + offset]) == Character(UnicodeScalar(byte)) else {
                return false
            }
        }
        for column in terminal.buffer.x..<terminal.cols {
            let cell = terminal.getCharacter(for: line[column])
            guard cell == " " || cell == "\0" else { return false }
        }
        if terminal.buffer.y + 1 < terminal.rows,
           terminal.getLine(row: terminal.buffer.y + 1)?.isWrapped == true { return false }
        return true
    }
}

enum TerminalEditableKeyDecision {
    static func invalidates(keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
                            charactersIgnoringModifiers: String?) -> Bool {
        if [48, 51, 53, 36, 76, 117, 123, 124, 125, 126, 115, 119].contains(keyCode) {
            return true
        }
        return modifiers.contains(.control)
            && ["a", "e", "u", "k", "w"].contains(charactersIgnoringModifiers?.lowercased() ?? "")
    }
}

enum TerminalEditableEventDecision: Equatable {
    case passThrough
    case invalidateAndPassThrough

    static func routeKey(localSession: Bool, sameWindow: Bool, exactResponder: Bool,
                         keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
                         charactersIgnoringModifiers: String?) -> Self {
        guard localSession, sameWindow, exactResponder else { return .passThrough }
        return TerminalEditableKeyDecision.invalidates(
            keyCode: keyCode, modifiers: modifiers,
            charactersIgnoringModifiers: charactersIgnoringModifiers)
            ? .invalidateAndPassThrough : .passThrough
    }
}

/// SessionManager 独占一个被动监听器；永远返回原 NSEvent，不消费任何按键。
@MainActor
final class TerminalEditableInputEventMonitor {
    private let activeService: @MainActor () -> LocalTerminalService?
    private var token: Any?
    private var observers: [NSObjectProtocol] = []

    init(activeService: @escaping @MainActor () -> LocalTerminalService?) {
        self.activeService = activeService
    }

    func install() {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let service = self.activeService() else { return event }
            guard let window = event.window, window === NSApp.keyWindow,
                  service.terminalView.window === window else { return event }
            if event.type == .keyDown {
                if TerminalEditableEventDecision.routeKey(
                    localSession: true, sameWindow: true,
                    exactResponder: window.firstResponder === service.terminalView,
                    keyCode: event.keyCode, modifiers: event.modifierFlags,
                    charactersIgnoringModifiers: event.charactersIgnoringModifiers)
                    == .invalidateAndPassThrough {
                    service.invalidateEditableInput()
                }
            } else if let contentView = window.contentView,
                      let hit = contentView.hitTest(event.locationInWindow),
                      hit !== service.terminalView,
                      !hit.isDescendant(of: service.terminalView) {
                service.invalidateEditableInput()
            }
            return event
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.activeService()?.invalidateEditableInput() }
        })
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.activeService()?.invalidateEditableInput() }
        })
    }

    isolated deinit {
        if let token { NSEvent.removeMonitor(token) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}
