//
// RootfsArchive.swift
// Ain
//
// Unpacks the bundled rootfs archive on first launch.
//
// The build environment is ~19k files / 1.1 GB. Shipping it as a directory
// inside the .app makes every re-signing pass hash thousands of resources,
// which is why sideloading used to take minutes. Shipping it as a single
// archive keeps the bundle at a handful of files, so signing is quick, and
// the tree is materialised here instead.
//

import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum RootfsArchive {
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    /// Extracts a GNU/POSIX tar archive. Returns the number of files written.
    @discardableResult
    static func extract(_ archive: URL, to destination: URL,
                        log: ((String) -> Void)? = nil) throws -> Int {
        let fd = open(archive.path, O_RDONLY)
        guard fd >= 0 else { throw Failure("无法打开构建环境归档") }
        defer { close(fd) }

        let files = FileManager.default
        try files.createDirectory(at: destination, withIntermediateDirectories: true)

        // One scratch block reused for every file keeps the copy loop allocation free.
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
        defer { buffer.deallocate() }

        var reader = Reader(fd: fd, buffer: buffer)
        var written = 0
        var pendingLongName: String?
        var deferredLinks: [(link: String, target: String)] = []

        while true {
            guard let header = reader.header() else { break }  // truncated: stop quietly
            if header.allSatisfy({ $0 == 0 }) { break }        // zero block ends the archive

            let typeflag = header[156]
            let size = number(header, 124, 12)

            if typeflag == UInt8(ascii: "L") {                 // GNU long name
                let data = try reader.bytes(size)
                pendingLongName = string(data, 0, data.count)
                continue
            }
            if typeflag == UInt8(ascii: "x") || typeflag == UInt8(ascii: "g")
                || typeflag == UInt8(ascii: "K") {             // pax / global headers
                try reader.skip(size)
                continue
            }

            let rawName = pendingLongName ?? string(header, 0, 100)
            pendingLongName = nil
            var name = rawName
            while name.hasPrefix("./") { name.removeFirst(2) }
            while name.hasSuffix("/") { name.removeLast() }
            guard !name.isEmpty, name != "." else {
                try reader.skip(size)
                continue
            }
            guard !name.split(separator: "/").contains("..") else {
                throw Failure("归档包含非法路径：\(name)")
            }
            let url = destination.appendingPathComponent(name)
            try files.createDirectory(at: url.deletingLastPathComponent(),
                                      withIntermediateDirectories: true)

            switch typeflag {
            case UInt8(ascii: "5"):                            // directory
                try files.createDirectory(at: url, withIntermediateDirectories: true)
            case UInt8(ascii: "2"):                            // symlink
                let target = string(header, 157, 100)
                try? files.removeItem(at: url)
                try files.createSymbolicLink(atPath: url.path, withDestinationPath: target)
            case UInt8(ascii: "1"):                            // hard link
                let target = string(header, 157, 100)
                let source = destination.appendingPathComponent(target)
                if files.fileExists(atPath: source.path) {
                    try? files.removeItem(at: url)
                    try? files.linkItem(at: source, to: url)
                } else {
                    deferredLinks.append((name, target))
                }
            default:                                           // regular file
                try reader.copy(size, to: url)
                written += 1
                if written % 4000 == 0 { log?("已展开 \(written) 个文件") }
            }
        }

        for link in deferredLinks {
            let source = destination.appendingPathComponent(link.target)
            guard files.fileExists(atPath: source.path) else { continue }
            let url = destination.appendingPathComponent(link.link)
            try? files.removeItem(at: url)
            try? files.linkItem(at: source, to: url)
        }

        log?("展开完成 · \(written) 个文件")
        return written
    }

    // MARK: - Streaming

    private static let block = 512
    private static let chunk = 1 << 20

    private struct Reader {
        let fd: Int32
        let buffer: UnsafeMutableRawPointer
        var offset: off_t = 0

        /// Reads one 512-byte header block; nil when the archive is exhausted.
        mutating func header() -> [UInt8]? {
            var header = [UInt8](repeating: 0, count: RootfsArchive.block)
            let count = header.withUnsafeMutableBytes { raw -> Int in
                RootfsArchive.read(fd, raw.baseAddress!, RootfsArchive.block, offset)
            }
            guard count == RootfsArchive.block else { return nil }
            offset += off_t(RootfsArchive.block)
            return header
        }

        mutating func skip(_ size: Int64) throws {
            offset += off_t(size + (size % 512 == 0 ? 0 : 512 - size % 512))
        }

        mutating func bytes(_ size: Int64) throws -> [UInt8] {
            var data = [UInt8](repeating: 0, count: Int(size))
            let count = data.withUnsafeMutableBytes { raw -> Int in
                RootfsArchive.read(fd, raw.baseAddress!, Int(size), offset)
            }
            guard count == Int(size) else { throw Failure("归档意外结束") }
            try skip(size)
            return data
        }

        /// Streams `size` bytes to a new file without buffering the whole entry.
        mutating func copy(_ size: Int64, to url: URL) throws {
            let out = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            guard out >= 0 else { throw Failure("无法写入 \(url.lastPathComponent)") }
            defer { close(out) }
            var remaining = size
            while remaining > 0 {
                let want = Int(min(Int64(RootfsArchive.chunk), remaining))
                let got = RootfsArchive.read(fd, buffer, want, offset)
                guard got > 0 else { throw Failure("归档在 \(url.lastPathComponent) 处意外结束") }
                var sent = 0
                while sent < got {
                    let n = write(out, buffer.advanced(by: sent), got - sent)
                    guard n > 0 else { throw Failure("写入 \(url.lastPathComponent) 失败") }
                    sent += n
                }
                offset += off_t(got)
                remaining -= Int64(got)
            }
            // Data was consumed above; only the alignment padding is left.
            offset += off_t(size % 512 == 0 ? 0 : 512 - size % 512)
        }
    }

    private static func read(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int, _ offset: off_t) -> Int {
        var filled = 0
        while filled < count {
            let n = pread(fd, buffer.advanced(by: filled), count - filled, offset + off_t(filled))
            if n <= 0 { break }
            filled += n
        }
        return filled
    }

    private static func string(_ bytes: [UInt8], _ offset: Int, _ length: Int) -> String {
        let slice = bytes[offset..<min(offset + length, bytes.count)]
        var out = [UInt8]()
        for byte in slice {
            if byte == 0 { break }
            out.append(byte)
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// tar stores numbers as NUL/space padded octal, or base-256 when the high bit is set.
    private static func number(_ bytes: [UInt8], _ offset: Int, _ length: Int) -> Int64 {
        let slice = bytes[offset..<min(offset + length, bytes.count)]
        if let first = slice.first, first & 0x80 != 0 {
            var value = Int64(first & 0x7f)
            for byte in slice.dropFirst() { value = (value << 8) | Int64(byte) }
            return value
        }
        var text = ""
        for byte in slice {
            if byte == 0 || byte == 0x20 {
                if !text.isEmpty { break }
                continue
            }
            text.append(Character(UnicodeScalar(byte)))
        }
        return Int64(text, radix: 8) ?? 0
    }
}
