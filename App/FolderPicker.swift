//
// FolderPicker.swift
// Ain
//
// Created by Ain on 2026/11/20.
//

import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct FolderPicker: ViewModifier {
    @Binding var isPresented: Bool
    let types: [UTType]
    let complete: (Result<Selection, Error>) -> Void

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            DocumentPicker(types: types) { result in
                isPresented = false
                complete(result)
            }
            .ignoresSafeArea()
        }
    }

    final class Selection: @unchecked Sendable {
        let url: URL
        private let hasScope: Bool

        init(_ url: URL) {
            self.url = url
            hasScope = url.startAccessingSecurityScopedResource()
        }

        deinit {
            if hasScope { url.stopAccessingSecurityScopedResource() }
        }
    }

}

/// Wraps `UIDocumentPickerViewController` directly.
///
/// SwiftUI's `fileImporter` always opens the picker in copy mode, which cannot
/// copy directories: choosing a folder dismisses the picker without ever
/// calling the completion handler. Presenting the controller ourselves with
/// `asCopy: false` returns a security-scoped folder URL instead.
private struct DocumentPicker: UIViewControllerRepresentable {
    let types: [UTType]
    let finish: (Result<FolderPicker.Selection, Error>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(finish) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        controller.delegate = context.coordinator
        controller.allowsMultipleSelection = false
        controller.shouldShowFileExtensions = false
        return controller
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let finish: (Result<FolderPicker.Selection, Error>) -> Void
        private var settled = false

        init(_ finish: @escaping (Result<FolderPicker.Selection, Error>) -> Void) {
            self.finish = finish
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard !settled else { return }
            settled = true
            guard let url = urls.first else {
                finish(.failure(WorkspaceError.message("没有选中任何文件或文件夹。")))
                return
            }
            finish(.success(FolderPicker.Selection(url)))
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            guard !settled else { return }
            settled = true
            finish(.failure(PickerCancelled()))
        }
    }
}

struct PickerCancelled: LocalizedError {
    var errorDescription: String? { "已取消" }
}
