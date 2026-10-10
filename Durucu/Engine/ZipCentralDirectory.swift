import Foundation

/// Reads the ZIP central directory for the per-entry details libarchive does not
/// expose: compressed size, compression method and CRC.
enum ZipCentralDirectory {
    struct Record: Sendable {
        var compressedSize: Int64
        var uncompressedSize: Int64
        var crc32: UInt32
        var method: String
        var isEncrypted: Bool
    }

    struct Directory: Sendable {
        var records: [String: Record]
        /// Some names are neither flagged nor valid UTF-8: they were written in the
        /// OEM code page of an older Windows machine.
        var hasLegacyNames: Bool
    }

    static func read(url: URL) -> Directory? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(), fileSize >= 22 else { return nil }

        // EOCD (22 bytes) + max comment (65535) + ZIP64 locator (20).
        let tailLength = min(fileSize, 65_535 + 22 + 20)
        let tailStart = fileSize - tailLength
        guard let tail = read(handle, at: tailStart, count: Int(tailLength)) else { return nil }

        guard let eocd = lastIndex(of: 0x0605_4b50, in: tail) else { return nil }
        var entryCount = UInt64(tail.u16(eocd + 10))
        var cdSize = UInt64(tail.u32(eocd + 12))
        var cdOffset = UInt64(tail.u32(eocd + 16))

        if entryCount == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF,
           eocd >= 20, tail.u32(eocd - 20) == 0x0706_4b50 {
            let zip64Offset = tail.u64(eocd - 20 + 8)
            guard let zip64 = read(handle, at: zip64Offset, count: 56), zip64.u32(0) == 0x0606_4b50 else { return nil }
            entryCount = zip64.u64(32)
            cdSize = zip64.u64(40)
            cdOffset = zip64.u64(48)
        }

        guard cdSize > 0, cdSize < 1 << 30 else { return nil }
        var directory = read(handle, at: cdOffset, count: Int(cdSize))
        if directory?.u32(0) != 0x0201_4b50 {
            // Self-extracting archives or data prepended to the zip shift every offset.
            let eocdAbsolute = tailStart + UInt64(eocd)
            guard eocdAbsolute >= cdSize else { return nil }
            directory = read(handle, at: eocdAbsolute - cdSize, count: Int(cdSize))
        }
        guard let directory, directory.u32(0) == 0x0201_4b50 else { return nil }

        var records: [String: Record] = [:]
        var hasLegacyNames = false
        records.reserveCapacity(Int(min(entryCount, 1_000_000)))
        var cursor = 0
        while cursor + 46 <= directory.count, directory.u32(cursor) == 0x0201_4b50 {
            let flags = directory.u16(cursor + 8)
            var method = directory.u16(cursor + 10)
            let crc = directory.u32(cursor + 16)
            var compressed = UInt64(directory.u32(cursor + 20))
            var uncompressed = UInt64(directory.u32(cursor + 24))
            let nameLength = Int(directory.u16(cursor + 28))
            let extraLength = Int(directory.u16(cursor + 30))
            let commentLength = Int(directory.u16(cursor + 32))
            let nameStart = cursor + 46
            let extraStart = nameStart + nameLength
            let next = extraStart + extraLength + commentLength
            guard next <= directory.count else { break }

            var aesStrength: UInt8?
            var unicodeName: String?
            var extra = extraStart
            while extra + 4 <= extraStart + extraLength {
                let id = directory.u16(extra)
                let size = Int(directory.u16(extra + 2))
                let body = extra + 4
                guard body + size <= extraStart + extraLength else { break }
                if id == 0x0001 {
                    var field = body
                    if uncompressed == 0xFFFF_FFFF, field + 8 <= body + size { uncompressed = directory.u64(field); field += 8 }
                    if compressed == 0xFFFF_FFFF, field + 8 <= body + size { compressed = directory.u64(field) }
                } else if id == 0x9901, size >= 7 {
                    aesStrength = directory[directory.startIndex + body + 4]
                    method = directory.u16(body + 5)
                } else if id == 0x7075, size > 5 {
                    let start = directory.startIndex + body + 5
                    unicodeName = String(validating: directory[start..<(directory.startIndex + body + size)], as: UTF8.self)
                }
                extra = body + size
            }

            let nameBytes = directory[(directory.startIndex + nameStart)..<(directory.startIndex + extraStart)]
            if flags & 0x0800 == 0, unicodeName == nil, String(validating: nameBytes, as: UTF8.self) == nil {
                hasLegacyNames = true
            }
            let name = unicodeName ?? ArchivePath.decode(bytes: nameBytes)
            records[ArchivePath.normalize(name)] = Record(
                compressedSize: Int64(compressed),
                uncompressedSize: Int64(uncompressed),
                crc32: crc,
                method: methodName(method, aesStrength: aesStrength, encrypted: flags & 1 != 0),
                isEncrypted: flags & 1 != 0
            )
            cursor = next
        }
        return Directory(records: records, hasLegacyNames: hasLegacyNames)
    }

    private static func methodName(_ method: UInt16, aesStrength: UInt8?, encrypted: Bool) -> String {
        let base = switch method {
        case 0: "Sıkıştırmasız"
        case 8: "Deflate"
        case 9: "Deflate64"
        case 12: "BZip2"
        case 14: "LZMA"
        case 93: "Zstandard"
        case 95: "XZ"
        case 98: "PPMd"
        default: "Yöntem \(method)"
        }
        guard encrypted else { return base }
        if let aesStrength {
            let bits = [1: 128, 2: 192, 3: 256][Int(aesStrength)] ?? 256
            return "\(base) · AES-\(bits)"
        }
        return "\(base) · ZipCrypto"
    }

    private static func read(_ handle: FileHandle, at offset: UInt64, count: Int) -> Data? {
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: count), data.count == count else { return nil }
        return data
    }

    private static func lastIndex(of signature: UInt32, in data: Data) -> Int? {
        var index = data.count - 22
        while index >= 0 {
            if data.u32(index) == signature { return index }
            index -= 1
        }
        return nil
    }
}

private extension Data {
    func u16(_ offset: Int) -> UInt16 {
        withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)) }
    }

    func u32(_ offset: Int) -> UInt32 {
        withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }

    func u64(_ offset: Int) -> UInt64 {
        withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
    }
}
