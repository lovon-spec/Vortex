// VortexGUIApp.swift -- Polished native macOS app for VM management.
// VortexGUI
//
// Provides two window scenes:
// 1. VM Library -- NavigationSplitView showing all VMs with status LEDs
// 2. VM Display -- opens when a VM starts, shows VZVirtualMachineView
//
// Launch modes:
//   VortexGUI              -- show the VM library
//   VortexGUI <uuid>       -- go directly to VM display for that UUID
//   open .build/Vortex.app --args <uuid>  -- same, via open(1)
//
// Design: dark appearance, native Cocoa, transparent titlebar tinted dark.
// Inspired by the Intendant macOS app aesthetic.

import os
import SwiftUI
import Virtualization
import VortexAudio
import VortexCore
import VortexPersistence
import VortexVZ

// MARK: - App Entry Point

@main
struct VortexApp: App {
    @NSApplicationDelegateAdaptor(VortexAppDelegate.self) var appDelegate
    @State private var viewModel = VMLibraryViewModel()

    /// If a UUID was passed on the command line, open its display directly.
    private var launchVMID: UUID? {
        let args = ProcessInfo.processInfo.arguments
        guard args.count > 1 else { return nil }
        return UUID(uuidString: args[1])
    }

    var body: some Scene {
        // Main library window
        Window("Vortex", id: "library") {
            VMLibraryView()
                .environment(viewModel)
                .onAppear {
                    configureMainWindow()
                    // If launched with a VM UUID, open its display window.
                    if let vmID = launchVMID {
                        Task {
                            viewModel.loadConfigurations()
                            await viewModel.bootVM(id: vmID)
                        }
                    }
                }
        }
        .defaultSize(width: 900, height: 600)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New VM...") {
                    viewModel.showCreationWizard = true
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            CommandGroup(after: .sidebar) {
                Button("Refresh VM List") {
                    viewModel.refresh()
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }

        // VM display window (opened per-VM)
        WindowGroup("VM Display", for: UUID.self) { $vmID in
            if let vmID = vmID {
                VMDisplayWindow(vmID: vmID)
                    .environment(viewModel)
            } else {
                Text("Invalid VM ID")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .defaultSize(width: 1024, height: 768)

        // Settings window
        Settings {
            PreferencesView()
        }
    }

    /// Applies dark appearance and window styling after the main window appears.
    private func configureMainWindow() {
        // Ensure dark appearance on all windows.
        DispatchQueue.main.async {
            for window in NSApp.windows {
                window.appearance = NSAppearance(named: .darkAqua)
                window.titlebarAppearsTransparent = true
                window.backgroundColor = NSColor(
                    red: 28.0 / 255.0,
                    green: 28.0 / 255.0,
                    blue: 30.0 / 255.0,
                    alpha: 1.0
                )
            }
        }
    }
}

// MARK: - App Delegate

/// Handles app lifecycle events: activation, Dock presence, window behavior.
final class VortexAppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Appear in the Dock as a proper GUI app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Apply dark appearance globally.
        NSApp.appearance = NSAppearance(named: .darkAqua)

        // Center the main window at 60% of screen.
        centerMainWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Re-apply dark appearance to any new windows.
        for window in NSApp.windows {
            if window.appearance?.name != .darkAqua {
                window.appearance = NSAppearance(named: .darkAqua)
            }
        }
    }

    /// Centers the key window at approximately 60% of the screen size.
    private func centerMainWindow() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard let window = NSApp.keyWindow ?? NSApp.windows.first,
                  let screen = window.screen ?? NSScreen.main else {
                return
            }

            let screenFrame = screen.visibleFrame
            let width = min(900.0, screenFrame.width * 0.60)
            let height = min(600.0, screenFrame.height * 0.60)
            let x = screenFrame.origin.x + (screenFrame.width - width) / 2.0
            let y = screenFrame.origin.y + (screenFrame.height - height) / 2.0

            window.setFrame(
                NSRect(x: x, y: y, width: width, height: height),
                display: true,
                animate: false
            )

            window.titlebarAppearsTransparent = true
            window.backgroundColor = NSColor(
                red: 28.0 / 255.0,
                green: 28.0 / 255.0,
                blue: 30.0 / 255.0,
                alpha: 1.0
            )
        }
    }
}
