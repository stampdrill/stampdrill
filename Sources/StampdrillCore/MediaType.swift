import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// Media types and file extensions, from the system's type database where
/// there is one and from a table of common types elsewhere.
enum MediaType {
    static func forFileExtension(_ ext: String) -> String? {
        #if canImport(UniformTypeIdentifiers)
        if let type = UTType(filenameExtension: ext)?.preferredMIMEType { return type }
        #endif
        return table.first { $0.ext == ext.lowercased() }?.type
    }

    static func fileExtension(for mediaType: String) -> String? {
        #if canImport(UniformTypeIdentifiers)
        if let ext = UTType(mimeType: mediaType)?.preferredFilenameExtension { return ext }
        #endif
        return table.first { $0.type == mediaType.lowercased() }?.ext
    }

    private static let table: [(ext: String, type: String)] = [
        ("json", "application/json"), ("xml", "application/xml"), ("html", "text/html"), ("htm", "text/html"),
        ("txt", "text/plain"), ("csv", "text/csv"), ("tsv", "text/tab-separated-values"), ("css", "text/css"),
        ("js", "text/javascript"), ("yaml", "application/yaml"), ("yml", "application/yaml"), ("md", "text/markdown"),
        ("pdf", "application/pdf"), ("zip", "application/zip"), ("gz", "application/gzip"),
        ("png", "image/png"), ("jpg", "image/jpeg"), ("jpeg", "image/jpeg"), ("gif", "image/gif"),
        ("webp", "image/webp"), ("svg", "image/svg+xml"), ("ico", "image/x-icon"),
        ("mp3", "audio/mpeg"), ("wav", "audio/wav"), ("mp4", "video/mp4"), ("mov", "video/quicktime"),
        ("woff", "font/woff"), ("woff2", "font/woff2"), ("wasm", "application/wasm"),
    ]
}
