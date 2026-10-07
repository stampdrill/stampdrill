import Foundation
import Stamp

/// A folder of request files.
///
/// `environment.stamp` at the root holds the dimensions and variable sets
/// shared by every file. Folders group requests; nothing else about the
/// layout is special.
public struct Workspace: Sendable {
    public static let environmentFileName = "environment.stamp"
    /// Personal variables that stay on this machine; `.gitignore` keeps them out of the repository.
    public static let localEnvironmentFileName = "environment.local.stamp"
    /// `.http` files use a subset of the same format, so they are read too.
    public static let fileExtensions: Set<String> = ["stamp", "http"]

    public let root: URL
    public private(set) var files: [WorkspaceFile]

    public init(root: URL, files: [WorkspaceFile]) {
        self.root = root.standardizedFileURL
        self.files = files.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    public static func load(from root: URL) throws -> Workspace {
        let root = root.standardizedFileURL
        var files: [WorkspaceFile] = []
        for url in try requestFileURLs(in: root) {
            files.append(try WorkspaceFile(url: url, root: root))
        }
        return Workspace(root: root, files: files)
    }

    /// The nearest folder above `url` that has an `environment.stamp` (or only a
    /// personal `environment.local.stamp`), or the file's own folder when there is none.
    public static func root(containing url: URL) -> URL {
        let start = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        var candidate = start.standardizedFileURL
        while true {
            if [environmentFileName, localEnvironmentFileName].contains(where: {
                FileManager.default.fileExists(atPath: candidate.appendingPathComponent($0).path)
            }) {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { return start.standardizedFileURL }
            candidate = parent
        }
    }

    public static func isRequestFile(_ url: URL) -> Bool {
        fileExtensions.contains(url.pathExtension.lowercased())
    }

    static func requestFileURLs(in root: URL) throws -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isDirectory == true {
                if ["node_modules", "build", "DerivedData"].contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
            } else if isRequestFile(url) {
                urls.append(url)
            }
        }
        return urls
    }

    public var environmentFile: WorkspaceFile? {
        files.first { $0.relativePath == Self.environmentFileName }
    }

    public var localEnvironmentFile: WorkspaceFile? {
        files.first { $0.relativePath == Self.localEnvironmentFileName }
    }

    public var requestFiles: [WorkspaceFile] {
        files.filter { $0.relativePath != Self.environmentFileName && $0.relativePath != Self.localEnvironmentFileName }
    }

    public var environment: EnvironmentMatrix {
        var matrix = environmentFile.map { EnvironmentMatrix(document: $0.document, origin: $0.relativePath) } ?? EnvironmentMatrix()
        if let local = localEnvironmentFile {
            matrix.merge(local.document, origin: local.relativePath, isLocal: true)
        }
        return matrix
    }

    /// The workspace environment plus the file's own dimensions and sets.
    public func environment(for file: WorkspaceFile) -> EnvironmentMatrix {
        [Self.environmentFileName, Self.localEnvironmentFileName].contains(file.relativePath)
            ? environment
            : environment.merging(file.document, origin: file.relativePath)
    }

    public func file(at relativePath: String) -> WorkspaceFile? {
        files.first { $0.relativePath == relativePath }
    }

    public func file(for url: URL) -> WorkspaceFile? {
        let path = url.standardizedFileURL.path
        return files.first { $0.url.path == path }
    }

    public func request(_ reference: RequestReference) -> (WorkspaceFile, RequestBlock)? {
        guard let file = file(at: reference.path), let request = file.document.request(named: reference.name) else {
            return nil
        }
        return (file, request)
    }

    /// Finds a request by name, looking in `file` first and then everywhere else.
    public func request(named name: String, near file: WorkspaceFile?) -> RequestReference? {
        if let file, file.document.request(named: name) != nil {
            return RequestReference(path: file.relativePath, name: name)
        }
        return requestFiles.lazy
            .first { $0.document.request(named: name) != nil }
            .map { RequestReference(path: $0.relativePath, name: name) }
    }

    /// Re-reads one file from disk, adding or removing it as needed.
    public mutating func reload(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        files.removeAll { $0.url.path == path }
        if FileManager.default.fileExists(atPath: path), Self.isRequestFile(url) {
            files.append(try WorkspaceFile(url: url, root: root))
            files.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        }
    }

    public mutating func replace(_ file: WorkspaceFile) {
        if let index = files.firstIndex(where: { $0.relativePath == file.relativePath }) {
            files[index] = file
        } else {
            files.append(file)
            files.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        }
    }
}

public struct WorkspaceFile: Sendable, Identifiable {
    public let url: URL
    public let relativePath: String
    public var document: Document

    public var id: String { relativePath }
    public var name: String { url.deletingPathExtension().lastPathComponent }
    public var text: String { document.source.string }

    public init(url: URL, root: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        self.init(url: url, root: root, text: text)
    }

    public init(url: URL, root: URL, text: String) {
        self.url = url.standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        let path = self.url.path
        relativePath = path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : self.url.lastPathComponent
        document = Document.parse(text, fileName: url.lastPathComponent)
    }

    public func updating(text: String) -> WorkspaceFile {
        var copy = self
        copy.document = Document.parse(text, fileName: url.lastPathComponent)
        return copy
    }
}

public struct RequestReference: Hashable, Codable, Sendable {
    public var path: String
    public var name: String

    public init(path: String, name: String) {
        self.path = path
        self.name = name
    }
}
