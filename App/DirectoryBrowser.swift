//
// DirectoryBrowser.swift
// Ain
//
// Created for Theos Lab. Lets the app import a project from its own
// `Documents` directory, without going through the system document picker.
//

import SwiftUI

struct DirectoryBrowser: View {
    let root: URL
    let pick: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var current: URL
    @State private var entries: [URL] = []

    init(root: URL, pick: @escaping (URL) -> Void) {
        let normalized = root.standardizedFileURL
        self.root = normalized
        self.pick = pick
        _current = State(initialValue: normalized)
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    Button {
                        pick(current)
                        dismiss()
                    } label: {
                        Label("导入「\(current.lastPathComponent)」", systemImage: "square.and.arrow.down")
                    }
                } footer: {
                    Text("只列出文件夹。含 Makefile 的目录会被识别为 Theos 项目。")
                }
                if entries.isEmpty {
                    Section {
                        Text("这个位置没有子文件夹。用「文件」App 把项目拷进「我的 iPhone → Theos Lab」，再回到这里。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Section("文件夹") {
                        ForEach(entries, id: \.self) { url in
                            Button {
                                current = url
                                load()
                            } label: {
                                HStack {
                                    Image(systemName: "folder")
                                    Text(url.lastPathComponent)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(current.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                if current != root {
                    ToolbarItem(placement: .bottomBar) {
                        Button {
                            current = current.deletingLastPathComponent()
                            load()
                        } label: { Label("上一级", systemImage: "arrow.up") }
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear(perform: load)
    }

    private func load() {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        entries = ((try? FileManager.default.contentsOfDirectory(at: current,
                                                                 includingPropertiesForKeys: Array(keys),
                                                                 options: [.skipsHiddenFiles])) ?? [])
            .filter { url in
                guard let values = try? url.resourceValues(forKeys: keys) else { return false }
                return values.isDirectory == true && values.isSymbolicLink != true
            }
            .filter { $0.lastPathComponent != "Builds" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
