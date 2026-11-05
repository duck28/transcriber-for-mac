import SwiftUI

@main
struct TranscriberApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Transcriber", id: "main") {
            ContentView()
                .environmentObject(appDelegate.model)
        }
        .commands {
            TranscriberCommands(model: appDelegate.model)
        }

        Settings {
            SettingsView()
                .environmentObject(appDelegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = TranscriptionModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.appearance.apply()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.applicationShouldTerminate()
    }
}

private struct TranscriberCommands: Commands {
    @ObservedObject var model: TranscriptionModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Transcript") { model.newTranscript() }
                .keyboardShortcut("n")
                .disabled(!model.canStartNewTranscript)
            Divider()
            Button("Transcribe Audio File…", action: model.chooseAudioFile)
                .keyboardShortcut("o")
                .disabled(!model.isIdle || !model.isSelectedLocaleInstalled)
            Button("Import from YouTube…") { model.showYouTubeImport = true }
                .keyboardShortcut("y", modifiers: [.command, .shift])
                .disabled(!model.isIdle || !model.isSelectedLocaleInstalled)
            Divider()
            Toggle("Narrator Mode", isOn: $model.narratorMode)
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!model.isIdle)
            Menu("Export Subtitles") {
                ForEach(SubtitleFormat.allCases) { format in
                    Button(format.menuTitle) { model.exportSubtitles(format) }
                }
                if model.finalCutProURL != nil {
                    Divider()
                    Button("Open in Final Cut Pro", action: model.openInFinalCutPro)
                }
            }
            .disabled(!model.canExportSubtitles)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save As…") { model.save() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(model.segments.isEmpty)
            Button("Rename Transcript…") { model.showRenameTranscript = true }
            Button("Show in Finder", action: model.revealInFinder)
        }
        CommandGroup(replacing: .sidebar) {
            Button(model.showsSidebar ? "Hide Transcripts" : "Show Transcripts") { model.showsSidebar.toggle() }
                .keyboardShortcut("s", modifiers: [.control, .command])
        }
        CommandGroup(after: .toolbar) {
            Picker("Appearance", selection: $model.appearance) {
                ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
            }
        }
    }
}
