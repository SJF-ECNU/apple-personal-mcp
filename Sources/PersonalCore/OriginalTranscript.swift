import Foundation

/// Read ISO BMFF metadata boundaries, never scan arbitrary audio bytes for JSON.
public final class OriginalTranscript {
    private struct Atom { let type: UInt32; let payload: UInt64; let end: UInt64 }
    private let file: FileHandle
    private let size: UInt64
    public init(url: URL) throws {
        file = try FileHandle(forReadingFrom: url)
        size = try file.seekToEnd()
    }
    deinit { try? file.close() }
    private func code(_ value: String) -> UInt32 { value.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
    private func read(_ offset: UInt64, _ length: Int) throws -> Data {
        guard length >= 0, offset <= size, UInt64(length) <= size - offset else { throw ServiceError("unsupported_format", "Metadata exceeds media boundary") }
        try file.seek(toOffset: offset)
        let data = try file.read(upToCount: length) ?? Data()
        guard data.count == length else { throw ServiceError("source_changed", "Media changed while reading metadata") }; return data
    }
    private func integer(_ data: Data) -> UInt64 { data.reduce(0) { $0 << 8 | UInt64($1) } }
    private func atoms(_ start: UInt64, _ end: UInt64) throws -> [Atom] {
        var offset = start; var result: [Atom] = []
        while offset < end {
            guard end - offset >= 8 else { throw ServiceError("unsupported_format", "Truncated media atom") }
            let header = try read(offset, 8); var length = integer(header.prefix(4)); var headerLength: UInt64 = 8
            if length == 1 { guard end - offset >= 16 else { throw ServiceError("unsupported_format", "Truncated extended atom") }; length = try integer(read(offset + 8, 8)); headerLength = 16 }
            if length == 0 { length = end - offset }
            guard length >= headerLength, length <= end - offset else { throw ServiceError("unsupported_format", "Invalid media atom size") }
            result.append(Atom(type: UInt32(integer(header.suffix(4))), payload: offset + headerLength, end: offset + length)); offset += length
        }
        return result
    }
    private func payload(_ atom: Atom, skipping: UInt64 = 0) throws -> Data {
        guard skipping <= atom.end - atom.payload, atom.end - atom.payload - skipping <= 32 * 1024 * 1024 else { throw ServiceError("resource_limit", "Transcript metadata exceeds supported 32 MiB bound") }
        return try read(atom.payload + skipping, Int(atom.end - atom.payload - skipping))
    }
    private func keys(_ atom: Atom) throws -> [UInt32: String] {
        let data = try payload(atom)
        guard data.count >= 8 else { throw ServiceError("unsupported_format", "Truncated metadata keys") }
        let count = integer(data[4..<8]); var offset = 8; var result: [UInt32: String] = [:]
        guard count <= UInt64(data.count / 8) else { throw ServiceError("unsupported_format", "Invalid metadata key count") }
        for index in 0..<count {
            guard offset <= data.count - 8 else { throw ServiceError("unsupported_format", "Truncated metadata key") }
            let length = integer(data[offset..<offset + 4])
            guard length >= 8, length <= UInt64(data.count - offset) else { throw ServiceError("unsupported_format", "Invalid metadata key size") }
            guard let name = String(data: data[offset + 8..<offset + Int(length)], encoding: .utf8) else { throw ServiceError("unsupported_format", "Invalid metadata key encoding") }
            result[UInt32(index + 1)] = name; offset += Int(length)
        }
        return result
    }
    private func walk(_ list: [Atom], depth: Int = 0) throws -> [Data] {
        guard depth < 16 else { throw ServiceError("unsupported_format", "Media metadata nesting exceeds supported depth") }
        var transcripts: [Data] = []
        for atom in list {
            if atom.type == code("tsrp") { transcripts.append(try payload(atom)); continue }
            if atom.type == code("meta") {
                guard atom.end - atom.payload >= 4 else { throw ServiceError("unsupported_format", "Truncated meta atom") }
                let children = try atoms(atom.payload + 4, atom.end)
                let keyMap = try children.first(where: { $0.type == code("keys") }).map(keys) ?? [:]
                for ilst in children where ilst.type == code("ilst") {
                    for item in try atoms(ilst.payload, ilst.end) where keyMap[item.type] == "com.apple.VoiceMemos.tsrp" {
                        for data in try atoms(item.payload, item.end) where data.type == code("data") { transcripts.append(try payload(data, skipping: 8)) }
                    }
                }
                transcripts += try walk(children.filter { $0.type != code("ilst") }, depth: depth + 1)
            } else if ["moov", "trak", "udta", "mdia", "minf"].contains(where: { atom.type == code($0) }) {
                transcripts += try walk(atoms(atom.payload, atom.end), depth: depth + 1)
            }
        }
        return transcripts
    }
    public func read() throws -> [JSON] {
        let payloads = try walk(atoms(0, size))
        return try payloads.map { data in
            guard let value = try? JSONDecoder().decode(JSON.self, from: data), value["attributedString"].object != nil else { throw ServiceError("unsupported_format", "Original transcript JSON layout is unsupported") }
            _ = try Self.text(value)
            return value
        }
    }
    public static func text(_ value: JSON) throws -> String {
        guard let runs = value["attributedString"]["runs"].array, runs.count % 2 == 0,
              let attributes = value["attributedString"]["attributeTable"].array else { throw ServiceError("unsupported_format", "Transcript runs/attribute table are unsupported") }
        var text = ""
        for index in stride(from: 0, to: runs.count, by: 2) {
            guard let run = runs[index].string, let attribute = runs[index + 1].int, attributes.indices.contains(attribute) else { throw ServiceError("unsupported_format", "Transcript run has invalid text or attribute reference") }
            text += run
        }
        return text
    }
}
