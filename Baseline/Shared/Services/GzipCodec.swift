import Foundation

/// Minimal gzip wrapper around Apple's raw-deflate `zlib` compression.
///
/// `NSData.compressed(using: .zlib)` produces a bare deflate stream with no container, so this
/// prepends the 10-byte gzip header and appends the CRC-32 + input-size trailer by hand. The payload
/// is then a real `.gz` object that any tool — `gunzip`, a browser, a Cloud Function — can read,
/// which is the whole point of gzipping rather than shipping the raw stream.
///
/// Ported from Ascend, where the same codec backs the workout heart-rate sidecar. Kept
/// self-contained and byte-exact so the two apps' objects stay interchangeable.
enum GzipCodec {
    enum Error: LocalizedError, Equatable {
        case compressionFailed
        case invalidGzipData
        case decompressionFailed

        var errorDescription: String? {
            switch self {
            case .compressionFailed: "Failed to compress the heart-rate series."
            case .invalidGzipData: "The heart-rate series is not valid gzip data."
            case .decompressionFailed: "Failed to decompress the heart-rate series."
            }
        }
    }

    static func compress(_ data: Data) throws -> Data {
        guard let deflated = try (data as NSData).compressed(using: .zlib) as Data?,
              deflated.isEmpty == false else {
            throw Error.compressionFailed
        }

        var gzipData = Data([
            0x1f, 0x8b,             // magic
            0x08,                   // deflate
            0x00,                   // flags
            0x00, 0x00, 0x00, 0x00, // mtime (zeroed: the object is content-addressed by its path)
            0x00,                   // extra flags
            0xff                    // OS unknown
        ])
        gzipData.append(deflated)

        var crc32 = Self.crc32(for: data).littleEndian
        withUnsafeBytes(of: &crc32) { gzipData.append(contentsOf: $0) }

        var inputSize = UInt32(truncatingIfNeeded: data.count).littleEndian
        withUnsafeBytes(of: &inputSize) { gzipData.append(contentsOf: $0) }

        return gzipData
    }

    static func decompress(_ data: Data) throws -> Data {
        // 10-byte header + 8-byte trailer is the floor for a well-formed member; the magic bytes and
        // compression method are checked so a truncated or mislabelled object fails here rather than
        // deep inside zlib.
        guard data.count >= 18,
              data[data.startIndex] == 0x1f,
              data[data.startIndex + 1] == 0x8b,
              data[data.startIndex + 2] == 0x08,
              data[data.startIndex + 3] == 0x00 else {
            throw Error.invalidGzipData
        }

        let deflated = data.dropFirst(10).dropLast(8)
        do {
            return try (Data(deflated) as NSData).decompressed(using: .zlib) as Data
        } catch {
            throw Error.decompressionFailed
        }
    }
}

private extension GzipCodec {
    static func crc32(for data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xff)
            crc = crcTable[index] ^ (crc >> 8)
        }
        return crc ^ 0xffff_ffff
    }

    static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = (crc & 1) == 1 ? 0xedb8_8320 ^ (crc >> 1) : crc >> 1
        }
        return crc
    }
}
