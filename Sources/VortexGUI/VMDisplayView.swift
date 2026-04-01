// VMDisplayView.swift — NSViewRepresentable wrapper for VZVirtualMachineView.
// VortexGUI

import SwiftUI
import Virtualization

/// Wraps `VZVirtualMachineView` for use in SwiftUI.
///
/// This view displays the framebuffer of a running `VZVirtualMachine` and
/// forwards keyboard and mouse events to the guest.
///
/// **Threading:** The view must be created and updated on the main thread
/// (enforced by SwiftUI). The underlying `VZVirtualMachineView` manages its
/// own rendering on the appropriate display link / CALayer pipeline.
struct VMDisplayView: NSViewRepresentable {
    let vm: VZVirtualMachine

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.virtualMachine = vm
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = true
        return view
    }

    func updateNSView(_ nsView: VZVirtualMachineView, context: Context) {
        // VZVirtualMachineView manages its own updates once the VM is assigned.
        // Re-assign only if the VM instance changed (shouldn't happen in normal
        // usage, but guards against SwiftUI identity issues).
        if nsView.virtualMachine !== vm {
            nsView.virtualMachine = vm
        }
    }
}
