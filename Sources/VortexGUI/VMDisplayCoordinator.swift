// VMDisplayCoordinator.swift -- Single-window coordination for VM displays.
// VortexGUI

import AppKit
import SwiftUI

final class VMDisplayCoordinator {
    private var windowsByVMID: [UUID: WeakWindow] = [:]

    @MainActor
    func openDisplay(for vmID: UUID, openWindow: OpenWindowAction) {
        if focusDisplay(for: vmID) {
            return
        }
        openWindow(value: vmID)
    }

    @MainActor
    @discardableResult
    func registerWindow(_ window: NSWindow, for vmID: UUID) -> Bool {
        if let existing = liveWindow(for: vmID), existing !== window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            closeDuplicateWindow(window)
            return false
        }

        window.identifier = Self.windowIdentifier(for: vmID)
        windowsByVMID[vmID] = WeakWindow(window)
        return true
    }

    @MainActor
    func unregisterWindow(_ window: NSWindow, for vmID: UUID) {
        guard windowsByVMID[vmID]?.window === window else {
            return
        }
        windowsByVMID.removeValue(forKey: vmID)
    }

    @MainActor
    @discardableResult
    func focusDisplay(for vmID: UUID) -> Bool {
        guard let window = liveWindow(for: vmID) else {
            return false
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    @MainActor
    private func closeDuplicateWindow(_ window: NSWindow) {
        window.orderOut(nil)
        window.close()
    }

    @MainActor
    private func liveWindow(for vmID: UUID) -> NSWindow? {
        if let window = windowsByVMID[vmID]?.window {
            return window
        }

        let identifier = Self.windowIdentifier(for: vmID)
        if let restored = NSApp.windows.first(where: { $0.identifier == identifier }) {
            windowsByVMID[vmID] = WeakWindow(restored)
            return restored
        }

        windowsByVMID.removeValue(forKey: vmID)
        return nil
    }

    private static func windowIdentifier(for vmID: UUID) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("com.vortex.display.\(vmID.uuidString)")
    }
}

private final class WeakWindow {
    weak var window: NSWindow?

    init(_ window: NSWindow) {
        self.window = window
    }
}

private struct VMDisplayCoordinatorKey: EnvironmentKey {
    static let defaultValue = VMDisplayCoordinator()
}

extension EnvironmentValues {
    var vmDisplayCoordinator: VMDisplayCoordinator {
        get { self[VMDisplayCoordinatorKey.self] }
        set { self[VMDisplayCoordinatorKey.self] = newValue }
    }
}

struct WindowAccessor: NSViewRepresentable {
    var onResolve: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                onResolve(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                onResolve(window)
            }
        }
    }
}
