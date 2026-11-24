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
    private let kernel = IshInstance.shared
    private let environment = [
        "PATH": "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": "/root", "THEOS": "/opt/theos", "LC_ALL": "C.UTF-8", "TMPDIR": "/tmp"
    ]

    /// Bump whenever the embedded image changes (new SDK, new toolchain package).
    /// Installs left over from an older build are dropped and re-copied once.
    private static let environmentVersion = 2
    private static let environmentKey = "theoslab.environmentVersion"
    private static let bootLock = NSLock()

    func boot() throws {
        Self.bootLock.lock()
        defer { Self.bootLock.unlock() }
        if kernel.isRunning { return }
        let files = FileManager.default
        let support = try files.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
        let legacy = support.appendingPathComponent("Alpine-0.3.3")
        let bundledRoot = support.appendingPathComponent("Alpine-Offline-1")
        let legacyTools = ["opt/.theoslab-ready", "opt/theos/makefiles/common.mk",
                           "usr/bin/clang", "usr/bin/ld64.lld", "usr/bin/zip", "usr/local/bin/ldid"]
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Guest/fs")
        let bundledReady: Bool = {
            guard let bundled,
                  files.fileExists(atPath: bundled.appendingPathComponent("meta.db").path) else { return false }
            return legacyTools.allSatisfy {
                files.fileExists(atPath: bundled.appendingPathComponent("data/" + $0).path)
            }
        }()
        if bundledReady, UserDefaults.standard.integer(forKey: Self.environmentKey) < Self.environmentVersion {
            // A rootfs extracted by an older build stays in the container forever, so the
            // SDKs shipped with this build would never appear. Replace it once.
            for stale in [legacy, bundledRoot] where files.fileExists(atPath: stale.path) {
                try? files.removeItem(at: stale)
            }
        }
        var root = legacyTools.allSatisfy { files.fileExists(atPath: legacy.appendingPathComponent("data/" + $0).path) }
            ? legacy : bundledRoot
        if !files.fileExists(atPath: root.path) {
            guard let bundled, bundledReady else {
                throw WorkspaceError.message("安装包缺少内嵌的 Theos 构建环境。")
            }
            let staging = support.appendingPathComponent(UUID().uuidString)
            defer { try? files.removeItem(at: staging) }
            try files.copyItem(at: bundled, to: staging)
            try files.moveItem(at: staging, to: root)
        }
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try? root.setResourceValues(resources)
        UserDefaults.standard.set(Self.environmentVersion, forKey: Self.environmentKey)
        try kernel.boot(.init(rootfsPath: root.path))
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
        if format != .deb {
            try stream(make + ["all"], cwd: guest, extraEnvironment: compilerEnvironment, log: log)
        }
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
