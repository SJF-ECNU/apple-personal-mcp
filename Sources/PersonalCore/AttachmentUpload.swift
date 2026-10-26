import Foundation

/// The actual file length is the upload cursor. Each Agent has a separate directory.
public final class AttachmentUpload {
    private let root: URL
    private let assets: AssetStore
    public init(root: URL, assets: AssetStore) { self.root = root; self.assets = assets }
    public static func filename(_ value: String) throws -> String {
        guard !value.isEmpty, value != ".", value != "..", !value.contains("/"), !value.contains("\\"), value.rangeOfCharacter(from: .controlCharacters) == nil, value.utf8.count <= 240 else { throw ServiceError("invalid_arguments", "Use a filename without directories/control characters, at most 240 UTF-8 bytes") }
        return value
    }
    public func call(_ values: [String: JSON]) throws -> JSON {
        let a = Arguments(values); let action = try a.requiredString("action")
        guard ["start", "chunk", "status", "finish", "cancel"].contains(action) else { throw ServiceError("invalid_arguments", "Unknown upload action") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if action == "start" {
            cleanup()
            let active = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            guard active.count < 16 else { throw ServiceError("server_busy", "Finish/cancel existing uploads first") }
            let id = UUID().uuidString; let folder = root.appendingPathComponent(id)
            let name = try Self.filename(a.requiredString("filename"))
            let mime = try a.string("mime_type") ?? "application/octet-stream"
            guard mime.utf8.count <= 200, mime.rangeOfCharacter(from: .controlCharacters) == nil else { throw ServiceError("invalid_arguments", "Invalid MIME type") }
            guard a.values["size"] != nil else { throw ServiceError("invalid_arguments", "Declared byte size is required") }
            let metadata = JSON.object(["upload_id": .string(id), "filename": .string(name), "size": .int(try a.integer("size", default: 0, range: 0...104857600)), "mime_type": .string(mime)])
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try PrivateFile.writeJSON(metadata, to: folder.appendingPathComponent("metadata.json"))
            guard FileManager.default.createFile(atPath: folder.appendingPathComponent("data").path, contents: Data(), attributes: [.posixPermissions: 0o600]) else { throw ServiceError("state_unavailable", "Cannot create upload") }
            return .object(["upload_id": .string(id), "next_offset": .int(0)])
        }
        let id = try a.requiredString("upload_id")
        guard UUID(uuidString: id) != nil else { throw ServiceError("invalid_arguments", "Invalid upload UUID") }
        let folder = root.appendingPathComponent(id); let metadataURL = folder.appendingPathComponent("metadata.json")
        guard folder.resolvingSymlinksInPath().path == folder.path,
              let attributes = try? metadataURL.resourceValues(forKeys: [.contentModificationDateKey]), let modified = attributes.contentModificationDate,
              Date().timeIntervalSince(modified) < 86400 else { throw ServiceError("not_found", "Upload is absent or expired") }
        let metadata = try JSONDecoder().decode(JSON.self, from: Data(contentsOf: metadataURL))
        if action == "cancel" { try FileManager.default.removeItem(at: folder); return .object(["status": .string("cancelled")]) }
        if let result = metadata["asset"].object { return .object(result) }
        let dataURL = folder.appendingPathComponent("data")
        guard dataURL.resolvingSymlinksInPath().path == dataURL.path else { throw ServiceError("invalid_asset", "Upload cannot be a symbolic link") }
        let size = try dataURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        if action == "chunk" {
            let offset = try a.integer("offset", default: 0, range: 0...104857600)
            guard let bytes = Data(base64Encoded: try a.requiredString("data_base64")), !bytes.isEmpty, bytes.count <= 524288,
                  offset <= (metadata["size"].int ?? 0) - bytes.count else { throw ServiceError("invalid_arguments", "Invalid chunk or declared size exceeded") }
            let file = try FileHandle(forUpdating: dataURL); defer { try? file.close() }
            if offset < size {
                try file.seek(toOffset: UInt64(offset))
                guard offset + bytes.count <= size, try file.read(upToCount: bytes.count) == bytes else { throw ServiceError("upload_conflict", "Previously uploaded bytes differ") }
            } else {
                guard offset == size else { throw ServiceError("invalid_cursor", "Append only at the returned next_offset") }
                try file.seekToEnd(); try file.write(contentsOf: bytes); try file.synchronize()
            }
            return .object(["upload_id": .string(id), "next_offset": .int(max(size, offset + bytes.count))])
        }
        if action == "status" { return .object(["upload_id": .string(id), "next_offset": .int(size), "size": metadata["size"]]) }
        guard action == "finish" else { throw ServiceError("invalid_arguments", "Use start/chunk/status/finish/cancel") }
        guard size == metadata["size"].int else { throw ServiceError("incomplete_upload", "Upload length does not match declared size") }
        let result = try assets.saveFile(dataURL, filename: metadata["filename"].string!, mimeType: metadata["mime_type"].string!)
        var fields = metadata.object!; fields["asset"] = result
        try PrivateFile.writeJSON(JSON.object(fields), to: metadataURL)
        try FileManager.default.removeItem(at: dataURL)
        return result
    }
    public func cleanup(now: Date = Date()) {
        for folder in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] where UUID(uuidString: folder.lastPathComponent) != nil {
            let file = folder.appendingPathComponent("metadata.json")
            guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, now.timeIntervalSince(modified) > 86400 else { continue }
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
