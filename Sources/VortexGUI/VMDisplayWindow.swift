// VMDisplayWindow.swift -- VM display window with toolbar and status bar.
// VortexGUI
//
// Opens when a VM is started. Shows VZVirtualMachineView filling the window,
// with a toolbar for power controls and audio settings, plus a status bar at
// the bottom showing VM state and audio routing info.

import AppKit
import SwiftUI
import Virtualization
import VortexCore
import VortexLinux
import VortexService

// MARK: - VMDisplayWindow

/// The VM display window, identified by VM UUID. Created by the WindowGroup scene.
struct VMDisplayWindow: View {
    let vmID: UUID
    @Environment(VMLibraryViewModel.self) private var viewModel
    @Environment(\.vmDisplayCoordinator) private var displayCoordinator
    @State private var controller: VMController?
    @State private var bootError: String?
    @State private var registeredWindow: NSWindow?
    @State private var isPrimaryDisplayWindow: Bool?

    var body: some View {
        let activeController = viewModel.controller(for: vmID) ?? controller
        Group {
            if isPrimaryDisplayWindow == false {
                Color.clear
                    .frame(width: 1, height: 1)
            } else if let controller = activeController {
                VMDisplayContent(controller: controller)
            } else if let error = bootError {
                VMBootErrorView(message: error)
            } else {
                VMBootingView()
            }
        }
        .background {
            WindowAccessor { window in
                registerWindowIfNeeded(window)
            }
        }
        .task(id: isPrimaryDisplayWindow) {
            guard isPrimaryDisplayWindow == true else { return }
            await attachController()
        }
        .onChange(of: viewModel.controller(for: vmID)?.config.identity.name) { _, name in
            if let name {
                registeredWindow?.title = name
            }
        }
        .onDisappear {
            if let registeredWindow {
                displayCoordinator.unregisterWindow(registeredWindow, for: vmID)
            }
        }
    }

    @MainActor
    private func registerWindowIfNeeded(_ window: NSWindow) {
        if let registeredWindow, registeredWindow === window {
            return
        }
        let isPrimary = displayCoordinator.registerWindow(window, for: vmID)
        isPrimaryDisplayWindow = isPrimary
        if isPrimary {
            registeredWindow = window
            if let controller {
                window.title = controller.config.identity.name
            }
        }
    }

    private func attachController() async {
        for _ in 0..<200 {
            if let existing = viewModel.controller(for: vmID) {
                self.controller = existing
                registeredWindow?.title = existing.config.identity.name
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }

        bootError = viewModel.errorMessage ?? "No VM controller is available for this display."
    }
}

// MARK: - Booting View

/// Shown while the VM is being prepared and booted.
private struct VMBootingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Starting VM...")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
    }
}

// MARK: - Boot Error View

/// Shown when the VM fails to boot.
private struct VMBootErrorView: View {
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.red)

            Text("Failed to Start VM")
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
    }
}

// MARK: - VM Display Content

/// The main display content: VZVirtualMachineView + toolbar + status bar.
private struct VMDisplayContent: View {
    @Bindable var controller: VMController

    var body: some View {
        VStack(spacing: 0) {
            if let vm = controller.vm {
                VMDisplayView(vm: vm)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let framebuffer = controller.nativeFramebuffer {
                NativeLinuxFramebufferView(framebuffer: framebuffer, controller: controller)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NativeLinuxSerialConsoleView(controller: controller)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Status bar at bottom
            VMStatusBar(controller: controller)
        }
        .navigationTitle(controller.config.identity.name)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if controller.vm != nil {
                    Button {
                        controller.showAudioSettings = true
                    } label: {
                        Label("Audio Settings", systemImage: "speaker.wave.2")
                    }
                    .help("Configure audio device routing")

                    Divider()
                }

                // Power controls
                if controller.canStart {
                    Button {
                        Task { await controller.start() }
                    } label: {
                        Label("Start", systemImage: "play.fill")
                    }
                    .help("Start VM")
                }

                if controller.isRunning {
                    Button {
                        Task { await controller.pause() }
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                    }
                    .help("Pause VM execution")
                }

                if controller.isPaused {
                    Button {
                        Task { await controller.resume() }
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                    }
                    .help("Resume VM execution")
                }

                if controller.canStop {
                    Button {
                        Task { await controller.stop() }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .help("Stop VM")
                }
            }
        }
        .sheet(isPresented: $controller.showAudioSettings) {
            AudioSettingsView(
                audioConfig: $controller.config.audio,
                onApply: {
                    controller.applyAudioSettings()
                    controller.showAudioSettings = false
                },
                onDismiss: {
                    controller.showAudioSettings = false
                }
            )
        }
    }
}

private struct NativeLinuxSerialConsoleView: View {
    @Bindable var controller: VMController

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(consoleText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .id("console-end")
            }
            .background(.black)
            .onChange(of: controller.serialConsoleText) {
                proxy.scrollTo("console-end", anchor: .bottom)
            }
        }
    }

    private var consoleText: String {
        controller.serialConsoleText.isEmpty ? "Waiting for serial output..." : controller.serialConsoleText
    }
}

