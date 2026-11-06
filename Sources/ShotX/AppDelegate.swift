import AppKit
import Carbon.HIToolbox
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var selection: SelectionController?
    private var editors: [EditorWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        if DebugSnapshot.runIfRequested() { return }
        setupStatusItem()
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey | shiftKey)) { [weak self] in
            self?.startCapture()
        }
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "ShotX")
        image?.isTemplate = true
        statusItem.button?.image = image

        let menu = NSMenu()
        let capture = NSMenuItem(title: "Capture Area", action: #selector(captureFromMenu), keyEquivalent: "a")
        capture.keyEquivalentModifierMask = [.command, .shift]
        capture.target = self
        menu.addItem(capture)
        menu.addItem(.separator())

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit ShotX", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc private func captureFromMenu() {
        // Let the menu finish closing before we freeze the screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.startCapture() }
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSSound.beep()
        }
        sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    /// Accessory apps have no visible menu bar, but a main menu is still needed
    /// so standard key equivalents (⌘Z, ⌘C, ⌘V, ⌘S…) route through the responder chain.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Save…", action: #selector(CanvasView.saveDocument(_:)), keyEquivalent: "s")
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        NSApp.mainMenu = main
    }

    // MARK: - Capture flow

    func startCapture() {
        guard selection == nil else { return }

        // Don't gate on CGPreflightScreenCaptureAccess(): it can report a stale "denied"
        // on recent macOS. Just try, and only ask for permission if capture actually fails.
        Task { @MainActor in
            do {
                let shots = try await ScreenGrabber.captureAllScreens()
                guard !shots.isEmpty else { return }
                self.selection = SelectionController(shots: shots) { [weak self] result in
                    guard let self else { return }
                    self.selection = nil
                    if let result { self.openEditor(result) }
                }
                self.selection?.show()
            } catch {
                CGRequestScreenCaptureAccess()
                self.showPermissionAlert()
            }
        }
    }

    private func openEditor(_ shot: CroppedShot) {
        // New screenshot replaces the current one; its annotations are discarded.
        for old in editors {
            old.onClose = nil
            old.discard()
        }
        editors.removeAll()

        let editor = EditorWindowController(shot: shot)
        editor.onClose = { [weak self, weak editor] in
            self?.editors.removeAll { $0 === editor }
        }
        editors.append(editor)
        editor.present()
    }

    private func showPermissionAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission needed"
        alert.informativeText = "Enable ShotX in System Settings → Privacy & Security → Screen & System Audio Recording, then relaunch ShotX."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
