//
// Terminal.swift
// Theos Lab
//
// A small stateful console over the embedded Linux box, plus the text helpers
// it needs. Commands run on a pty so prompts and progress arrive immediately,
// and `cd` is tracked here so the working directory survives between commands.
//

import Foundation
import IshEmbed

/// Strips ANSI control sequences and applies carriage returns / backspaces so
/// output reads like it does in a real terminal.
enum TerminalText {
    static func decode(_ data: Data) -> String {
        clean(String(decoding: data, as: UTF8.self))
    }

    static func clean(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { $0 == "\u{1B}" || $0 == "\r" || $0 == "\u{08}" }) else {
            return text.replacingOccurrences(of: "\u{0}", with: "")
        }
        var out = ""
        out.reserveCapacity(text.count)
        var state = 0  // 0 normal · 1 after ESC · 2 inside CSI · 3 inside OSC
        for scalar in text.unicodeScalars {
            switch state {
            case 0:
                if scalar == "\u{1B}" { state = 1; continue }
                if scalar == "\u{0}" { continue }
                if scalar == "\r" {
                    if let newline = out.lastIndex(of: "\n") {
                        out = String(out[...newline])
                    } else {
                        out = ""
                    }
                    continue
                }
                if scalar == "\u{08}" {
                    if !out.isEmpty { out.removeLast() }
                    continue
                }
                out.unicodeScalars.append(scalar)
            case 1:
                state = scalar == "[" ? 2 : (scalar == "]" ? 3 : 0)
            case 2:
                if scalar.value >= 0x40, scalar.value <= 0x7E { state = 0 }
            case 3:
                if scalar.value == 0x07 { state = 0 }
            default:
                state = 0
            }
        }
        return out
    }
}

final class TerminalModel: ObservableObject {
    @Published private(set) var text = ""
    @Published private(set) var running = false
    @Published private(set) var cwd = "/root"

    /// Fired on the main thread once nic.pl has produced a project in Documents.
    var onProjectCreated: ((URL) -> Void)?

    private let runtime = TheosRuntime.shared
    private let queue = DispatchQueue(label: "theoslab.terminal", qos: .userInitiated)
    private let lock = NSLock()
    private let sessionLock = NSLock()
    private var pending = ""
    private var draining = false
    private var job: IshSession?
    private var started = false
    private(set) var history: [String] = []
    private var historyIndex = 0

    /// `ARCHS` keeps the LLD 17 linker away from arm64e, and `THEOS_PACKAGE_SCHEME`
    /// makes a plain `make package` produce a rootless deb for Dopamine.
    static let environment: [String: String] = [
        "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "HOME": "/root", "THEOS": "/opt/theos", "LC_ALL": "C.UTF-8",
        "TMPDIR": "/tmp", "TERM": "xterm-256color", "COLOR": "0",
        "ARCHS": "arm64", "THEOS_PACKAGE_SCHEME": "rootless"
    ]

    private static let helpText = """
    可用命令：
      ls · cd <目录> · pwd · cat · grep · find · ps
      make package        在 /root/work/<项目> 里打包 rootless deb
      make clean          清理构建产物
      clear               清屏
    快捷按钮会替你把当前项目同步到 /root/work 再执行。
    """

    var prompt: String {
        let shown: String
        if cwd == "/root" {
            shown = "~"
        } else if cwd.hasPrefix("/root/") {
            shown = "~" + cwd.dropFirst("/root".count)
        } else {
            shown = cwd
        }
        return "root@theoslab:\(shown)#"
    }

    // MARK: - transcript

