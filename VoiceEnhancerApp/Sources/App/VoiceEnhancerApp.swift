import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let audio = AudioViewModel()
    private let isBackgroundLaunch = ProcessInfo.processInfo.arguments.contains("--background-launch")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The LaunchAgent is the single owner of login startup. Without this,
        // macOS may also restore whichever development or installed copy was
        // running at logout and launch two copies from different paths.
        NSApp.disableRelaunchOnLogin()

        Task {
            await audio.start()

            if isBackgroundLaunch {
                // Launching at login must start the capture graph without
                // leaving the settings window open on the desktop.
                NSApp.windows.first { $0.title == "Voice Enhancer" }?.close()
            }
        }
    }

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

    var body: some Scene {
        Window("Voice Enhancer", id: "main") {
            ContentView()
                .environmentObject(appDelegate.audio)
                .frame(minWidth: 520, minHeight: 420)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra("Voice Enhancer", systemImage: "waveform") {
            VoiceEnhancerMenu()
                .environmentObject(appDelegate.audio)
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
