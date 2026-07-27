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
        case checksumMismatch
        case sizeMismatch
        case decompressedTooLarge

        var errorDescription: String? {
            switch self {
            case .compressionFailed: "Failed to compress the heart-rate series."
            case .invalidGzipData: "The heart-rate series is not valid gzip data."
            case .decompressionFailed: "Failed to decompress the heart-rate series."
            case .checksumMismatch: "The heart-rate series failed its integrity check."
            case .sizeMismatch: "The heart-rate series is not the length it claims to be."
            case .decompressedTooLarge: "The heart-rate series is larger than the allowed size."
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

    /// Inflate a gzip member and *verify it*.
    ///
    /// The trailer `compress` writes is not decoration: silently trusting a corrupted or truncated
    /// object would decode into plausible-looking garbage and chart it as measured heart rate. So the
    /// CRC-32 and the length are both checked against what actually came out, and a mismatch throws
    /// rather than returning data.
    ///
    /// `maximumDecompressedBytes` bounds the *output*. Bounding the compressed object alone leaves a
    /// crafted or truncated member free to expand without limit, so the declared size is screened
    /// before inflating. ISIZE is only the low 32 bits of the original length, so that screen is a
    /// cheap pre-filter; the check against the real output length below is the one that decides.
    static func decompress(_ data: Data, maximumDecompressedBytes: Int64? = nil) throws -> Data {
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

        let trailer = data.suffix(8)
        let storedCRC = Self.littleEndianUInt32(trailer.prefix(4))
        let declaredSize = Self.littleEndianUInt32(trailer.suffix(4))

        if let maximumDecompressedBytes, Int64(declaredSize) > maximumDecompressedBytes {
            throw Error.decompressedTooLarge
        }

        let deflated = data.dropFirst(10).dropLast(8)
        let inflated: Data
        do {
            inflated = try (Data(deflated) as NSData).decompressed(using: .zlib) as Data
        } catch {
            throw Error.decompressionFailed
        }

        if let maximumDecompressedBytes, Int64(inflated.count) > maximumDecompressedBytes {
            throw Error.decompressedTooLarge
        }
        guard UInt32(truncatingIfNeeded: inflated.count) == declaredSize else { throw Error.sizeMismatch }
        guard Self.crc32(for: inflated) == storedCRC else { throw Error.checksumMismatch }
        return inflated
    }
}

private extension GzipCodec {
    static func littleEndianUInt32(_ bytes: Data) -> UInt32 {
        bytes.reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

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