    func append(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        pending += chunk
        let schedule = !draining
        draining = true
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.drain() }
    }

    private func drain() {
        lock.lock()
        let chunk = pending
        pending = ""
        draining = false
        lock.unlock()
        guard !chunk.isEmpty else { return }
        var next = text + chunk
        if next.count > 400_000 { next = String(next.suffix(300_000)) }
        text = next
    }

    func clear() {
        lock.lock(); pending = ""; lock.unlock()
        text = ""
    }

    // MARK: - lifecycle

    func start() {
        guard !started else { return }
        started = true
        append("Theos Lab 终端 · THEOS=/opt/theos · 输入 help 查看用法\n")
        queue.async {
            do {
                try self.runtime.boot()
                self.append("环境已就绪 · 工作目录 /root\n\n")
            } catch {
                self.append("\n启动构建环境失败：" + Self.describe(error) + "\n")
                DispatchQueue.main.async { self.started = false }
            }
        }
    }

    // MARK: - commands

    func run(_ raw: String) {
        let command = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        guard !running else {
            append("\n还有命令在跑，先点「中断」。\n")
            return
        }
        if history.last != command { history.append(command) }
        historyIndex = history.count
        append(prompt + " " + command + "\n")
        switch command {
        case "clear", "cls":
            clear()
            return
        case "help":
            append(Self.helpText + "\n")
            return
        default:
            break
        }
        running = true
        queue.async { self.execute(command) }
    }

    func previousCommand() -> String? {
        guard !history.isEmpty else { return nil }
        historyIndex = max(0, historyIndex - 1)
        return history[min(historyIndex, history.count - 1)]
    }

    func nextCommand() -> String? {
        guard !history.isEmpty else { return nil }
        historyIndex = min(history.count, historyIndex + 1)
        return historyIndex >= history.count ? "" : history[historyIndex]
    }

    func interrupt() {
        sessionLock.lock()
        let session = job
        sessionLock.unlock()
        try? session?.interrupt()
    }

    private func execute(_ command: String) {
        var status: Int32 = 0
        do {
            try runtime.boot()
            if command == "cd" || command.hasPrefix("cd ") {
                try changeDirectory(String(command.dropFirst(2)))
            } else {
                status = try stream(command)
            }
        } catch {
            append("\n" + Self.describe(error) + "\n")
            status = -1
        }
        DispatchQueue.main.async {
            self.running = false
            if status > 0 { self.append("[退出码 \(status)]\n") }
        }
    }

    private func stream(_ command: String) throws -> Int32 {
        let session = try IshInstance.shared.spawn(.init(argv: ["/bin/sh", "-c", command],
                                                         cwd: cwd,
                                                         env: Self.environment,
                                                         allocateTTY: true,
                                                         mergeStderrIntoStdout: true,
                                                         initialWindowSize: (rows: 40, cols: 200, xpixel: 0, ypixel: 0)))
        sessionLock.lock(); job = session; sessionLock.unlock()
        defer {
            sessionLock.lock(); job = nil; sessionLock.unlock()
            session.close()
        }
        while true {
            switch try session.read(timeout: nil) {
            case .data(let bytes, _, _):
                append(TerminalText.decode(bytes))
            case .exited(let code, let signal):
                return signal == 0 ? code : 128 + signal
            }
        }
    }

    private func changeDirectory(_ raw: String) throws {
        var path = raw.trimmingCharacters(in: .whitespaces)
        if path.isEmpty || path == "~" { path = "/root" }
        else if path.hasPrefix("~/") { path = "/root/" + path.dropFirst(2) }
        let output = try runtime.shell("cd " + Self.quote(path) + " && pwd", cwd: cwd)
        let resolved = output.trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.main.async { self.cwd = resolved }
    }

    // MARK: - project actions

    func upload(_ project: URL) {
        guard !running else {
            append("\n还有命令在跑，先点「中断」。\n")
            return
        }
        running = true
        let name = project.lastPathComponent
        let guest = "/root/work/" + name
        append("\n$ 同步项目 → \(guest)\n")
        queue.async {
            do {
                try self.runtime.stage(project, at: guest) { self.append($0) }
                self.append("同步完成 · 当前目录 \(guest)\n")
                self.append("直接输入 make package 就能打包 rootless deb。\n")
                DispatchQueue.main.async {
                    self.cwd = guest
                    self.running = false
                }
            } catch {
                self.append("\n同步失败：" + Self.describe(error) + "\n")
                DispatchQueue.main.async { self.running = false }
            }
        }
    }

    func createProject(template: String, name: String, package: String, author: String,
                       filter: String, terminate: String) {
        guard !running else {
            append("\n还有命令在跑，先点「中断」。\n")
            return
        }
        running = true
        let tweakish = template.contains("tweak")
        let answers = tweakish ? [filter, terminate] : []
        append("\n$ /opt/theos/bin/nic.pl -t \(template) -n \(name) -p \(package) -u \"\(author)\"\n")
        queue.async {
            do {
                let host = try self.runtime.createProject(template: template, name: name, package: package,
                                                          author: author, answers: answers) { self.append($0) }
                self.append("\n✅ 已创建 Documents/Projects/\(host.lastPathComponent)\n")
                DispatchQueue.main.async {
                    self.running = false
                    self.onProjectCreated?(host)
                }
            } catch {
                self.append("\n❌ " + Self.describe(error) + "\n")
                DispatchQueue.main.async { self.running = false }
            }
        }
    }

    // MARK: - helpers

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
