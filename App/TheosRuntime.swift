//
// TheosRuntime.swift
// Ain
//
// Created by Ain on 2026/11/20.
//

import Foundation
import CryptoKit
import IshEmbed

enum BuildFormat: String, CaseIterable, Identifiable {
    case automatic, ipa, dylib, deb
    var id: Self { self }

    var title: String {
        self == .automatic ? "自动识别" : ".\(rawValue)"
    }
}

final class TheosRuntime: @unchecked Sendable {
    /// Shared instance for the console; the workspace keeps its own, both talk to the same kernel.
    static let shared = TheosRuntime()
    private let kernel = IshInstance.shared
    private let environment = [
        "PATH": "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": "/root", "THEOS": "/opt/theos", "LC_ALL": "C.UTF-8", "TMPDIR": "/tmp"
    ]

    /// Bump whenever the embedded image changes (new SDK, new toolchain package).
    /// Installs left over from an older build are dropped and re-copied once.
    private static let environmentVersion = 5
    private static let environmentKey = "theoslab.environmentVersion"
    static let bootLock = NSLock()
    private(set) static var lastBootError: String?

    /// Kept in `Documents` so it can be pulled out through the Files app when
    /// something goes wrong on device.
    static let logURL: URL? = {
        guard let documents = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                           appropriateFor: nil, create: true) else { return nil }
        return documents.appendingPathComponent("theoslab-boot.log")
    }()

    static func note(_ text: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        print("[theoslab] \(stamp) \(text)")
        guard let logURL else { return }
        let line = stamp + " " + text + "\n"
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: logURL)
        }
    }

    func boot() throws {
        Self.bootLock.lock()
        defer { Self.bootLock.unlock() }
        if kernel.isRunning { return }
        do {
            try start()
            Self.lastBootError = nil
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            Self.lastBootError = text
            Self.note("boot failed: \(text)")
            throw error
        }
    }

    private func start() throws {
        let files = FileManager.default
        let support = try files.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
        let legacy = support.appendingPathComponent("Alpine-0.3.3")
        let bundledRoot = support.appendingPathComponent("Alpine-Offline-1")
        // `/sbin/ishsv` is the PID-1 supervisor the kernel execve's; without it the
        // embedded Linux never starts and boot only reports a generic error.
        let tools = ["sbin/ishsv", "opt/.theoslab-ready", "opt/theos/makefiles/common.mk",
                     "usr/bin/clang", "usr/bin/ld64.lld", "usr/bin/zip", "usr/local/bin/ldid"]
        func ready(_ root: URL) -> Bool {
            files.fileExists(atPath: root.appendingPathComponent("meta.db").path)
                && tools.allSatisfy { files.fileExists(atPath: root.appendingPathComponent("data/" + $0).path) }
        }

        let resources = Bundle.main.resourceURL
        let bundledTree = resources?.appendingPathComponent("Guest/fs")
        // The environment ships packed: ~19k loose files would be re-hashed by every
        // code-signing pass, so the bundle only carries one archive.
        let candidates = [resources?.appendingPathComponent("Guest/fs.tar"),
                          (try? files.url(for: .documentDirectory, in: .userDomainMask,
                                          appropriateFor: nil, create: false))?
                            .appendingPathComponent("rootfs.tar")]
        let archive = candidates.compactMap { $0 }.first { files.fileExists(atPath: $0.path) }
        let treeReady = bundledTree.map(ready) ?? false
        let hasSource = treeReady || archive != nil

        Self.note("launch · tree=\(treeReady) · archive=\(archive?.lastPathComponent ?? "无") · storedVersion=\(UserDefaults.standard.integer(forKey: Self.environmentKey)) · free=\(Self.freeSpace(support))")

        if hasSource, UserDefaults.standard.integer(forKey: Self.environmentKey) < Self.environmentVersion {
            // A rootfs extracted by an older build stays in the container forever, so the
            // SDKs shipped with this build would never appear. Replace it once.
            for stale in [legacy, bundledRoot] where files.fileExists(atPath: stale.path) {
                try? files.removeItem(at: stale)
                Self.note("removed stale rootfs \(stale.lastPathComponent)")
            }
        }

        var root = ready(legacy) ? legacy : bundledRoot
        if !ready(root) {
            guard hasSource else {
                throw WorkspaceError.message("安装包缺少内嵌的 Theos 构建环境。")
            }
            if files.fileExists(atPath: root.path) {
                try? files.removeItem(at: root)
                Self.note("dropped incomplete rootfs")
            }
            try install(root: root, tree: treeReady ? bundledTree : nil, archive: archive, support: support)
            guard ready(root) else {
                try? files.removeItem(at: root)
                throw WorkspaceError.message("解压构建环境失败（环境不完整），请重试。")
            }
            Self.note("environment ready · free=\(Self.freeSpace(support))")
        }
        var resources2 = URLResourceValues()
        resources2.isExcludedFromBackup = true
        try? root.setResourceValues(resources2)
        try kernel.boot(.init(rootfsPath: root.path))
        UserDefaults.standard.set(Self.environmentVersion, forKey: Self.environmentKey)
        Self.note("kernel booted · \(root.lastPathComponent)")
    }

    /// Materialises the environment into `root`, either by copying a pre-extracted
    /// directory or by unpacking the bundled archive.
    private func install(root: URL, tree: URL?, archive: URL?, support: URL) throws {
        let files = FileManager.default
        var needed: Int64 = 0
        if let tree {
            needed = Self.directorySize(tree)
        } else if let archive {
            let size = (try? files.attributesOfItem(atPath: archive.path))?[.size] as? NSNumber
            needed = Int64(Double(size?.int64Value ?? 0) * 1.2)
        }
        if let free = Self.freeBytes(support), needed > 0, free < needed {
            throw WorkspaceError.message("存储空间不足：构建环境需要约 \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file))，当前可用 \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file))。清理后重新打开 App。")
        }

        let staging = support.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: staging) }
        try files.createDirectory(at: staging, withIntermediateDirectories: true)

        if let tree {
            Self.note("copying environment → \(root.lastPathComponent) · size=\(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file))")
            let temporary = staging.appendingPathComponent("tree")
            try files.copyItem(at: tree, to: temporary)
            try files.moveItem(at: temporary, to: root)
        } else if let archive {
            Self.note("unpacking \(archive.lastPathComponent) → \(root.lastPathComponent) · size=\(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file))")
            let count = try RootfsArchive.extract(archive, to: staging) { Self.note($0) }
            guard count > 0 else {
                throw WorkspaceError.message("构建环境归档为空，请重新安装 App。")
            }
            try files.moveItem(at: staging, to: root)
        } else {
            throw WorkspaceError.message("安装包缺少内嵌的 Theos 构建环境。")
        }
    }

    static func freeSpace(_ url: URL) -> String {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = values.volumeAvailableCapacityForImportantUsage else { return "未知" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func freeBytes(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    static func directorySize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys,
                                                           options: [], errorHandler: nil) {
            for case let child as URL in enumerator {
                guard let values = try? child.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true, let size = values.fileSize else { continue }
                total += Int64(size)
            }
        }
        return total
    }

    /// Plain-text state of the on-disk environment, shown in build settings.
    func environmentReport() -> String {
        let files = FileManager.default
        var lines: [String] = []
        guard let support = try? files.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                           appropriateFor: nil, create: true) else { return "无法访问应用容器" }
        lines.append("环境版本 \(UserDefaults.standard.integer(forKey: Self.environmentKey)) / 期望 \(Self.environmentVersion)")
        for name in ["Alpine-Offline-1", "Alpine-0.3.3"] {
            let root = support.appendingPathComponent(name)
            let exists = files.fileExists(atPath: root.appendingPathComponent("meta.db").path)
            lines.append("\(name)：\(exists ? "已就绪" : "不存在")")
        }
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("Guest/fs.tar")
        if let packaged, let size = (try? files.attributesOfItem(atPath: packaged.path))?[.size] as? NSNumber {
            lines.append("内嵌归档：\(ByteCountFormatter.string(fromByteCount: size.int64Value, countStyle: .file))")
        } else {
            lines.append("内嵌归档：无")
        }
        if kernel.isRunning {
            lines.append("Linux 内核：运行中")
            let listing = (try? capture(["/bin/ls", "/opt/theos/sdks"])) ?? Data()
            let names = String(decoding: listing, as: UTF8.self).split(separator: "\n")
                .filter { $0.hasPrefix("iPhoneOS") && $0.hasSuffix(".sdk") }
                .map { String($0.dropFirst("iPhoneOS".count).dropLast(".sdk".count)) }
            lines.append("已安装 SDK：\(names.isEmpty ? "无" : names.joined(separator: "、"))")
        } else {
            lines.append("Linux 内核：未运行")
        }
        lines.append("剩余空间：\(Self.freeSpace(support))")
        if let error = Self.lastBootError { lines.append("最近错误：\(error)") }
        return lines.joined(separator: "\n")
    }

    /// Drops the extracted environment so the next boot re-copies the bundled one.
    func rebuildEnvironment() throws {
        if kernel.isRunning { try? kernel.shutdown(graceMs: 2_000) }
        let files = FileManager.default
        let support = try files.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
        for name in ["Alpine-Offline-1", "Alpine-0.3.3"] {
            let root = support.appendingPathComponent(name)
            if files.fileExists(atPath: root.path) { try files.removeItem(at: root) }
        }
        UserDefaults.standard.set(0, forKey: Self.environmentKey)
        Self.note("environment reset requested")
        try boot()
    }

    func installedSDKs() throws -> [String] {
        try boot()
        let result = try capture(["/bin/sh", "-c", """
            for sdk in /opt/theos/sdks/iPhoneOS*.sdk; do
                [ -d "$sdk" ] || continue
                name=${sdk##*/}
                name=${name#iPhoneOS}
                printf '%s\n' "${name%.sdk}"
            done
            """])
        return String(decoding: result, as: UTF8.self).split(separator: "\n").map(String.init)
            .filter(Self.isVersion).sorted { $0.compare($1, options: .numeric) == .orderedAscending }
    }

    static let recentSDKs = ["26.0", "27.0"]
    static let bundledSDKs = recentSDKs.filter { bundledSDK($0) != nil }

    private static func bundledSDK(_ version: String) -> URL? {
        guard let archive = Bundle.main.resourceURL?.appendingPathComponent("Guest/SDKs/iPhoneOS\(version).sdk.tar.gz"),
              FileManager.default.fileExists(atPath: archive.path) else { return nil }
        return archive
    }

    func install(_ sdk: String, log: @escaping (String) -> Void) throws {
        try boot()
        guard let script = Bundle.main.url(forResource: "bootstrap", withExtension: "sh") else {
            throw WorkspaceError.message("App 中缺少环境安装脚本。")
        }
        if !sdk.isEmpty, !((try installedSDKs()).contains(sdk)) {
            let name = "iPhoneOS\(sdk).sdk"
            let resource: URL
            var zip = false
            var downloaded = false
            if let bundled = Self.bundledSDK(sdk) {
                resource = bundled
                log("正在解包内嵌 SDK · \(sdk)\n")
            } else if let release = SDKDownload.catalog[sdk] {
                resource = try download(release, version: sdk, log: log)
                zip = release.isZip
                downloaded = true
                log("正在安装 SDK · \(sdk)\n")
            } else {
                throw WorkspaceError.message("请在构建设置导入 iPhoneOS\(sdk).sdk 文件夹。")
            }
            defer { if downloaded { try? FileManager.default.removeItem(at: resource) } }
            let parent = "/opt/theos/sdks"
            let temporary = parent + "/.install-" + UUID().uuidString
            _ = try capture(["/bin/mkdir", "-p", temporary])
            defer { _ = try? capture(["/bin/rm", "-rf", temporary]) }
            if zip {
                let archive = temporary + "/sdk.zip"
                try stream(["/bin/sh", "-c", "cat > \"$1\"", "sh", archive], input: resource, log: log)
                try stream(["/usr/bin/unzip", "-oq", archive, "-d", temporary], log: log)
            } else {
                try stream(["/bin/busybox", "tar", downloaded ? "-xJf" : "-xzf", "-", "-C", temporary],
                           input: resource, log: log)
            }
            _ = try capture(["/bin/sh", "-c", """
                test -f "$1/usr/lib/libSystem.tbd" && test -d "$1/usr/include"
                """, "sh", temporary + "/" + name])
            _ = try capture(["/bin/mv", temporary + "/" + name, parent + "/" + name])
        }
        try stream(["/bin/sh", "-s", "--", sdk], input: script, log: log)
    }

    private func download(_ release: SDKDownload, version: String,
                          log: @escaping (String) -> Void) throws -> URL {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let completion = DispatchSemaphore(value: 0)
        let result = SDKDownloadResult()
        log("正在下载 iPhoneOS \(version) SDK\n")
        session.downloadTask(with: release.url) { file, response, error in
            defer { completion.signal() }
            result.value = Result {
                if let error { throw error }
                guard (response as? HTTPURLResponse)?.statusCode == 200, let file else {
                    throw WorkspaceError.message("SDK 下载失败 · HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                }
                if let expected = release.sha256 {
                    let reader = try FileHandle(forReadingFrom: file)
                    defer { try? reader.close() }
                    var hash = SHA256()
                    while let bytes = try reader.read(upToCount: 1 << 20), !bytes.isEmpty {
                        hash.update(data: bytes)
                    }
                    let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
                    guard actual == expected else {
                        throw WorkspaceError.message("SDK 压缩包 SHA-256 校验失败。")
                    }
                }
                try FileManager.default.moveItem(at: file, to: destination)
                return destination
            }
        }.resume()
        completion.wait()
        return try result.value.get()
    }

    func importObfuscator(_ source: URL, mode: ObfuscationMode, log: @escaping (String) -> Void) throws {
        let isDriver = mode == .ollvm
        try installELF(source, name: isDriver ? "ollvm-clang" : "ollvm-pass.so",
                       executable: isDriver, log: log)
        log("已导入 \(mode.title)\n")
    }

    func importARM64eLinker(_ source: URL, log: @escaping (String) -> Void) throws {
        try installELF(source, name: "arm64e-ld", executable: true, log: log)
        log("已导入 arm64e 链接器\n")
    }

    private func installELF(_ source: URL, name: String, executable: Bool,
                            log: @escaping (String) -> Void) throws {
        try boot()
        let elf = try FileHandle(forReadingFrom: source)
        defer { try? elf.close() }
        guard let header = try elf.read(upToCount: 20), header.count == 20,
              Array(header.prefix(6)) == [0x7f, 0x45, 0x4c, 0x46, 2, 1],
              header[18] == 183, header[19] == 0 else {
            throw WorkspaceError.message("请选择 Linux ARM64 ELF 文件。")
        }
        let directory = "/opt/theoslab-tools"
        let staged = directory + "/" + UUID().uuidString
        _ = try capture(["/bin/mkdir", "-p", directory])
        defer { _ = try? capture(["/bin/rm", "-f", staged]) }
        try stream(["/bin/sh", "-c", "cat > \"$1\"", "sh", staged], input: source, log: log)
        if executable {
            _ = try capture(["/bin/chmod", "755", staged])
        }
        _ = try capture(["/bin/busybox", "mv", "-f", staged, directory + "/" + name])
    }

    func importSDK(_ source: URL, log: @escaping (String) -> Void) throws -> String {
        let name = source.lastPathComponent
        guard name.hasPrefix("iPhoneOS"), name.hasSuffix(".sdk") else {
            throw WorkspaceError.message("请选择 iPhoneOS版本.sdk 文件夹。")
        }
        let version = String(name.dropFirst(8).dropLast(4))
        guard Self.isVersion(version),
              FileManager.default.fileExists(atPath: source.appendingPathComponent("usr/include").path),
              FileManager.default.fileExists(atPath: source.appendingPathComponent("usr/lib/libSystem.tbd").path) else {
            throw WorkspaceError.message("SDK 缺少版本、头文件或链接描述文件。")
        }
        try install("", log: log)
        guard try !installedSDKs().contains(version) else {
            throw WorkspaceError.message("这个 SDK 版本已经安装。")
        }
        let guestStage = "/opt/theos/sdks/.import-" + UUID().uuidString
        _ = try capture(["/bin/mkdir", "-p", guestStage])
        defer { _ = try? capture(["/bin/rm", "-rf", guestStage]) }
        try transfer(source, omittingBuildFiles: false, guest: guestStage, log: log)
        // LLD 17 doesn't recognize this target spelling in recent SDK stubs.
        try stream(["/usr/bin/find", guestStage, "-type", "f", "-name", "*.tbd", "-exec",
                    "/usr/bin/perl", "-pi", "-e",
                    #"s/,\h*arm64e\.x1-ios(?=\s*[,\]])//g; s/arm64e\.x1-ios\h*,\h*//g"#,
                    "{}", "+"], log: log)
        _ = try capture(["/bin/mv", guestStage, "/opt/theos/sdks/" + name])
        return version
    }

    func build(_ project: URL, sdk: String, deployment: String, format: BuildFormat, options: BuildOptions = .init(),
               log: @escaping (String) -> Void) throws -> URL {
        try boot()
        guard Self.isVersion(sdk), Self.isVersion(deployment),
              deployment.compare(sdk, options: .numeric) != .orderedDescending else {
            throw WorkspaceError.message("最低系统版本必须小于或等于所选 SDK。")
        }
        if options.architecture.requiresARM64e,
           deployment.compare("14.0", options: .numeric) == .orderedAscending {
            throw WorkspaceError.message("此工具链的 arm64e 需要将最低系统版本设为 iOS 14.0 或以上。")
        }
        if options.architecture.requiresARM64e {
            do { _ = try capture(["/bin/busybox", "test", "-x", "/opt/theoslab-tools/arm64e-ld"]) }
            catch { throw WorkspaceError.message("请先在构建设置导入支持 arm64e 的 Mach-O 链接器。") }
        }
        try install(sdk, log: log)
        let guest = "/tmp/theoslab-" + UUID().uuidString
        _ = try capture(["/bin/mkdir", "-p", guest])
        defer { _ = try? capture(["/bin/rm", "-rf", guest]) }
        try transfer(project, omittingBuildFiles: true, guest: guest, log: log)
        var make = ["/usr/bin/make", "-j1", "COLOR=0", "THEOS=/opt/theos", "TARGET=iphone:clang:\(sdk):\(deployment)",
                    options.configuration.makeArgument]
        if let architecture = options.architecture.makeArgument { make.append(architecture) }
        var compilerEnvironment: [String: String] = [:]
        if !options.libraries.isEmpty {
            let paths = try options.libraries.map { relative in
                guard BuildOptions.isLibrary(relative), !relative.hasPrefix("/"),
                      !relative.split(separator: "/").contains(where: { $0 == ".." }) else {
                    throw WorkspaceError.message("链接库必须位于项目目录中。")
                }
                let path = guest + "/" + relative
                do { _ = try capture(["/bin/busybox", "test", "-f", path]) }
                catch { throw WorkspaceError.message("找不到链接库 · \(relative)") }
                return path
            }
            let response = guest + "/.theoslab-libraries.rsp"
            try writeResponse(paths, to: response)
            compilerEnvironment["THEOSLAB_LINK_LIBRARIES"] = response
            log("链接库 · \(options.libraries.joined(separator: ", "))\n")
        }
        if options.obfuscation != .off {
            var bundledPass: String?
            if options.obfuscation == .builtIn {
                let pass = Bundle.main.resourceURL?.appendingPathComponent("Guest/Toolchain/ollvm.so")
                guard let pass, FileManager.default.fileExists(atPath: pass.path) else {
                    throw WorkspaceError.message("安装包缺少内嵌 OLLVM。")
                }
                let path = guest + "/.theoslab-ollvm-\(UUID().uuidString).so"
                try stream(["/bin/sh", "-c", "cat > \"$1\"", "sh", path], input: pass, log: log)
                bundledPass = path
            } else {
                let path = options.obfuscation == .ollvm ? "ollvm-clang" : "ollvm-pass.so"
                do {
                    _ = try capture(["/bin/busybox", "test", "-f", "/opt/theoslab-tools/" + path])
                } catch {
                    throw WorkspaceError.message("请先在构建设置导入 \(options.obfuscation.title)。")
                }
            }
            let arguments = try options.compilerArguments(bundledPass: bundledPass)
            let argfile = guest + "/.theoslab-compiler.rsp"
            try writeResponse(arguments, to: argfile)
            compilerEnvironment["THEOSLAB_OBFUSCATION"] = options.obfuscation.rawValue
            compilerEnvironment["THEOSLAB_COMPILER_ARGS"] = argfile
            log("混淆 · \(options.obfuscation.title) \(arguments.joined(separator: " "))\n")
        }
        log("GNU Make · \(options.configuration.rawValue) · \(options.architecture.title) · iPhoneOS \(sdk) · 最低 iOS \(deployment) · \(format.title)\n")
        // Do not build here: artifacts.sh runs `all` for the formats that need
        // it and `package` (which implies all) for deb. Building twice in one
        // obj directory makes Theos sign-and-rename over an existing dylib,
        // which iSH's fakefs rejects with "mv: Not a directory".
        guard let artifactScript = Bundle.main.url(forResource: "artifacts", withExtension: "sh") else {
            throw WorkspaceError.message("App 中缺少产物打包脚本。")
        }
        let artifactDirectory = "/tmp/theoslab-artifacts-" + UUID().uuidString
        defer { _ = try? capture(["/bin/rm", "-rf", artifactDirectory]) }
        let args = ["/bin/sh", "-s", "--", format.rawValue, artifactDirectory] + Array(make.dropFirst())
        try stream(args, cwd: guest, input: artifactScript, extraEnvironment: compilerEnvironment, log: log)
        let files = FileManager.default
        let documents = try files.url(for: .documentDirectory, in: .userDomainMask,
                                      appropriateFor: nil, create: true)
        let output = documents.appendingPathComponent("Builds").appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: output, withIntermediateDirectories: true)
        var complete = false
        defer { if !complete { try? files.removeItem(at: output) } }
        let matches = try capture(["/usr/bin/find", artifactDirectory, "-maxdepth", "1", "-type", "f", "-print0"])
        for path in String(decoding: matches, as: UTF8.self).split(separator: "\0") {
            let filename = URL(fileURLWithPath: String(path)).lastPathComponent
            try stream(["/bin/cat", String(path)], output: output.appendingPathComponent(filename), log: log)
        }
        complete = true
        return output
    }

    static func isVersion(_ value: String) -> Bool {
        value.range(of: #"^[0-9]+(\.[0-9]+){0,2}$"#, options: .regularExpression) != nil
    }

    // MARK: - Console helpers

    /// Runs a script and returns its stdout, throwing the guest's stderr on failure.
    func shell(_ script: String, cwd: String? = nil) throws -> String {
        try boot()
        return String(decoding: try capture(["/bin/sh", "-c", script], cwd: cwd), as: UTF8.self)
    }

    /// Copies a host project into the guest so it can be built from the console.
    func stage(_ project: URL, at guest: String, log: @escaping (String) -> Void) throws {
        try boot()
        _ = try capture(["/bin/mkdir", "-p", guest])
        try transfer(project, omittingBuildFiles: true, guest: guest, log: log)
    }

    /// Packs a guest directory back into the app's container.
    @discardableResult
    func export(_ guest: String, to host: URL) throws -> URL {
        let files = FileManager.default
        let archive = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: archive) }
        try stream(["/bin/busybox", "tar", "-cf", "-", "-C", guest, "."], output: archive, log: { _ in })
        let parent = host.deletingLastPathComponent()
        try files.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".export-" + String(UUID().uuidString.prefix(8)))
        defer { try? files.removeItem(at: staging) }
        _ = try RootfsArchive.extract(archive, to: staging)
        if files.fileExists(atPath: host.path) { try files.removeItem(at: host) }
        try files.moveItem(at: staging, to: host)
        return host
    }

    /// Drives `$THEOS/bin/nic.pl` on a real pty, then copies the result into
    /// `Documents/Projects` so the workspace can open it.
    func createProject(template: String, name: String, package: String, author: String,
                       answers: [String], log: @escaping (String) -> Void) throws -> URL {
        try boot()
        let scratch = "/root/.nic-" + String(UUID().uuidString.prefix(8))
        _ = try capture(["/bin/mkdir", "-p", scratch])
        defer { _ = try? capture(["/bin/rm", "-rf", scratch]) }

        var environment = self.environment
        environment["TERM"] = "xterm-256color"
        let argv = ["/opt/theos/bin/nic.pl", "-t", template, "-n", name, "-p", package, "-u", author]
        let session = try kernel.spawn(.init(argv: argv, cwd: scratch, env: environment,
                                             allocateTTY: true, mergeStderrIntoStdout: true,
                                             initialWindowSize: (rows: 40, cols: 160, xpixel: 0, ypixel: 0)))
        defer { session.close() }
        // The pty queue holds these until nic.pl asks; empty lines accept the
        // template's defaults for any prompt we did not model in the form.
        var input = answers.map { $0 + "\n" }.joined()
        input += String(repeating: "\n", count: 12)
        try session.write(Data(input.utf8))

        while true {
            let event: IshSessionEvent
            do {
                event = try session.read(timeout: 180)
            } catch {
                try? session.interrupt()
                throw WorkspaceError.message("nic.pl 长时间没有响应，已中止。")
            }
            switch event {
            case .data(let bytes, _, _):
                log(TerminalText.decode(bytes))
            case .exited(let code, let signal):
                guard code == 0, signal == 0 else {
                    throw WorkspaceError.message("nic.pl 退出码 \(code) · 项目未创建。")
                }
                let listing = String(decoding: try capture(["/bin/busybox", "find", scratch,
                                                            "-mindepth", "1", "-maxdepth", "1", "-type", "d"]),
                                     as: UTF8.self)
                guard let created = listing.split(separator: "\n").map(String.init).first(where: { path in
                    (try? capture(["/bin/busybox", "test", "-f", path + "/Makefile"])) != nil
                }) else {
                    throw WorkspaceError.message("nic.pl 没有生成项目目录。")
                }
                let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                             appropriateFor: nil, create: true)
                // Never overwrite an existing project; nic.pl already picked a
                // unique directory inside the scratch area, so mirror that here.
                let folder = URL(fileURLWithPath: created).lastPathComponent
                let projects = documents.appendingPathComponent("Projects")
                var target = projects.appendingPathComponent(folder)
                var suffix = 2
                while FileManager.default.fileExists(atPath: target.path) {
                    target = projects.appendingPathComponent("\(folder)-\(suffix)")
                    suffix += 1
                }
                return try export(created, to: target)
            }
        }
    }

    private func writeResponse(_ arguments: [String], to path: String) throws {
        let quoted = arguments.map { arg in
            "\"" + arg.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        _ = try capture(["/bin/sh", "-c", "file=$1; shift; printf '%s\\n' \"$@\" > \"$file\"", "sh", path] + quoted)
    }

    private func transfer(_ source: URL, omittingBuildFiles: Bool, guest: String,
                          log: @escaping (String) -> Void) throws {
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: archive) }
        try ProjectArchive.write(source, omittingBuildFiles: omittingBuildFiles, to: archive)
        try stream(["/bin/busybox", "tar", "-xf", "-", "-C", guest], input: archive, log: log)
    }

    private func capture(_ argv: [String], cwd: String? = nil) throws -> Data {
        let result = try kernel.runOneshot(.init(argv: argv, cwd: cwd, env: environment, timeout: 30))
        guard result.exitCode == 0, result.signal == 0, !result.timedOut else {
            throw WorkspaceError.message(String(decoding: result.stderrData, as: UTF8.self))
        }
        return result.stdoutData
    }

    private func stream(_ argv: [String], cwd: String? = nil, input: URL? = nil, output: URL? = nil,
                        extraEnvironment: [String: String] = [:],
                        log: @escaping (String) -> Void) throws {
        let env = environment.merging(extraEnvironment) { _, value in value }
        let session = try kernel.spawn(.init(argv: argv, cwd: cwd, env: env))
        defer { session.close() }
        var writer: FileHandle?
        if let output {
            guard FileManager.default.createFile(atPath: output.path, contents: nil) else {
                throw WorkspaceError.message("无法保存构建产物。")
            }
            writer = try FileHandle(forWritingTo: output)
        }
        defer { try? writer?.close() }
        if let input {
            let reader = try FileHandle(forReadingFrom: input)
            defer { try? reader.close() }
            while let block = try reader.read(upToCount: 8192), !block.isEmpty {
                try session.write(block)
            }
        }
        try session.closeStdin()
        while true {
            switch try session.read(timeout: nil) {
            case .data(let bytes, let kind, _):
                if let writer, case .stdout = kind { try writer.write(contentsOf: bytes) }
                else { log(String(decoding: bytes, as: UTF8.self)) }
            case .exited(let code, let signal):
                guard code == 0, signal == 0 else {
                    throw WorkspaceError.message("命令失败 · \(argv[0]) · 退出码 \(code) · 信号 \(signal)")
                }
                return
            }
        }
    }
}

private final class SDKDownloadResult: @unchecked Sendable {
    var value: Result<URL, Error> = .failure(WorkspaceError.message("SDK 下载中断。"))
}
