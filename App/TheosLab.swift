//
// TheosLab.swift
// Ain
//
// Created by Ain on 2026/11/20.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ImageIO

@main
struct TheosLabApp: App {
    var body: some Scene {
        WindowGroup { WorkspaceView() }
    }
}

private struct WorkspaceView: View {
    private enum ImportKind: String, Identifiable {
        case project, sdk, ollvm, pass, library, arm64eLinker
        var id: Self { self }

        var types: [UTType] {
            switch self {
            case .project: return [.folder]
            case .sdk: return [.folder, .package]
            default: return [.data]
            }
        }
    }
    private struct ProjectChoices: Identifiable {
        let id = UUID()
        let urls: [URL]
        let documents: URL
    }
    private static let queue = DispatchQueue(label: "Theos Lab Linux", qos: .userInitiated)
    private static let projectImportQueue = DispatchQueue(label: "Theos Lab Project Import", qos: .userInitiated)
    private static let runtime = TheosRuntime()
    @AppStorage("minimumIOS") private var deployment = "15.0"
    @AppStorage("sdkVersion") private var sdk = "26.0"
    @AppStorage("activeProjectPath") private var activeProjectPath = ""
    @State private var sdks: [String] = []
    @State private var projects: [URL] = []
    @State private var project: URL?
    @State private var tree: [ProjectEntry] = []
    @State private var tabs: [String] = []
    @State private var fileSearch = ""
    @State private var browser = false
    @State private var panel: BottomPanel?
    @State private var editingSource = false
    @AppStorage("showNavigator") private var showNavigator = true
    @AppStorage("buildConfiguration") private var configuration = BuildConfiguration.debug
    @AppStorage("buildArchitecture") private var architecture = BuildArchitecture.project
    @AppStorage("predictCompletion") private var predictCompletion = true
    @State private var linkedLibraries = Set<String>()
    @State private var image: ProjectImage?
    @AppStorage("obfuscationMode") private var obfuscation = ObfuscationMode.off
    @AppStorage("ollvmFlatten") private var flatten = true
    @AppStorage("ollvmSubstitute") private var substitute = true
    @AppStorage("ollvmBogus") private var bogus = false
    @AppStorage("ollvmParameters") private var parameters = ""
    @State private var buildSettings = false
    @State private var projectDeployment: String?
    @State private var issues: [BuildIssue] = []
    @State private var location: EditorLocation?
    @State private var encoding = String.Encoding.utf8
    @State private var openError: String?
    @Environment(\.horizontalSizeClass) private var width

