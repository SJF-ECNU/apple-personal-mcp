import Foundation

/// Keep atomic replacement and owner-only file permissions together.
enum PrivateFile {
    static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try write(JSONEncoder().encode(value), to: url)
    }
}
