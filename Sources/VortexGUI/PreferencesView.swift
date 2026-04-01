// PreferencesView.swift -- Settings window (Vortex > Settings).
// VortexGUI
//
// Minimal preferences pane. Currently shows application info and paths.
// Future: global audio defaults, VM storage location, update settings.

import SwiftUI
import VortexCore
import VortexPersistence

// MARK: - PreferencesView

/// The Settings scene content. Accessible via Cmd+Comma or the app menu.
struct PreferencesView: View {

    @State private var vmStoragePath: String = ""

    var body: some View {
        TabView {
            GeneralTab()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            AudioTab()
                .tabItem {
                    Label("Audio", systemImage: "speaker.wave.2")
                }

            AboutTab()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 480, height: 300)
    }
}

// MARK: - General Tab

private struct GeneralTab: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("VM Storage") {
                    let path = VMFileManager().baseDirectory.path
                    Text(path)
                        .font(.caption)
                        .monospaced()
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                LabeledContent("Close Behavior") {
                    Text("Quit when last window closes")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Audio Tab

private struct AudioTab: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Transport") {
                    Text("TCP (port 5198)")
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Wire Format") {
                    Text("8-byte header + PCM payload")
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Microphone") {
                    Text("Requires TCC permission (launch from Finder)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Audio Bridge")
            }

            Section {
                Text("Per-VM audio devices are configured in each VM's Audio Settings.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - About Tab

private struct AboutTab: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("Vortex")
                .font(.title2)
                .fontWeight(.semibold)

            Text("macOS VM Hypervisor with Per-VM Audio Routing")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("macOS 14+ on Apple Silicon")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 24)
    }
}
