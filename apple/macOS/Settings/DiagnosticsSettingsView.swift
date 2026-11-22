import AppKit
import Combine
import FloridaKit
import SwiftUI

struct DiagnosticsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var includeText = false
    @State private var status: DiagnosticsRecorder.Status?
    @State private var message: String?

    private let recorder = DiagnosticsRecorder.shared

    var body: some View {
        Form {
            Section {
                Text("Record app activity locally to help reproduce a problem. Nothing is sent automatically.")
                    .foregroundStyle(.secondary)
                if status?.isRecording != true {
                    Toggle("Include text in the next recording", isOn: $includeText)
                }
                if let status {
                    LabeledContent(status.isRecording ? "Recording" : "Stopped") {
                        Text("\(Int(status.elapsed))s elapsed · \(status.count) events")
                            .monospacedDigit()
                    }
                } else {
                    Text("No recording")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    if status?.isRecording == true {
                        Button("Stop Recording") {
                            recorder.stop()
                            refreshStatus()
                        }
                    } else {
                        Button("Start Recording") {
                            recorder.start(includeText: includeText, excludingToken: model.config?.token)
                            recorder.record("mac.screen", "snapshot", [
                                "calendar": .value(model.viewMode.rawValue),
                                "screen": .value(model.interaction.kind.rawValue),
                            ])
                            includeText = false
                            message = nil
                            refreshStatus()
                        }
                    }
                    Button("Copy Report") { copyReport() }
                        .disabled(status == nil)
                    Button("Share Report…") { shareReport() }
                        .disabled(status == nil)
                    Button("Clear", role: .destructive) {
                        recorder.clear()
                        includeText = false
                        message = nil
                        refreshStatus()
                    }
                    .disabled(status == nil)
                }
                if let message {
                    Text(message)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Recording stops after 15 minutes. Include text can show submitted Quick Add text and task or event titles. Review the report before sharing.")
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshStatus)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if model.settingsTab == .diagnostics, status?.isRecording == true { refreshStatus() }
        }
    }

    private func refreshStatus() {
        status = recorder.status
    }

    private func makeReport() -> String? {
        let state: String
        if model.config == nil { state = "disconnected" }
        else if model.isSyncing { state = "syncing" }
        else if model.lastSyncError != nil { state = "error" }
        else if model.lastSyncAt == nil { state = "waiting" }
        else { state = "idle" }
        return recorder.report(.init(
            device: "Mac", serverURL: model.config?.baseURL, syncState: state,
            pending: model.pendingWriteCount, rejected: model.rejectedWriteCount))
    }

    private func copyReport() {
        guard let report = makeReport() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        message = pasteboard.setString(report, forType: .string) ? "Report copied." : "Could not copy report."
    }

    private func shareReport() {
        guard let report = makeReport(), let view = NSApp.keyWindow?.contentView else { return }
        let anchor = NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        NSSharingServicePicker(items: [report]).show(relativeTo: anchor, of: view, preferredEdge: .minY)
    }
}
