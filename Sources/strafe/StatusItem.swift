import AppKit

/// The menu-bar controller. Owns the `NSStatusItem` and wires its menu to the
/// interceptor / permission state. LSUIElement is set in the bundled
/// Info.plist so there is no dock icon.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let interceptor: SwipeInterceptor
    private let engine: GestureSwitchEngine
    private var transitionSpeedItems: [TransitionSpeedPreset: NSMenuItem] = [:]

    private let toggleItem = NSMenuItem(
        title: "Enable", action: #selector(toggleEnabled), keyEquivalent: ""
    )
    private let accessibilityItem = NSMenuItem(
        title: "Accessibility granted: —", action: nil, keyEquivalent: ""
    )

    init(interceptor: SwipeInterceptor, engine: GestureSwitchEngine) {
        self.interceptor = interceptor
        self.engine = engine
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "rectangle.on.rectangle",
                accessibilityDescription: "strafe"
            )
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.delegate = self

        toggleItem.target = self
        accessibilityItem.isEnabled = false

        let transitionSpeedMenu = NSMenu()
        for preset in TransitionSpeedPreset.allCases {
            let item = NSMenuItem(
                title: preset.title,
                action: #selector(selectTransitionSpeed(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = preset.rawValue
            transitionSpeedMenu.addItem(item)
            transitionSpeedItems[preset] = item
        }
        let transitionSpeedItem = NSMenuItem(
            title: "Transition Speed",
            action: nil,
            keyEquivalent: ""
        )
        transitionSpeedItem.submenu = transitionSpeedMenu

        menu.addItem(toggleItem)
        menu.addItem(transitionSpeedItem)
        menu.addItem(accessibilityItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit strafe", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        refresh()
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        // Toggle interception. The tap stays alive (so it can re-enable itself
        // after a system auto-disable); `overrideEnabled` gates whether real
        // swipes are actually suppressed and replaced (SPEC §2.2).
        interceptor.overrideEnabled.toggle()
        if interceptor.overrideEnabled && !interceptor.isRunning {
            interceptor.start()
        }
        refresh()
    }

    @objc private func selectTransitionSpeed(_ sender: NSMenuItem) {
        guard let preset = TransitionSpeedPreset(rawValue: sender.tag) else { return }
        engine.setTransitionSpeed(preset)
        refresh()
    }

    @objc private func quit() {
        interceptor.teardown()
        NSApp.terminate(nil)
    }

    // MARK: - State

    private func refresh() {
        toggleItem.title = interceptor.overrideEnabled ? "Disable" : "Enable"
        let selectedSpeed = engine.transitionSpeed
        for preset in TransitionSpeedPreset.allCases {
            transitionSpeedItems[preset]?.state = preset == selectedSpeed ? .on : .off
        }
        let granted = Permissions.isAccessibilityGranted
        accessibilityItem.title = "Accessibility granted: \(granted ? "yes" : "no")"
    }
}
