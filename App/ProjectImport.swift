//
// ProjectImport.swift
// Ain
//
// Created by Ain on 2026/11/20.
//

import Foundation

enum ProjectImport {
    static let makefiles = ["GNUmakefile", "makefile", "Makefile"]
    private static let ignored = Set(["Builds", "packages", "node_modules"])
    /// Directories that belong to the Linux environment, not to the user's work.
    /// Scanning them costs seconds and can surface Theos' own makefiles as "projects".
    private static let environmentMarkers = ["etc/alpine-release", "opt/theos/makefiles", "sbin/ishsv"]
    private static let maxDepth = 6

    static func findProjects(in directory: URL) throws -> [URL] {
        var found: [URL] = []
        scan(directory, depth: 0, into: &found)
        return found
    }

    private static func scan(_ directory: URL, depth: Int, into found: inout [URL]) {
        guard depth <= maxDepth else { return }
        let files = FileManager.default

        if isProjectRoot(directory) {
            found.append(directory)
            return
        }
        if isEnvironmentRoot(directory) { return }

        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        let children = (try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys),
                                                      options: .skipsHiddenFiles)) ?? []
        for item in children.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            guard !ignored.contains(item.lastPathComponent), item.pathExtension != "sdk",
                  let values = try? item.resourceValues(forKeys: keys),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  values.isPackage != true else { continue }
            scan(item, depth: depth + 1, into: &found)
        }
    }

    private static func isProjectRoot(_ directory: URL) -> Bool {
        makefiles.contains { name in
            (try? directory.appendingPathComponent(name).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    private static func isEnvironmentRoot(_ directory: URL) -> Bool {
        environmentMarkers.contains { marker in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(marker).path)
        }
    }

    static func add(_ folder: URL, to documents: URL) throws -> [URL] {
        let root = documents.resolvingSymlinksInPath().standardizedFileURL
        let chosen = folder.resolvingSymlinksInPath().standardizedFileURL
        if chosen.path == root.path || chosen.path.hasPrefix(root.path + "/") {
            return try requireProjects(in: chosen)
        }

        let files = FileManager.default
        let projects = root.appendingPathComponent("Projects", isDirectory: true)
        try files.createDirectory(at: projects, withIntermediateDirectories: true)
        let staging = projects.appendingPathComponent(".import-" + UUID().uuidString, isDirectory: true)
        defer { try? files.removeItem(at: staging) }
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: [], error: &coordinationError) { source in
            do { try files.copyItem(at: source, to: staging) }
            catch { copyError = error }
        }
        if coordinationError != nil && !files.fileExists(atPath: staging.path) {
            // If Files can't coordinate the read, try the original URL while access is still open.
            try files.copyItem(at: folder, to: staging)
        }
        if let copyError { throw copyError }
        let found = try requireProjects(in: staging)
        let name = folder.lastPathComponent
        let preferred = projects.appendingPathComponent(name, isDirectory: true)
        let target = files.fileExists(atPath: preferred.path)
            ? projects.appendingPathComponent(name + "-" + UUID().uuidString.prefix(8), isDirectory: true)
            : preferred
        let relativeComponents = found.map { Array($0.pathComponents.dropFirst(staging.pathComponents.count)) }
        try files.moveItem(at: staging, to: target)
        return relativeComponents.map { components in
            components.reduce(target) { $0.appendingPathComponent($1, isDirectory: true) }
        }
    }

    private static func requireProjects(in directory: URL) throws -> [URL] {
        let projects = try findProjects(in: directory)
        guard !projects.isEmpty else {
            throw WorkspaceError.message("所选文件夹中找不到 Theos 项目。请选择含 Makefile 的文件夹或它的上一级目录。")
        }
        return projects
    }
}
