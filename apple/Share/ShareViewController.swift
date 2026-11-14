import FloridaKit
import SwiftUI
import UniformTypeIdentifiers
import WidgetKit
import UIKit

@MainActor
final class ShareViewController: UIViewController {
    private var model: ShareCaptureModel?
    private var testInput: ShareInput?
    private var testPath: String?
    private var testCompletion: ((TaskItem?) -> Void)?

    #if DEBUG
    convenience init(input: ShareInput, path: String, completion: @escaping (TaskItem?) -> Void) {
        self.init()
        testInput = input
        testPath = path
        testCompletion = completion
    }
    #endif

    override func viewDidLoad() {
        super.viewDidLoad()
        Task {
            do {
                let input = try await readInput()
                let model = ShareCaptureModel(input: input)
                self.model = model
                let host = UIHostingController(rootView: ShareSheet(model: model, add: { [weak self] in
                    self?.add()
                }, cancel: { [weak self] in self?.cancel() }))
                addChild(host)
                host.view.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(host.view)
                NSLayoutConstraint.activate([
                    host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                    host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                    host.view.topAnchor.constraint(equalTo: view.topAnchor),
                    host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                ])
                host.didMove(toParent: self)
                await model.load(path: testPath)
            } catch {
                let alert = UIAlertController(title: "Can’t share this item", message: "Share one link or plain text with Florida.", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.complete(nil) })
                present(alert, animated: true)
            }
        }
    }

    private func add() {
        guard let model else { return }
        let path = testPath
        Task {
            if let saved = await model.add(write: { draft, id, category in
                try await Task.detached {
                    try ShareTaskWriter.save(draft, captureID: id, categoryID: category, path: path)
                }.value
            }) {
                WidgetCenter.shared.reloadAllTimelines()
                complete(saved)
            }
        }
    }

    private func cancel() {
        guard model?.cancel() == true else { return }
        complete(nil)
    }

    private func complete(_ task: TaskItem?) {
        if let testCompletion { testCompletion(task); return }
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func readInput() async throws -> ShareInput {
        if let testInput { return testInput }
        guard let items = extensionContext?.inputItems as? [NSExtensionItem], items.count == 1,
              let item = items.first, let providers = item.attachments, (1...2).contains(providers.count),
              providers.allSatisfy({ provider in
                  !provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
                      && !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                      && (provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
                          || provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier))
              }),
              providers.filter({ $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }).count <= 1,
              providers.filter({ !$0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }).count <= 1
        else { throw ShareTaskWriter.CaptureError.invalidDraft }
        var input = ShareInput(pageTitle: item.attributedTitle?.string ?? item.attributedContentText?.string)
        for provider in providers {
            let isURL = provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
            let type = isURL ? UTType.url.identifier : UTType.plainText.identifier
            let value: String? = try await withCheckedThrowingContinuation { continuation in
                provider.loadItem(forTypeIdentifier: type, options: nil) { value, error in
                    if let error { continuation.resume(throwing: error); return }
                    let text = (value as? URL)?.absoluteString ?? (value as? String)
                        ?? (value as? Data).flatMap { String(data: $0, encoding: .utf8) }
                    continuation.resume(returning: text)
                }
            }
            guard let value, value.utf8.count <= 65_536 else { throw ShareTaskWriter.CaptureError.invalidDraft }
            if isURL {
                guard TaskSource.from(url: value) != nil else { throw ShareTaskWriter.CaptureError.invalidDraft }
                input.url = value
            } else { input.text = value }
        }
        if input.url == nil { input.pageTitle = nil }
        guard (input.pageTitle?.utf8.count ?? 0) <= 65_536,
              ShareDraftParser.parse(input, now: Date(), calendar: .current) != nil else {
            throw ShareTaskWriter.CaptureError.invalidDraft
        }
        return input
    }
}