private struct NativeLinuxFramebufferView: View {
    let framebuffer: NativeLinuxFramebuffer
    let controller: VMController

    var body: some View {
        NativeLinuxFramebufferHost(framebuffer: framebuffer, controller: controller)
    }
}

private struct NativeLinuxFramebufferHost: NSViewRepresentable {
    let framebuffer: NativeLinuxFramebuffer
    let controller: VMController

    func makeNSView(context: Context) -> NativeLinuxFramebufferNSView {
        let view = NativeLinuxFramebufferNSView()
        view.update(framebuffer: framebuffer, controller: controller)
        return view
    }

    func updateNSView(_ nsView: NativeLinuxFramebufferNSView, context: Context) {
        nsView.update(framebuffer: framebuffer, controller: controller)
    }
}

private final class NativeLinuxFramebufferNSView: NSView {
    private weak var controller: VMController?
    private var framebuffer: NativeLinuxFramebuffer?
    private var image: CGImage?
    private var trackingAreaRef: NSTrackingArea?
    private var modifierStates: [UInt16: Bool] = [:]
    private var pressedMacKeyCodes: [UInt16: UInt16] = [:]
    private var pressedLinuxKeys: Set<UInt16> = []
    private var observedWindow: NSWindow?
    private var inputReleaseObservers: [NSObjectProtocol] = []
    private var keyUpMonitor: Any?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    deinit {
        releaseAllKeys()
        removeInputReleaseObservers()
        removeKeyUpMonitor()
    }

