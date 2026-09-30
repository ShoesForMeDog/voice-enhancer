import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// Application entry point.
///
/// This file should remain intentionally small. Anything more than "wire up
/// the scene" goes in ``ContentView`` or deeper. Keeping the @main type
/// trivial makes the app's top-level behavior obvious at a glance and makes
/// it easy to swap in alternative entry points later (e.g. a menu-bar-only
/// mode, a CLI renderer for tuning).
@main
struct VoiceEnhancerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// The single shared view model. Injected via environment so any view
    /// that needs audio state can reach it without explicit passing.
    @StateObject private var audio = AudioViewModel()

    var body: some Scene {
        Window("Voice Enhancer", id: "main") {
            ContentView()
                .environmentObject(audio)
                .frame(minWidth: 520, minHeight: 420)
                .task {
                    // Start the audio graph when the window first appears.
                    // Errors surface into audio.status for the UI to show.
                    await audio.start()
                }
                // NOTE: Do NOT stop audio on window disappear. The user needs
                // the capture graph running while the window is closed (e.g.
                // during a Google Meet call). Audio stops only when the app
                // actually quits (see onReceive below).
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: NSApplication.willTerminateNotification)
                ) { _ in
                    audio.stop()
                }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra("Voice Enhancer", systemImage: "waveform") {
            VoiceEnhancerMenu()
                .environmentObject(audio)
        }
    }
}

private struct VoiceEnhancerMenu: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var audio: AudioViewModel

    var body: some View {
        Button("Open Voice Enhancer") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }

        Toggle("Enhancement Enabled", isOn: $audio.isEnabled)

        Divider()

        Button("Quit Voice Enhancer") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
