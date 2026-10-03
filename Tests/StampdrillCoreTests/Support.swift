import Foundation
@testable import StampdrillCore
import Stamp

/// Builds an in-memory workspace from `path: contents` pairs.
func makeWorkspace(_ files: [String: String]) -> Workspace {
    let root = URL(fileURLWithPath: "/tmp/stampdrill-tests")
    return Workspace(root: root, files: files.map { path, text in
        WorkspaceFile(url: root.appendingPathComponent(path), root: root, text: text)
    })
}