    func update(framebuffer: NativeLinuxFramebuffer, controller: VMController) {
        self.controller = controller
        self.framebuffer = framebuffer
        self.image = Self.makeImage(from: framebuffer)
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        if let window {
            installInputReleaseObservers(for: window)
            installKeyUpMonitor()
        } else {
            releaseAllKeys()
            removeInputReleaseObservers()
            removeKeyUpMonitor()
        }
        claimInputFocusSoon()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window {
            releaseAllKeys()
            removeInputReleaseObservers()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidHide() {
        releaseAllKeys()
        super.viewDidHide()
    }

    override func resignFirstResponder() -> Bool {
        releaseAllKeys()
        return super.resignFirstResponder()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
        super.updateTrackingAreas()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()

        guard let image else {
            return
        }

        let rect = imageRect(for: image)
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        nsImage.draw(
            in: rect,
            from: NSRect(origin: .zero, size: nsImage.size),
            operation: .copy,
            fraction: 1.0,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.none]
        )
    }

    override func mouseEntered(with event: NSEvent) {
        claimInputFocus()
        sendPointerEvent(event)
    }

    override func mouseDown(with event: NSEvent) {
        claimInputFocus()
        sendPointerEvent(event)
    }

    override func mouseUp(with event: NSEvent) {
        sendPointerEvent(event)
    }

    override func mouseMoved(with event: NSEvent) {
        sendPointerEvent(event)
    }

    override func mouseDragged(with event: NSEvent) {
        sendPointerEvent(event)
    }

    override func rightMouseDown(with event: NSEvent) {
        claimInputFocus()
        sendPointerEvent(event)
    }

    override func rightMouseUp(with event: NSEvent) {
        sendPointerEvent(event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        sendPointerEvent(event)
    }

    override func otherMouseDown(with event: NSEvent) {
        claimInputFocus()
        sendPointerEvent(event)
    }

    override func otherMouseUp(with event: NSEvent) {
        sendPointerEvent(event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        sendPointerEvent(event)
    }

    override func keyDown(with event: NSEvent) {
        guard !event.isARepeat,
              let code = NativeLinuxKeyMap.linuxCode(forMacKeyCode: event.keyCode) else {
            return
        }
        sendKey(code: code, macKeyCode: event.keyCode, pressed: true)
    }

    override func keyUp(with event: NSEvent) {
        guard let code = NativeLinuxKeyMap.linuxCode(forMacKeyCode: event.keyCode) else {
            return
        }
        sendKey(code: code, macKeyCode: event.keyCode, pressed: false)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let code = NativeLinuxKeyMap.linuxCode(forMacKeyCode: event.keyCode) else {
            return
        }

        if event.keyCode == NativeLinuxKeyMap.capsLockMacKeyCode {
            sendKey(code: code, macKeyCode: event.keyCode, pressed: true)
            sendKey(code: code, macKeyCode: event.keyCode, pressed: false)
            return
        }

        let pressed = !(modifierStates[event.keyCode] ?? false)
        modifierStates[event.keyCode] = pressed
        sendKey(code: code, macKeyCode: event.keyCode, pressed: pressed)
    }

    private func sendPointerEvent(_ event: NSEvent) {
        guard let image,
              let point = framebufferPoint(for: event, image: image) else {
            return
        }

        let pressedButtons = NSEvent.pressedMouseButtons
        controller?.sendNativePointer(
            x: point.x,
            y: point.y,
            leftButton: (pressedButtons & (1 << 0)) != 0,
            rightButton: (pressedButtons & (1 << 1)) != 0,
            middleButton: (pressedButtons & (1 << 2)) != 0
        )
    }

    private func sendKey(code: UInt16, macKeyCode: UInt16?, pressed: Bool) {
        if pressed {
            guard pressedLinuxKeys.insert(code).inserted else {
                return
            }
            if let macKeyCode {
                pressedMacKeyCodes[macKeyCode] = code
            }
        } else {
            pressedLinuxKeys.remove(code)
            if let macKeyCode {
                pressedMacKeyCodes.removeValue(forKey: macKeyCode)
            }
        }
        controller?.sendNativeKey(code: code, pressed: pressed)
    }

    private func releaseAllKeys() {
        let codes = pressedLinuxKeys
        pressedLinuxKeys.removeAll()
        pressedMacKeyCodes.removeAll()
        modifierStates.removeAll()

        for code in codes {
            controller?.sendNativeKey(code: code, pressed: false)
        }
    }

    private func installInputReleaseObservers(for window: NSWindow) {
        guard observedWindow !== window else {
            return
        }

        removeInputReleaseObservers()
        observedWindow = window

        let center = NotificationCenter.default
        let queue = OperationQueue.main
        let names: [Notification.Name] = [
            NSWindow.didResignKeyNotification,
            NSWindow.didResignMainNotification,
            NSWindow.willCloseNotification,
            NSApplication.didResignActiveNotification,
        ]

        for name in names {
            let object: Any? = name == NSApplication.didResignActiveNotification ? NSApp : window
            let token = center.addObserver(
                forName: name,
                object: object,
                queue: queue
            ) { [weak self] _ in
                self?.releaseAllKeys()
            }
            inputReleaseObservers.append(token)
        }
    }

    private func removeInputReleaseObservers() {
        let center = NotificationCenter.default
        for token in inputReleaseObservers {
            center.removeObserver(token)
        }
        inputReleaseObservers.removeAll()
        observedWindow = nil
    }

    private func installKeyUpMonitor() {
        guard keyUpMonitor == nil else {
            return
        }

        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyUp]) { [weak self] event in
            self?.releaseKeyIfFocusMovedAway(event)
            return event
        }
    }

    private func removeKeyUpMonitor() {
        if let keyUpMonitor {
            NSEvent.removeMonitor(keyUpMonitor)
            self.keyUpMonitor = nil
        }
    }

    private func releaseKeyIfFocusMovedAway(_ event: NSEvent) {
        guard let window,
              event.window === window,
              window.firstResponder !== self,
              let code = pressedMacKeyCodes[event.keyCode] else {
            return
        }
        sendKey(code: code, macKeyCode: event.keyCode, pressed: false)
    }

    private func claimInputFocusSoon() {
        DispatchQueue.main.async { [weak self] in
            self?.claimInputFocus()
        }
    }

    private func claimInputFocus() {
        guard let window, window.firstResponder !== self else {
            return
        }
        window.makeFirstResponder(self)
    }

    private func framebufferPoint(for event: NSEvent, image: CGImage) -> (x: UInt32, y: UInt32)? {
        let point = convert(event.locationInWindow, from: nil)
        let rect = imageRect(for: image)
        guard rect.contains(point) else {
            return nil
        }

        let x = ((point.x - rect.minX) / rect.width) * CGFloat(image.width)
        let y = ((point.y - rect.minY) / rect.height) * CGFloat(image.height)
        return (
            UInt32(max(0, min(CGFloat(image.width - 1), x))),
            UInt32(max(0, min(CGFloat(image.height - 1), y)))
        )
    }

    private func imageRect(for image: CGImage) -> NSRect {
        let imageSize = NSSize(width: image.width, height: image.height)
        guard imageSize.width > 0, imageSize.height > 0,
              bounds.width > 0, bounds.height > 0 else {
            return .zero
        }

        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return NSRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private static func makeImage(from framebuffer: NativeLinuxFramebuffer) -> CGImage? {
        let expectedSize = framebuffer.width * framebuffer.height * 4
        guard framebuffer.width > 0,
              framebuffer.height > 0,
              framebuffer.data.count >= expectedSize,
              let provider = CGDataProvider(data: framebuffer.data.prefix(expectedSize) as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }

        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
        )
        return CGImage(
            width: framebuffer.width,
            height: framebuffer.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: framebuffer.width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

private enum NativeLinuxKeyMap {
    static let capsLockMacKeyCode: UInt16 = 57

    private static let keyCodes: [UInt16: UInt16] = [
        0: 30, 1: 31, 2: 32, 3: 33, 4: 35, 5: 34, 6: 44, 7: 45,
        8: 46, 9: 47, 11: 48, 12: 16, 13: 17, 14: 18, 15: 19,
        16: 21, 17: 20, 18: 2, 19: 3, 20: 4, 21: 5, 22: 7,
        23: 6, 24: 13, 25: 10, 26: 8, 27: 12, 28: 9, 29: 11,
        30: 27, 31: 24, 32: 22, 33: 26, 34: 23, 35: 25, 36: 28,
        37: 38, 38: 36, 39: 40, 40: 37, 41: 39, 42: 43, 43: 51,
        44: 53, 45: 49, 46: 50, 47: 52, 48: 15, 49: 57, 50: 41,
        51: 14, 53: 1, 54: 126, 55: 125, 56: 42, 57: 58, 58: 56,
        59: 29, 60: 54, 61: 100, 62: 97, 65: 83, 67: 55, 69: 78,
        75: 98, 76: 96, 78: 74, 81: 117, 82: 82, 83: 79, 84: 80,
        85: 81, 86: 75, 87: 76, 88: 77, 89: 71, 91: 72, 92: 73,
        96: 63, 97: 64, 98: 65, 99: 61, 100: 66, 101: 67, 103: 87,
        105: 183, 106: 185, 107: 184, 109: 68, 111: 88, 113: 186,
        114: 110, 115: 102, 116: 104, 117: 111, 118: 62, 119: 107,
        120: 60, 121: 109, 122: 59, 123: 105, 124: 106, 125: 108,
        126: 103,
    ]

    static func linuxCode(forMacKeyCode keyCode: UInt16) -> UInt16? {
        keyCodes[keyCode]
    }
}

// MARK: - Status Bar

/// Bottom status bar showing VM state and audio routing.
private struct VMStatusBar: View {
    let controller: VMController

    var body: some View {
        HStack(spacing: 12) {
            // VM state indicator
            HStack(spacing: 6) {
                Circle()
                    .fill(vmStateColor)
                    .frame(width: 7, height: 7)
                Text(controller.stateLabel)
                    .font(.caption)
                    .fontWeight(.medium)
            }

            Divider()
                .frame(height: 12)

            // Audio routing summary
            HStack(spacing: 4) {
                Image(systemName: audioIconName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(controller.audioRoutingSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Audio device warning
            if let warning = controller.audioDeviceWarning {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }

            // Guest audio connection indicator
            if controller.isRunning && controller.config.audio.enabled {
                if controller.nativeLinuxVM != nil {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(.green)
                            .frame(width: 6, height: 6)
                        Text("virtio-snd")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if controller.isGuestConnected {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(.green)
                            .frame(width: 6, height: 6)
                        Text("Guest connected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(.yellow)
                            .frame(width: 6, height: 6)
                        Text("Waiting for guest tools...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Error indicator
            if let error = controller.errorMessage {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var vmStateColor: Color {
        if controller.isRunning { return .green }
        if controller.isPaused { return .yellow }
        return .gray
    }

    private var audioIconName: String {
        if !controller.config.audio.enabled { return "speaker.slash.fill" }
        if controller.audioDeviceWarning != nil { return "speaker.badge.exclamationmark.fill" }
        if controller.isGuestConnected { return "speaker.wave.2.fill" }
        if controller.config.audio.output != nil { return "speaker.fill" }
        return "speaker.fill"
    }
}
