import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let store = UsageStore()
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        popover.behavior = .transient
        popover.delegate = self
        popover.animates = false
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = NSHostingController(rootView: UsageView(store: store))

        store.onUpdate = { [weak self] in
            self?.updateStatusIcon()
            // Let SwiftUI apply content changes before sizing and anchoring.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.popover.isShown else { return }
                self.sizePopover()
                self.anchorPopover()
            }
        }
        updateStatusIcon()
        store.refreshAll()

        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.store.refreshAll()
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            store.refreshAll(opening: true)
            // Finish status-item layout before AppKit resolves the anchor.
            DispatchQueue.main.async { [weak self, button] in
                guard let self, !self.popover.isShown else { return }
                button.layoutSubtreeIfNeeded()
                self.sizePopover()
                self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                self.popover.contentViewController?.view.window?.makeKey()
            }
        }
    }

    private func sizePopover() {
        guard let view = popover.contentViewController?.view else { return }
        view.layoutSubtreeIfNeeded()
        popover.contentSize = view.fittingSize
    }

    func popoverDidShow(_ notification: Notification) {
        anchorPopover()
    }

    private func anchorPopover() {
        guard let button = statusItem.button,
              let statusWindow = button.window,
              let popupWindow = popover.contentViewController?.view.window else { return }
        // Use screen coordinates from the actual status-item window, so this
        // also works on secondary displays. Preserve AppKit's horizontal
        // placement and arrow offset near the edges of a screen.
        let buttonFrame = statusWindow.convertToScreen(button.convert(button.bounds, to: nil))
        popupWindow.setFrameOrigin(NSPoint(x: popupWindow.frame.minX,
                                          y: buttonFrame.minY - popupWindow.frame.height))
    }

    private func updateStatusIcon() {
        // One glyph per service has to answer "how much have I got left", so it
        // tracks whichever window is closest to running out. Neither service
        // reliably has both: Codex's overall bucket reports only a weekly
        // window, and a window a plan doesn't have reads as absent, not full.
        func tightest(_ u: ServiceUsage) -> Double? {
            [u.session, u.weekly].compactMap { $0?.remaining }.min()
        }
        statusItem.button?.image = StatusRenderer.image(
            claude: tightest(store.claude),
            codex: tightest(store.codex)
        )
    }
}

// Terminal diagnostic: only usage figures and errors are printed, never credentials.
if CommandLine.arguments.contains("--check-claude") {
    let count = CommandLine.arguments.contains("--repeat") ? 2 : 1
    for index in 0..<count {
        if index > 0 { Thread.sleep(forTimeInterval: 60) }
        let history = ClaudeDesktopUsageHistory.read()
        let usage = ClaudeWebReader.read(organizationID: history?.organizationID,
            allowKeychainPrompt: CommandLine.arguments.contains("--allow-keychain-prompt"))
        if let error = usage.error { print("Claude check failed: \(error)"); exit(1) }
        print("Claude live check \(index + 1): 5h used \(usage.session?.percent.description ?? "n/a")%, weekly used \(usage.weekly?.percent.description ?? "n/a")%; reset times received: \(usage.session?.resetsAt != nil && usage.weekly?.resetsAt != nil)")
        fflush(stdout)
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
