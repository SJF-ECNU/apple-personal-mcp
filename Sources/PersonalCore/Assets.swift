import Foundation

public final class AssetStore {
    private let root: URL
    private let application: String
    public init(root: URL = AppIdentity.support.appendingPathComponent("Exports"), application: String = "mail") { self.root = root; self.application = application }
    public func save(_ data: Data, filename: String, mimeType: String) throws -> JSON {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let id = UUID().uuidString
        let url = root.appendingPathComponent(id)
        try PrivateFile.write(data, to: url)
        return try metadata(id: id, filename: filename, mimeType: mimeType, size: data.count)
    }
    public func saveFile(_ source: URL, filename: String, mimeType: String) throws -> JSON {
        let before = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
        guard before.isRegularFile == true else { throw ServiceError("not_downloaded", "Original media is not a local regular file") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let id = UUID().uuidString; let destination = root.appendingPathComponent(id)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            let after = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate else { throw ServiceError("source_changed", "Original media changed during export") }
            try FileManager.default.setAttributes([.posixPermissions: 0o600, .modificationDate: Date()], ofItemAtPath: destination.path)
            return try metadata(id: id, filename: filename, mimeType: mimeType, size: before.fileSize ?? 0)
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
    }
    private func metadata(id: String, filename: String, mimeType: String, size: Int) throws -> JSON {
        let metadata = JSON.object(["asset_id": .string(id), "filename": .string(filename), "mime_type": .string(mimeType), "size": .int(size), "uri": .string("apple-personal-mcp://assets/\(application)/\(id)"), "expires_at": .string(ISO8601DateFormatter().string(from: Date().addingTimeInterval(86400)))])
        try PrivateFile.writeJSON(metadata, to: root.appendingPathComponent(id + ".json"))
        return metadata
    }
    public func read(id: String, offset: Int, length: Int) throws -> JSON {
        guard UUID(uuidString: id) != nil else { throw ServiceError("invalid_asset", "Invalid resource ID") }
        let url = root.appendingPathComponent(id)
        guard url.resolvingSymlinksInPath().path == url.path,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              attrs[.type] as? FileAttributeType == .typeRegular else { throw ServiceError("not_found", "Resource is unavailable") }
        guard let modified = attrs[.modificationDate] as? Date, Date().timeIntervalSince(modified) <= 86400 else {
            throw ServiceError("asset_expired", "Retrieve the attachment again")
        }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        guard offset >= 0, offset <= size, length > 0, length <= 524288 else { throw ServiceError("invalid_arguments", "Invalid byte range") }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        try file.seek(toOffset: UInt64(offset))
        let bytes = try file.read(upToCount: length) ?? Data()
        return .object(["asset_id": .string(id), "offset": .int(offset), "size": .int(size), "data_base64": .string(bytes.base64EncodedString()), "next_offset": offset + bytes.count < size ? .int(offset + bytes.count) : .null])
    }
    public func list() throws -> [JSON] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).map { root.appendingPathComponent($0.lastPathComponent) }.compactMap { url in
            guard url.pathExtension == "json", UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
                  url.resolvingSymlinksInPath().path == url.path,
                  let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), attrs[.type] as? FileAttributeType == .typeRegular,
                  (attrs[.size] as? NSNumber)?.intValue ?? Int.max < 16384,
                  let data = try? Data(contentsOf: url), let item = try? JSONDecoder().decode(JSON.self, from: data),
                  let id = item["asset_id"].string, id == url.deletingPathExtension().lastPathComponent,
                  let expires = item["expires_at"].string.flatMap({ ISO8601DateFormatter().date(from: $0) }), expires > Date(),
                  FileManager.default.fileExists(atPath: root.appendingPathComponent(id).path) else { return nil }
            var fields = item.object ?? [:]
            fields["uri"] = .string("apple-personal-mcp://assets/\(application)/\(id)")
            return .object(fields)
        }.sorted { ($0["asset_id"].string ?? "") < ($1["asset_id"].string ?? "") }
    }
    func resolve(_ id: String) throws -> (URL, JSON) {
        _ = try read(id: id, offset: 0, length: 1)
        guard let metadata = try list().first(where: { $0["asset_id"].string == id }) else { throw ServiceError("not_found", "Resource metadata is unavailable") }
        return (root.appendingPathComponent(id), metadata)
    }
    public func cleanupExpired(now: Date = Date()) {
        guard root.resolvingSymlinksInPath().path == root.path,
              let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for name in files.map(\.lastPathComponent) where UUID(uuidString: name) != nil {
            let file = root.appendingPathComponent(name)
            guard file.resolvingSymlinksInPath().path == file.path,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: file.path), attributes[.type] as? FileAttributeType == .typeRegular,
                  let modified = attributes[.modificationDate] as? Date, now.timeIntervalSince(modified) > 86400 else { continue }
            try? FileManager.default.removeItem(at: file)
            let metadata = root.appendingPathComponent(file.lastPathComponent + ".json")
            if metadata.resolvingSymlinksInPath().path == metadata.path { try? FileManager.default.removeItem(at: metadata) }
        }
    }
}
