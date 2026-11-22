import FloridaKit
import SwiftUI
import UIKit

struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @State private var includeText = false
    @State private var status: DiagnosticsRecorder.Status?
    private let recorder = DiagnosticsRecorder.shared

    var body: some View {
        Form {
            Section {
                if status?.isRecording == true {
                    Button("Stop recording") {
                        recorder.stop()
                        status = recorder.status
                    }
                } else {
                    Toggle("Include text", isOn: $includeText)
                    Button("Start recording") {
                        recorder.start(includeText: includeText, excludingToken: model.serverConfig?.token)
                        includeText = false
                        status = recorder.status
                    }
                }
                if let status {
                    let seconds = Int(status.elapsed)
                    LabeledContent(status.isRecording ? "Recording" : "Stopped",
                                   value: "\(seconds / 60)m \(seconds % 60)s · \(status.count) events")
                }
            } footer: {
                Text("Recording stays in memory and stops after 15 minutes. Include text can show submitted Quick Add text and task or event titles in the next report. Review it before sharing.")
            }

            if let status {
                Section {
                    if !status.isRecording, let report {
                        NavigationLink("Preview report") {
                            ScrollView {
                                Text(verbatim: report)
                                    .font(.system(.footnote, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding()
                                    .accessibilityIdentifier("diagnostics-report")
                            }
                            .navigationTitle("Report")
                        }
                        Button("Copy report") {
                            UIPasteboard.general.setItems([["public.utf8-plain-text": report]], options: [.localOnly: true])
                            model.showToast(Toast(message: "Diagnostics report copied.", systemImage: "doc.on.doc", style: .success))
                        }
                        ShareLink(item: report) { Text("Share report") }
                    }
                    Button("Clear recording", role: .destructive) {
                        recorder.clear()
                        status = nil
                        includeText = false
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(FloridaStyle.paper)
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toastOverlay()
        .onAppear { status = recorder.status }
        .task(id: status?.isRecording == true) {
            while !Task.isCancelled, status?.isRecording == true {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                status = recorder.status
            }
        }
    }

    private var report: String? {
        recorder.report(.init(
            device: UIDevice.current.model,
            serverURL: model.serverConfig?.baseURL,
            syncState: model.needsSetup ? "not configured" : model.isSyncing ? "syncing" : model.lastError != nil ? "error" : "idle",
            pending: model.pendingWriteCount, rejected: model.rejectedChanges.count))
    }
}
