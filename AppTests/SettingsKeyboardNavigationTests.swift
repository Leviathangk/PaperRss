import AppKit
import XCTest
@testable import PaperRssDesktop

@MainActor
final class SettingsKeyboardNavigationTests: XCTestCase {
    private func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func arrow(in window: NSWindow, flags: NSEvent.ModifierFlags = [.numericPad, .function]) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: window.windowNumber, context: nil, characters: "\u{f701}",
                         charactersIgnoringModifiers: "\u{f701}", isARepeat: false, keyCode: 125)!
    }

    func testArrowsAllowHardwareFlagsButRespectInactiveAndOtherWindows() {
        let owner = window(), other = window()
        defer { owner.close(); other.close() }
        let key = arrow(in: owner)
        XCTAssertTrue(SettingsKeyboardNavigation.NavigationView.shouldHandle(key, in: owner, isActive: true))
        XCTAssertFalse(SettingsKeyboardNavigation.NavigationView.shouldHandle(key, in: owner, isActive: false))
        XCTAssertFalse(SettingsKeyboardNavigation.NavigationView.shouldHandle(arrow(in: other), in: owner, isActive: true))
        for flag: NSEvent.ModifierFlags in [.command, .control, .option, .shift] {
            XCTAssertFalse(SettingsKeyboardNavigation.NavigationView.shouldHandle(arrow(in: owner, flags: flag), in: owner, isActive: true))
        }
    }

    func testTextEditorKeepsArrowsForCursorMovement() {
        let owner = window()
        defer { owner.close() }
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        owner.contentView?.addSubview(editor)
        XCTAssertTrue(owner.makeFirstResponder(editor))
        XCTAssertFalse(SettingsKeyboardNavigation.NavigationView.shouldHandle(arrow(in: owner), in: owner, isActive: true))
    }

    func testClosingSettingsRestoresReaderResponderAndToolbar() {
        let owner = window()
        defer { owner.close() }
        let actions = ToolbarActions(onRefresh: {}, onAddFeed: {}, onAddFolder: {}, onImport: {}, onExport: {},
            isRefreshing: false, selectionTitle: "Fixture", hasUnread: false, onMarkAllRead: {})
        let coordinator = ThreeColumnSplitViewCoordinator(actions: actions, appearance: .default,
            appearanceMode: .light, appTheme: .system, columnFocusState: PaperColumnFocusState())
        let split = NSSplitViewController()
        let controller = NSViewController()
        let reader = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        controller.view = reader
        split.addSplitViewItem(NSSplitViewItem(viewController: controller))
        owner.contentViewController = split
        coordinator.splitViewController = split
        let toolbar = NSToolbar(identifier: "SettingsReturnFixture")
        owner.toolbar = toolbar
        XCTAssertTrue(owner.makeFirstResponder(reader))
        coordinator.setReaderActive(false)
        XCTAssertTrue(split.view.isHidden, "隐藏的原生阅读器必须退出键盘焦点循环")
        XCTAssertFalse(owner.firstResponder === reader)
        coordinator.setReaderActive(true)
        XCTAssertFalse(split.view.isHidden)
        XCTAssertTrue(owner.firstResponder === reader)
        XCTAssertTrue(owner.toolbar === toolbar)
    }

    func testActivationRunsOnceAndCanBeCancelledBeforeFocusChanges() async {
        let navigation = SettingsKeyboardNavigation.NavigationView()
        var activations = 0
        navigation.onActivate = { activations += 1 }
        navigation.setActive(true)
        await Task.yield()
        XCTAssertEqual(activations, 1)
        navigation.setActive(true)
        navigation.setActive(false)
        await Task.yield()
        XCTAssertEqual(activations, 1)
        navigation.setActive(true)
        navigation.setActive(false)
        await Task.yield()
        XCTAssertEqual(activations, 1)
        navigation.stop()
    }
}
