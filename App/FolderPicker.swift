//
// FolderPicker.swift
// Ain
//
// Created by Ain on 2026/11/20.
//

import SwiftUI
import UniformTypeIdentifiers
import UIKit
import ObjectiveC

/// Presents `UIDocumentPickerViewController` the way UIKit expects it.
///
/// Two earlier attempts failed on modern iOS:
///
/// 1. SwiftUI `fileImporter` always opens the picker in copy mode, which cannot
///    copy a directory, so choosing a folder never called back.
/// 2. Hosting the controller inside a `.sheet` made the picker show up fine but
///    left its "Open" button inert: the tap never reached our delegate, and the
///    button even looked enabled while sitting inside a folder.
///
/// Presenting modally from the window's top view controller, and keeping the
/// delegate alive with an associated object (the delegate property is `weak`),
/// is the documented configuration.
struct FolderPicker: ViewModifier {
    @Binding var isPresented: Bool
    let types: [UTType]
    let complete: (Result<Selection, Error>) -> Void

    func body(content: Content) -> some View {
        content.onChange(of: isPresented) { presented in
            guard presented else { return }
            // Leaving `isPresented` true would keep a pending SwiftUI sheet around;
            // the picker is presented modally instead, so clear it on the next tick.
            DispatchQueue.main.async {
                isPresented = false
                DocumentPicker.present(types: types, complete: complete)
            }
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

final class DocumentPicker: NSObject, UIDocumentPickerDelegate {
    private let complete: (Result<FolderPicker.Selection, Error>) -> Void
    private let started = Date()
    private var settled = false
    private static let association = UnsafeRawPointer(UnsafeMutablePointer<UInt8>.allocate(capacity: 1))

    private init(_ complete: @escaping (Result<FolderPicker.Selection, Error>) -> Void) {
        self.complete = complete
    }

    static func present(types: [UTType],
                        complete: @escaping (Result<FolderPicker.Selection, Error>) -> Void) {
        guard let host = topViewController() else {
            complete(.failure(WorkspaceError.message("无法打开「文件」选择器，请改用「浏览 App 文档」。")))
            return
        }
        let delegate = DocumentPicker(complete)
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        controller.delegate = delegate
        controller.allowsMultipleSelection = false
        controller.shouldShowFileExtensions = false
        // `delegate` is weak: without this the coordinator dies right after present()
        // and every callback is silently dropped.
        objc_setAssociatedObject(controller, association, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        host.present(controller, animated: true)
        TheosRuntime.note("picker · presented \(types.map(\.identifier).joined(separator: ","))")
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
            ?? scene?.windows.first?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    private var elapsed: String { String(format: "%.1fs", Date().timeIntervalSince(started)) }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard !settled else { return }
        settled = true
        TheosRuntime.note("picker · picked \(urls.first?.path ?? "nil") · \(elapsed)")
        guard let url = urls.first else {
            complete(.failure(WorkspaceError.message("没有选中任何文件夹。")))
            return
        }
        complete(.success(FolderPicker.Selection(url)))
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        guard !settled else { return }
        settled = true
        TheosRuntime.note("picker · cancelled · \(elapsed)")
        complete(.failure(PickerCancelled()))
    }
}

struct PickerCancelled: LocalizedError {
    var errorDescription: String? { "已取消" }
}