    private enum BottomPanel { case issues, log }
    private var files: [String] { tree.flatMap(\.filePaths) }
    @State private var sourcePath: String?
    @State private var source = ""
    @State private var saved = ""
    @State private var log = ""
    @State private var status = ""
    @State private var busy = false
    @State private var importKind = ImportKind.project
    @State private var browseDocuments = false
    @State private var environmentText = ""
    @State private var showFilePicker = false
    @State private var showImportHub = false
    @State private var pendingOpenProject: URL?
    @State private var pendingSystemPicker = false
    @State private var pendingBrowseDocuments = false
    @State private var importAfterSettings: ImportKind?
    @State private var projectChoices: ProjectChoices?
    @State private var pickedProject: URL?
    @State private var format = BuildFormat.automatic
    @State private var outputs: [URL] = []
    @State private var share: ShareItem?

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                commandBar
                Divider()
                HStack(spacing: 0) {
                    if width == .regular, project != nil, showNavigator {
                        explorer.frame(width: 230)
                        Divider()
                    }
                    VStack(spacing: 0) {
                        if project == nil {
                            welcome
                        } else {
                            tabStrip
                            Divider()
                            if let sourcePath {
                                editorToolbar(sourcePath)
                                if let image {
                                    ImagePreview(image: image).id(sourcePath)
                                } else {
                                    IDEEditor(text: $source, path: sourcePath, location: location,
                                              projectWords: files, editable: !busy,
                                              predictionEnabled: predictCompletion,
                                              editingChanged: { editingSource = $0 })
                                }
                            } else {
                                Spacer()
                                Text("从文件树打开源码").foregroundStyle(.secondary)
                                Spacer()
                            }
                        }
                        Divider()
                        if let panel, !editingSource { outputPanel(panel) }
                        Divider()
                        statusBar
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Theos Lab")
            .navigationBarHidden(true)
            .modifier(FolderPicker(isPresented: $showFilePicker, types: importKind.types) { result in
                switch result {
                case .success(let selection):
                    perform { try finishImport(selection, kind: importKind) }
                case .failure(let error):
                    guard !(error is PickerCancelled) else { return }
                    status = error.localizedDescription
                    openError = status
                }
            })
            .sheet(item: $projectChoices, onDismiss: {
                guard let url = pickedProject else { return }
                pickedProject = nil
                perform { try openProject(url) }
            }) { choices in
                NavigationView {
                    List(choices.urls, id: \.self) { url in
                        Button {
                            pickedProject = url
                            projectChoices = nil
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(url.lastPathComponent)
                                if let path = relativeProjectPath(url.deletingLastPathComponent(), in: choices.documents),
                                   path != "." {
                                    Text(path).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .navigationTitle("选择要打开的项目")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { projectChoices = nil }
                    } }
                }
                .navigationViewStyle(.stack)
            }
            .sheet(isPresented: $browser) {
                NavigationView {
                    explorer
                        .navigationTitle("项目文件")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { browser = false }
                        } }
                }
                .navigationViewStyle(.stack)
            }
            .sheet(isPresented: $browseDocuments) {
                DirectoryBrowser(root: (try? documents()) ?? FileManager.default.urls(for: .documentDirectory,
                                                                                      in: .userDomainMask)[0]) { url in
                    importProject(at: url)
                }
            }
            .sheet(isPresented: $showImportHub, onDismiss: {
                // Presenting another controller while the sheet is still on screen makes
                // the system drop it, so defer until the sheet is gone.
                if let url = pendingOpenProject {
                    pendingOpenProject = nil
                    perform { try openProject(url) }
                } else if pendingSystemPicker {
                    pendingSystemPicker = false
                    beginImport(.project, viaHub: true)
                } else if pendingBrowseDocuments {
                    pendingBrowseDocuments = false
                    browseDocuments = true
                }
            }) {
                ImportHub(documents: (try? documents()) ?? FileManager.default.urls(for: .documentDirectory,
                                                                                    in: .userDomainMask)[0],
                          projects: $projects,
                          open: { pendingOpenProject = $0 },
                          browseDocuments: { pendingBrowseDocuments = true },
                          useSystemPicker: { pendingSystemPicker = true },
                          refresh: { perform { try refreshProjects() } })
            }
            .sheet(item: $share) { item in ShareSheet(url: item.url) }
            .sheet(isPresented: $buildSettings, onDismiss: {
                guard let kind = importAfterSettings else { return }
                importAfterSettings = nil
                beginImport(kind)
            }) { settingsView }
            .alert("无法打开或保存", isPresented: Binding(
                get: { openError != nil }, set: { if !$0 { openError = nil } }
            )) {
                Button("好", role: .cancel) { openError = nil }
            } message: { Text(openError ?? "") }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                // Pasting a project into Documents happens in the Files app, so pick it
                // up as soon as the user comes back instead of asking them to refresh.
                guard !busy else { return }
                try? refreshProjects()
            }
            .onAppear {
                perform {
                    try refreshProjects()
                    if project == nil, !activeProjectPath.isEmpty {
                        let path = try documents().appendingPathComponent(activeProjectPath).standardizedFileURL.path
                        if let previous = projects.first(where: { $0.standardizedFileURL.path == path }) {
                            try openProject(previous)
                        }
                    }
                }
                Self.queue.async {
                    let versions = (try? Self.runtime.installedSDKs()) ?? []
                    DispatchQueue.main.async {
                        sdks = versions
                        adoptInstalledSDK(versions)
                    }
                }
            }
            .onOpenURL { url in
                // Reached through Files → 分享 → 「Theos Lab」. The URL is security scoped,
                // so keep the selection alive until the background copy finishes.
                TheosRuntime.note("openURL · \(url.path)")
                importProject(FolderPicker.Selection(url))
            }
        }
        .navigationViewStyle(.stack)
    }

    private var welcome: some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: "hammer.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.tint)
                Text("打开一个 Theos 项目").font(.title2.weight(.semibold))

                if projects.isEmpty {
                    Text("把含 Makefile 的项目文件夹拷进「我的 iPhone → Theos Lab」，回到这里就会自动列出，点一下即可打开。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                } else {
                    VStack(spacing: 0) {
                        let shown = Array(projects.prefix(6).enumerated())
                        ForEach(shown, id: \.element) { item in
                            Button {
                                perform { try openProject(item.element) }
                            } label: {
                                HStack {
                                    Image(systemName: "folder.fill").foregroundStyle(.tint)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.element.lastPathComponent).foregroundStyle(.primary)
                                        if let path = relativeProjectPath(item.element, in: (try? documents()) ?? item.element),
                                           path != "." {
                                            Text(path).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 10)
                                .padding(.horizontal, 14)
                            }
                            if item.offset < shown.count - 1 { Divider().padding(.leading, 44) }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
                    .padding(.horizontal, 20)
                }

                HStack(spacing: 10) {
                    Button("导入项目…") { showImportHub = true }
                        .buttonStyle(.borderedProminent)
                    Button("刷新") { perform { try refreshProjects() } }
                        .buttonStyle(.bordered)
                }
                .padding(.top, 4)
            }
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
    }

    private var commandBar: some View {
        HStack(spacing: 14) {
            Menu {
                Button("导入项目…") { showImportHub = true }
                Button("浏览 App 文档…") { browseDocuments = true }
                Button("刷新项目列表") { perform { try refreshProjects() } }
                Text("若系统选择器点「開啟」没反应：在「文件」里长按项目文件夹 → 拷贝，粘贴进「我的 iPhone → Theos Lab」，项目会自动列出来")
                ForEach(projects, id: \.self) { url in
                    Button(url.lastPathComponent) { perform { try openProject(url) } }
                }
            } label: {
                Label(project?.lastPathComponent ?? "项目", systemImage: "folder")
                    .lineLimit(1)
            }.accessibilityIdentifier("project-menu")
            if project != nil {
                Button {
                    if width == .regular { showNavigator.toggle() } else { browser = true }
                } label: {
                    Image(systemName: width == .regular && !showNavigator ? "sidebar.left" : "sidebar.leading")
                        .symbolVariant(width == .regular && showNavigator ? .fill : .none)
                }
                    .accessibilityLabel("项目文件")
                    .accessibilityValue(width == .regular && showNavigator ? "已展开" : "已收起")
                    .help(width == .regular && showNavigator ? "收起侧栏" : "展开项目文件")
                    .keyboardShortcut("0", modifiers: .command)
            }
            Spacer(minLength: 0)
            Menu {
                Picker("iPhoneOS SDK", selection: $sdk) {
                    ForEach(sdkOptions, id: \.self) { Text(sdkTitle($0)).tag($0) }
                }
                Picker("产物格式", selection: $format) {
                    ForEach(BuildFormat.allCases) { Text($0.title).tag($0) }
                }
                if canPrepareSelectedSDK {
                    Button("准备所选 SDK") { prepareSDK() }
                }
                Button("导入本地 SDK") { beginImport(.sdk) }
            } label: { Label(sdk, systemImage: "cpu") }
            Button { buildSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                .accessibilityLabel("构建设置")
            Button(action: build) {
                Image(systemName: "hammer.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(project == nil)
            .accessibilityLabel("构建")
            .keyboardShortcut("b", modifiers: .command)
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground))
        .disabled(busy)
    }

    private func editorToolbar(_ path: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.right").font(.caption2)
            Text(path.replacingOccurrences(of: "/", with: "  ›  "))
                .lineLimit(1).truncationMode(.head)
                .font(.caption.monospaced())
            Spacer(minLength: 4)
            if let image {
                Text("\(image.width) × \(image.height) 像素")
                    .font(.caption.monospacedDigit())
            } else {
            Menu {
                ForEach(EditorSymbol.read(source)) { symbol in
                    Button(symbol.name) { location = EditorLocation(line: symbol.line, column: 1) }
                }
            } label: { Image(systemName: "list.bullet.rectangle") }
                .accessibilityLabel("跳转到符号")
            Button {
                UIPasteboard.general.string = source
                status = "已复制整个文件"
            } label: { Image(systemName: "doc.on.doc") }
                .accessibilityLabel("复制整个文件")
                .help("复制整个文件")
            Button {
                endEditing()
            } label: { Image(systemName: "keyboard.chevron.compact.down") }
                .accessibilityLabel("收起键盘")
                .disabled(!editingSource)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.65))
    }

    private func endEditing() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private var settingsView: some View {
        NavigationView {
            Form {
                Section("SDK") {
                    Picker("iPhoneOS", selection: $sdk) {
                        ForEach(sdkOptions, id: \.self) { version in Text(sdkTitle(version)).tag(version) }
                    }
                    if canPrepareSelectedSDK {
                        Button(sdks.contains(sdk) ? "检查 SDK" : "安装所选 SDK") {
                            buildSettings = false
                            prepareSDK()
                        }
                    }
                    Button("导入本地 SDK") { importFromSettings(.sdk) }
                }
                Section("构建") {
                    Picker("配置", selection: $configuration) {
                        ForEach(BuildConfiguration.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    Picker("架构", selection: $architecture) {
                        ForEach(BuildArchitecture.allCases) { Text($0.title).tag($0) }
                    }
                    if architecture.requiresARM64e {
                        Button("导入 arm64e 链接器") { importFromSettings(.arm64eLinker) }
                    }
                    Picker("产物格式", selection: $format) {
                        ForEach(BuildFormat.allCases) { Text($0.title).tag($0) }
                    }
                    TextField("最低 iOS", text: Binding(
                        get: { projectDeployment ?? deployment },
                        set: { if project != nil { projectDeployment = $0 } else { deployment = $0 } }
                    )).keyboardType(.decimalPad)
                }
                if project != nil {
                    Section("额外链接库") {
                        ForEach(files.filter(BuildOptions.isLibrary), id: \.self) { path in
                            Toggle(path, isOn: Binding(
                                get: { linkedLibraries.contains(path) },
                                set: { checked in
                                    if checked { linkedLibraries.insert(path) } else { linkedLibraries.remove(path) }
                                }
                            ))
                        }
                        Button("导入链接库") { importFromSettings(.library) }
                    }
                }
                Section("编辑器") { Toggle("预测补全", isOn: $predictCompletion) }
                Section("LLVM 混淆") {
                    Picker("模式", selection: $obfuscation) {
                        ForEach(ObfuscationMode.allCases) { Text($0.title).tag($0) }
                    }
                    if obfuscation != .off {
                        if obfuscation == .ollvm || obfuscation == .plugin {
                            Button(obfuscation == .ollvm ? "导入 OLLVM Clang" : "导入 LLVM 17 Pass") {
                                importFromSettings(obfuscation == .ollvm ? .ollvm : .pass)
                            }
                        }
                        if obfuscation.usesOLLVMOptions {
                            Toggle("控制流平坦化 · -fla", isOn: $flatten)
                            Toggle("指令替换 · -sub", isOn: $substitute)
                            Toggle("虚假控制流 · -bcf", isOn: $bogus)
                        }
                        TextEditor(text: $parameters)
                            .font(.body.monospaced()).frame(minHeight: 85)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                            .accessibilityLabel("每行一个 LLVM 参数")
                    }
                }
                Section("环境") {
                    Text(environmentText.isEmpty ? "点「检查环境」查看构建环境状态" : environmentText)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Button("检查环境") { refreshEnvironment() }
                    Button("重建构建环境", role: .destructive) {
                        buildSettings = false
                        run("正在重建构建环境…") { _ in
                            try Self.runtime.rebuildEnvironment()
                            return (try Self.runtime.installedSDKs(), [], nil)
                        }
                    }
                }
            }
            .navigationTitle("构建设置")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { buildSettings = false } } }
        }.navigationViewStyle(.stack)
    }

    private func importFromSettings(_ kind: ImportKind) {
        importAfterSettings = kind
        buildSettings = false
    }

    private var explorer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("查找文件", text: $fileSearch).autocorrectionDisabled()
                Button { perform { if let project { tree = try ProjectEntry.read(project) } } } label: {
                    Image(systemName: "arrow.clockwise")
                }.accessibilityLabel("刷新文件树")
            }.padding(.horizontal, 12).padding(.top, 10)
            if fileSearch.isEmpty {
                List(tree, children: \.children) { entry in
                    if entry.children != nil {
                        Label(entry.name, systemImage: "folder")
                    } else {
                        fileButton(entry.path, title: entry.name)
                    }
                }.listStyle(.plain)
            } else {
                List(files.filter { $0.localizedCaseInsensitiveContains(fileSearch) }, id: \.self) { path in
                    fileButton(path, title: path)
                }.listStyle(.plain)
            }
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .disabled(busy)
    }

    private func fileButton(_ path: String, title: String) -> some View {
        Button {
            perform { try openFile(path); browser = false }
        } label: {
            Label(title, systemImage: ProjectImage.supports(path) ? "photo" :
                    BuildOptions.isLibrary(path) ? "shippingbox" : (sourcePath == path ? "doc.text.fill" : "doc.text"))
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.plain)
            .foregroundStyle(sourcePath == path ? Color.accentColor : .primary)
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(tabs, id: \.self) { path in
                    HStack(spacing: 8) {
                        Button {
                            perform { try openFile(path) }
                        } label: {
                            Text((path as NSString).lastPathComponent + (path == sourcePath && source != saved ? " •" : ""))
                                .foregroundStyle(path == sourcePath ? Color.accentColor : .secondary)
                        }.accessibilityHint(path)
                        Button { perform { try closeTab(path) } } label: {
                            Image(systemName: "xmark").font(.caption2)
                        }.accessibilityLabel("关闭 \(path)")
                    }
                    .padding(.vertical, 9).padding(.horizontal, 12)
                    .background(path == sourcePath ? Color(uiColor: .systemBackground) : .clear)
                    Divider()
                }
            }.fixedSize()
        }.background(Color(uiColor: .secondarySystemBackground))
            .disabled(busy)
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Button {
                endEditing()
                panel = panel == .issues ? nil : .issues
            } label: {
                Label("\(issues.filter(\.isError).count)", systemImage: "exclamationmark.octagon")
            }.accessibilityLabel("诊断")
            Button {
                endEditing()
                panel = panel == .log ? nil : .log
            } label: {
                Image(systemName: "terminal")
            }.accessibilityLabel("构建日志")
            if busy { ProgressView().controlSize(.small) }
            Text(status).lineLimit(1).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if !outputs.isEmpty {
                Menu("产物") {
                    ForEach(outputs, id: \.self) { url in
                        Button(url.lastPathComponent) { share = ShareItem(url: url) }
                    }
                }
            }
            if project != nil {
                Button { buildSettings = true } label: {
                    Text("\(configuration.rawValue) · iOS \(projectDeployment ?? deployment)").monospacedDigit()
                }
                .accessibilityLabel("构建配置和最低 iOS 版本")
                .accessibilityValue("\(configuration.rawValue) · iOS \(projectDeployment ?? deployment)")
                .accessibilityIdentifier("active-build-settings")
                .disabled(busy)
                Button { perform { try saveFile() } } label: { Image(systemName: "square.and.arrow.down") }
                    .disabled(busy || source == saved).accessibilityLabel("保存")
            }
        }.font(.footnote).padding(.horizontal, 12).padding(.vertical, 9)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    @ViewBuilder
    private func outputPanel(_ selected: BottomPanel) -> some View {
        if selected == .log {
            ScrollViewReader { scroll in
                ScrollView {
                    Text(log.isEmpty ? "暂无构建日志" : log)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    Color.clear.frame(height: 1).id("log-end")
                }
                .onChange(of: log) { _ in if busy { scroll.scrollTo("log-end", anchor: .bottom) } }
            }.frame(height: 175)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if issues.isEmpty { Text("暂无诊断").foregroundStyle(.secondary) }
                    ForEach(issues) { issue in
                        Button {
                            perform {
                                if let path = issue.path, let line = issue.line {
                                    try openFile(path)
                                    location = EditorLocation(line: line, column: issue.column ?? 1)
                                }
                            }
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: issue.isError ? "xmark.circle.fill" : "exclamationmark.triangle")
                                    .foregroundStyle(issue.isError ? Color.red : .orange)
                                VStack(alignment: .leading) {
                                    Text(issue.message).foregroundStyle(.primary)
                                    if let path = issue.path, let line = issue.line {
                                        Text("\(path):\(line):\(issue.column ?? 1)").foregroundStyle(.secondary)
                                    }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain).disabled(issue.path == nil || busy)
                    }
                }.font(.caption).padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 175)
        }
    }

    private var sdkOptions: [String] {
        Set(sdks + TheosRuntime.recentSDKs + Array(SDKDownload.catalog.keys) + [sdk]).sorted {
            $0.compare($1, options: .numeric) == .orderedAscending
        }
    }

    private func sdkTitle(_ version: String) -> String {
        if sdks.contains(version) { return version }
        if TheosRuntime.bundledSDKs.contains(version) { return "\(version) · 内嵌" }
        if SDKDownload.catalog[version] != nil { return "\(version) · 可下载" }
        return "\(version) · 本地导入"
    }

    private var canPrepareSelectedSDK: Bool {
        sdks.contains(sdk) || TheosRuntime.bundledSDKs.contains(sdk) || SDKDownload.catalog[sdk] != nil
    }

    private func documents() throws -> URL {
        try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
            .resolvingSymlinksInPath().standardizedFileURL
    }

    private func relativeProjectPath(_ url: URL, in documents: URL) -> String? {
        let path = url.path
        if path == documents.path { return "." }
        let prefix = documents.path + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    private func refreshProjects() throws {
        projects = try ProjectImport.findProjects(in: documents())
    }

    private func beginImport(_ kind: ImportKind, viaHub: Bool = false) {
        endEditing()
        if kind == .project && !viaHub {
            showImportHub = true
            return
        }
        importKind = kind
        showFilePicker = true
    }

    private func finishImport(_ selection: FolderPicker.Selection, kind: ImportKind) throws {
        switch kind {
        case .project: importProject(selection)
        case .sdk: importSDK(selection)
        case .ollvm, .pass: importObfuscator(selection, kind: kind)
        case .arm64eLinker: importARM64eLinker(selection)
        case .library: try importLibrary(selection.url)
        }
    }

    private func importProject(_ selection: FolderPicker.Selection) {
        importProject(at: selection.url, keeping: selection)
    }

    private func importProject(at url: URL, keeping scope: AnyObject? = nil) {
        perform {
            try saveFile()
            let root = try documents()
            let previousProjects = projects
            busy = true
            status = "正在导入项目…"
            Self.projectImportQueue.async {
                // Hold the security-scoped selection for the whole copy.
                let result = Result {
                    _ = scope
                    let imported = try ProjectImport.add(url, to: root)
                    let discovered = (try? ProjectImport.findProjects(in: root)) ?? previousProjects
                    let paths = Set(discovered.map(\.path))
                    return (imported, discovered + imported.filter { !paths.contains($0.path) })
                }
                DispatchQueue.main.async {
                    busy = false
                    perform {
                        let (imported, available) = try result.get()
                        projects = available
                        if imported.count == 1, let first = imported.first {
                            try openProject(first)
                        } else {
                            status = "已添加 \(imported.count) 个项目"
                            projectChoices = ProjectChoices(urls: imported, documents: root)
                        }
                    }
                }
            }
        }
    }

    private func openProject(_ url: URL) throws {
        try saveFile()
        let root = url.resolvingSymlinksInPath().standardizedFileURL
        let entries = try ProjectEntry.read(root)
        project = root
        tree = entries
        tabs = []
        fileSearch = ""
        sourcePath = nil
        source = ""
        saved = ""
        image = nil
        linkedLibraries = []
        outputs = []
        issues = []
        log = ""
        panel = nil
        if let first = ProjectImport.makefiles.first(where: { files.contains($0) }) {
            try openFile(first)
        }
        projectDeployment = BuildOptions.deployment(in: source)
        if let path = relativeProjectPath(root, in: try documents()) {
            activeProjectPath = path
        }
        status = "项目已打开"
    }

    private func openFile(_ path: String) throws {
        guard path != sourcePath else { return }
        try saveFile()
        endEditing()
        guard let project else { return }
        let url = try sourceURL(path, in: project)
        let picture = ProjectImage.supports(path) ? try ProjectImage.load(url) : nil
        let document = picture == nil ? try SourceDocument.load(url) : nil
        if !tabs.contains(path) { tabs.append(path) }
        sourcePath = path
        location = nil
        image = picture
        source = document?.text ?? ""
        saved = source
        encoding = document?.encoding ?? .utf8
        status = path
    }

    private func sourceURL(_ path: String, in project: URL) throws -> URL {
        let root = project.resolvingSymlinksInPath().standardizedFileURL
        let url = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else {
            throw WorkspaceError.message("文件位于项目目录之外。")
        }
        return url
    }

    private func closeTab(_ path: String) throws {
        if sourcePath == path {
            try saveFile()
            if let next = tabs.last(where: { $0 != path }) {
                try openFile(next)
            } else {
                sourcePath = nil
                source = ""
                saved = ""
                image = nil
            }
        }
        tabs.removeAll { $0 == path }
    }

    private func saveFile() throws {
        guard image == nil, let project, let sourcePath, source != saved else { return }
        try source.write(to: sourceURL(sourcePath, in: project), atomically: true, encoding: encoding)
        saved = source
        status = "已保存 \(sourcePath)"
    }

    /// Points the picker at an SDK that actually exists in the environment, so the
    /// first build does not fail because the stored selection is still download-only.
    private func refreshEnvironment() {
        environmentText = "正在检查…"
        Self.queue.async {
            let report = Self.runtime.environmentReport()
            DispatchQueue.main.async { environmentText = report }
        }
    }

    private func adoptInstalledSDK(_ versions: [String]) {
        guard !versions.isEmpty, !versions.contains(sdk) else { return }
        sdk = versions.max { $0.compare($1, options: .numeric) == .orderedAscending } ?? versions[0]
    }

    private func prepareSDK() {
        let version = sdk
        run("正在准备 SDK \(version)…") { report in
            try Self.runtime.install(version, log: report)
            return (try Self.runtime.installedSDKs(), [], nil)
        }
    }

    private func importSDK(_ selection: FolderPicker.Selection) {
        run("正在导入 SDK…") { report in
            let version = try Self.runtime.importSDK(selection.url, log: report)
            return (try Self.runtime.installedSDKs(), [], version)
        }
    }

    private func importObfuscator(_ selection: FolderPicker.Selection, kind: ImportKind) {
        run("正在导入混淆工具…") { report in
            try Self.runtime.importObfuscator(selection.url, mode: kind == .ollvm ? .ollvm : .plugin, log: report)
            return (try Self.runtime.installedSDKs(), [], nil)
        }
    }

    private func importLibrary(_ url: URL) throws {
        guard let project, BuildOptions.isLibrary(url.path) else {
            throw WorkspaceError.message("请选择 .a、.dylib 或 .tbd 文件。")
        }
        let relative = "Libraries/" + url.lastPathComponent
        let destination = try sourceURL(relative, in: project)
        let files = FileManager.default
        if files.fileExists(atPath: destination.path) {
            guard url.standardizedFileURL == destination.standardizedFileURL else {
                throw WorkspaceError.message("项目的 Libraries 目录已包含同名文件。")
            }
        } else {
            try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files.copyItem(at: url, to: destination)
        }
        tree = try ProjectEntry.read(project)
        linkedLibraries.insert(relative)
        status = "已添加 \(url.lastPathComponent)"
    }

    private func importARM64eLinker(_ selection: FolderPicker.Selection) {
        run("正在导入链接器…") { report in
            try Self.runtime.importARM64eLinker(selection.url, log: report)
            return (try Self.runtime.installedSDKs(), [], nil)
        }
    }

    private func build() {
        endEditing()
        perform {
            try saveFile()
            guard let project else { return }
            let version = sdk
            let minimum = projectDeployment ?? deployment
            let selectedFormat = format
            let options = BuildOptions(configuration: configuration, architecture: architecture,
                                       libraries: linkedLibraries.sorted(),
                                       obfuscation: obfuscation, flatten: flatten, substitute: substitute,
                                       bogus: bogus, parameters: parameters)
            outputs = []
            run("正在构建，请保持 App 在前台…") { report in
                let directory = try Self.runtime.build(project, sdk: version, deployment: minimum,
                                                       format: selectedFormat, options: options, log: report)
                let scan = FileManager.default.enumerator(at: directory,
                                                           includingPropertiesForKeys: [.isRegularFileKey])
                let artifacts = (scan?.allObjects as? [URL] ?? []).filter {
                    ["dylib", "deb", "a", "ipa", "tar"].contains($0.pathExtension) &&
                    (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                }
                return (try Self.runtime.installedSDKs(), artifacts, nil)
            }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() }
        catch { status = error.localizedDescription; openError = status }
    }

    private func run(_ title: String,
                     _ task: @escaping (@escaping (String) -> Void) throws -> ([String], [URL], String?)) {
        busy = true
        status = title
        log = ""
        issues = []
        panel = .log
        let projectFiles = Set(files)
        Self.queue.async {
            let result = Result {
                try task { chunk in
                    DispatchQueue.main.async {
                        log += chunk
                        if log.utf8.count > 180_000 { log = String(log.suffix(40_000)) }
                    }
                }
            }
            DispatchQueue.main.async {
                busy = false
                issues = BuildIssue.read(log, projectFiles: projectFiles)
                switch result {
                case .success(let (versions, artifacts, chosen)):
                    sdks = versions
                    if let chosen { sdk = chosen } else { adoptInstalledSDK(versions) }
                    if !artifacts.isEmpty { outputs = artifacts }
                    status = artifacts.isEmpty ? "操作完成" : "构建完成"
                case .failure(let error):
                    status = error.localizedDescription
                    if !issues.isEmpty { panel = .issues }
                }
            }
        }
    }
}

private struct ProjectImage {
    let image: UIImage
    let width: Int
    let height: Int

    static func supports(_ path: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp", "ico"]
            .contains((path as NSString).pathExtension.lowercased())
    }

    static func load(_ url: URL) throws -> Self {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let preview = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048
              ] as CFDictionary) else {
            throw WorkspaceError.message("无法预览这张图片。")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? preview.width
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? preview.height
        return Self(image: UIImage(cgImage: preview), width: width, height: height)
    }
}

private struct ImagePreview: View {
    let image: ProjectImage
    @State private var zoom = 1.0

    var body: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                Image(uiImage: image.image)
                    .resizable().scaledToFit()
                    .frame(width: max(1, geometry.size.width * zoom - 32),
                           height: max(1, geometry.size.height * zoom - 32))
                    .padding(16)
                    .accessibilityLabel("图片预览")
                    .onTapGesture(count: 2) { zoom = zoom == 1 ? 2 : 1 }
            }
            .background(Color(uiColor: .secondarySystemBackground))
        }
        .overlay(alignment: .bottomTrailing) {
            HStack {
                Button { zoom = max(1, zoom - 0.5) } label: { Image(systemName: "minus.magnifyingglass") }
                    .accessibilityLabel("缩小图片")
                Button { zoom = 1 } label: { Text("\(Int(zoom * 100))%").monospacedDigit() }
                    .accessibilityLabel("适应窗口")
                Button { zoom = min(4, zoom + 0.5) } label: { Image(systemName: "plus.magnifyingglass") }
                    .accessibilityLabel("放大图片")
            }.padding(8).background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 6)).padding(8)
        }
    }
}

private struct ShareItem: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
