//
// ImportHub.swift
// Theos Lab
//
// Import entry point that does not depend on `UIDocumentPickerViewController`.
//
// On current iOS the system folder picker shows its "開啟" button as enabled but
// the tap can end up in `documentPickerWasCancelled` (the provider refuses to
// hand out in-place access), so the button looks dead. Everything here works on
// files that already live in the app's own Documents directory, where no
// security scope is needed at all.
//

import SwiftUI

struct ImportHub: View {
    let documents: URL
    @Binding var projects: [URL]
    let open: (URL) -> Void
    let browseDocuments: () -> Void
    let useSystemPicker: () -> Void
    let refresh: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section {
                    if projects.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("还没有发现项目").font(.subheadline.weight(.semibold))
                            Text("把含 Makefile 的项目文件夹拷进「我的 iPhone → Theos Lab」，它会出现在这里。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    } else {
                        ForEach(projects, id: \.self) { url in
                            Button {
                                dismiss()
                                open(url)
                            } label: {
                                HStack {
                                    Image(systemName: "folder.fill").foregroundStyle(.tint)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(url.lastPathComponent).foregroundStyle(.primary)
                                        if let relative = relativePath(url) {
                                            Text(relative).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("App 文档里已发现的项目")
                } footer: {
                    Text("这些文件夹已经在本机 App 沙盒内，点一下就能打开，不经过系统选择器。")
                }

                Section {
                    Button {
                        refresh()
                    } label: {
                        Label("重新扫描 App 文档", systemImage: "arrow.clockwise")
                    }
                    Button {
                        dismiss()
                        browseDocuments()
                    } label: {
                        Label("浏览 App 文档…", systemImage: "folder")
                    }
                    Button {
                        dismiss()
                        useSystemPicker()
                    } label: {
                        Label("从「文件」App 选择…", systemImage: "folder.badge.plus")
                    }
                } header: {
                    Text("其他方式")
                } footer: {
                    Text("若系统选择器点「開啟」没反应，别用它：改用「浏览 App 文档」，或按下面的步骤把文件夹拷进 App。")
                }

                Section {
                    step(1, "打开「文件」App → 我的 iPhone → Theos Lab")
                    step(2, "长按项目文件夹 →「拷贝」，回到 Theos Lab 文件夹 →「粘贴」")
                    step(3, "回到这个页面点「重新扫描」，再点项目打开")
                } header: {
                    Text("最稳的三步")
                } footer: {
                    Text("Theos Lab 已开启文件共享，所以它可以出现在「文件」App 的「我的 iPhone」里。")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("导入 Theos 项目")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func step(_ index: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index)")
                .font(.caption.weight(.bold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))
            Text(text).font(.footnote)
        }
        .padding(.vertical, 2)
    }

    private func relativePath(_ url: URL) -> String? {
        let root = documents.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path != root, path.hasPrefix(root + "/") else { return nil }
        let relative = String(path.dropFirst(root.count + 1))
        return relative.isEmpty ? nil : relative
    }
}
