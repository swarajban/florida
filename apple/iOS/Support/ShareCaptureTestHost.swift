#if DEBUG
import FloridaKit
import SwiftUI

struct ShareCaptureTestHost: View {
    @State private var result: String?
    private let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite").path

    var body: some View {
        if let result {
            Text(result).accessibilityIdentifier("share-result")
        } else {
            Controller(path: path) { result = $0 }
        }
    }

    private struct Controller: UIViewControllerRepresentable {
        let path: String
        let complete: (String) -> Void

        func makeUIViewController(context: Context) -> ShareViewController {
            let store = try! AppDatabase(path: path)
            try! store.apply(SyncResponse(cursor: Date().ISO8601Format(), categories: [
                TaskCategory(id: "inbox", name: "Inbox", scheduleId: "work", createdAt: Date(), updatedAt: Date()),
                TaskCategory(id: "work", name: "Work", scheduleId: "work", createdAt: Date(), updatedAt: Date()),
            ]))
            try! store.writer.close()
            let title = UserDefaults.standard.string(forKey: "uiShareTitle") ?? "Fix crash #123"
            return ShareViewController(input: ShareInput(url: "https://example.com/article", pageTitle: title), path: path) { task in
                let reader = try! AppDatabase.openExisting(path: path, requireSync: false)
                let writes = try! reader.pendingWrites().count
                let saved = task.flatMap { try! reader.task(id: $0.id) }
                try! reader.writer.close()
                complete("Writes: \(writes) · \(saved?.title ?? "Cancelled") · \(saved?.source?.url ?? "")")
            }
        }

        func updateUIViewController(_ controller: ShareViewController, context: Context) {}
    }
}
#endif
