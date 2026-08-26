//
//  ZipArchiveWriter.swift
//  ScanVault
//

import Foundation

/// Minimal, dependency-free ZIP writer ("stored" entries — data copied
/// verbatim).
///
/// Used by the GDPR export flow to bundle PDFs, transcriptions and JSON
/// metadata into one portable archive. Stored-mode keeps the implementation
/// auditable (no compression side channels) and is universally readable by
/// Finder, Files and unzip. Sizes stay reasonable because scanned PDFs are
/// already internally compressed.
nonisolated enum ZipArchiveWriter {

    struct Entry: Sendable {
        /// Archive path, e.g. `"PDFs/invoice-2026.pdf"`. ASCII-safe when possible.
        let name: String
        let data: Data
    }

    // MARK: - Errors

    enum ZipWriterError: LocalizedError {
        case unsupportedName(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedName(let name):
                "Archive entry name contains characters that are unsafe for export: \(name)"
            }
        }
    }

    // MARK: - API

    /// Writes `entries` into a ZIP archive at `url`, replacing any old file.
    @discardableResult
    static func write(_ entries: [Entry], to url: URL) throws -> URL {
        guard entries.allSatisfy({ Self.isSafeName($0.name) }) else {
            throw ZipWriterError.unsupportedName(entries.first(where: { !Self.isSafeName($0.name) })!.name)
        }

        var output = Data()
        var centralDirectory = Data()
        var entryCount: UInt16 = 0

        let (dosTime, dosDate) = Self.dosDateTime(from: .now)

        for entry in entries {
            let nameBytes = Array(entry.name.utf8)
            let crc = Self.crc32(of: entry.data)

            let localHeaderOffset = UInt32(output.count)
            let localOffset = output.count

            // --- Local file header -------------------------------------------
            output.appendLE(UInt32(0x0403_4B50))
            output.appendLE(UInt16(20))          // version needed
            output.appendLE(UInt16(0x0800))      // UTF-8 name flag
            output.appendLE(UInt16(0))           // 0 = stored
            output.appendLE(dosTime)
            output.appendLE(dosDate)
            output.appendLE(crc)
            output.appendLE(UInt32(entry.data.count))
            output.appendLE(UInt32(entry.data.count))
            output.appendLE(UInt16(nameBytes.count))
            output.appendLE(UInt16(0))
            output.append(contentsOf: nameBytes)
            output.append(entry.data)

            // --- Central directory record ------------------------------------
            centralDirectory.appendLE(UInt32(0x0201_4B50))
            centralDirectory.appendLE(UInt16(20))       // version made by
            centralDirectory.appendLE(UInt16(20))       // version needed
            centralDirectory.appendLE(UInt16(0x0800))
            centralDirectory.appendLE(UInt16(0))
            centralDirectory.appendLE(dosTime)
            centralDirectory.appendLE(dosDate)
            centralDirectory.appendLE(crc)
            centralDirectory.appendLE(UInt32(entry.data.count))
            centralDirectory.appendLE(UInt32(entry.data.count))
            centralDirectory.appendLE(UInt16(nameBytes.count))
            centralDirectory.appendLE(UInt16(0)) // extra
            centralDirectory.appendLE(UInt16(0)) // comment
            centralDirectory.appendLE(UInt16(0)) // disk number start
            centralDirectory.appendLE(UInt16(0)) // internal attrs
            centralDirectory.appendLE(UInt32(0)) // external attrs
            centralDirectory.appendLE(localHeaderOffset)
            centralDirectory.append(contentsOf: nameBytes)

            entryCount += 1
            _ = localOffset // headers are appended sequentially
        }

        let centralDirectoryOffset = UInt32(output.count)
        let centralDirectorySize = UInt32(centralDirectory.count)
        output.append(centralDirectory)

        // --- End of central directory ----------------------------------------
        output.appendLE(UInt32(0x0605_4B50))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(0))
        output.appendLE(entryCount)
        output.appendLE(entryCount)
        output.appendLE(centralDirectorySize)
        output.appendLE(centralDirectoryOffset)
        output.appendLE(UInt16(0))

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try output.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Internals

    /// Rejects traversal attempts and control characters before anything is
    /// touched on disk — the archive is built purely in memory, but the export
    /// file names themselves must also be share-safe.
    private static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty
            && !name.contains("../")
            && !name.hasPrefix("/")
            && !name.contains("\\")
            && name.allSatisfy { !$0.isNewline && $0.asciiValue.map { $0 >= 32 && $0 != 127 } ?? true }
    }

    /// CRC-32 (IEEE 802.3 polynomial), the checksum every ZIP reader requires.
    private static func crc32(of data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for index in 0..<256 {
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1 == 1) ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
            }
            table[index] = value
        }

        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static func dosDateTime(from date: Date) -> (UInt16, UInt16) {
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, parts.year ?? 1980)
        let dosDate = UInt16((year - 1980) << 9 | (parts.month ?? 1) << 5 | (parts.day ?? 1))
        let dosTime = UInt16((parts.hour ?? 0) << 11 | (parts.minute ?? 0) << 5 | (parts.second ?? 0) / 2)
        return (dosTime, dosDate)
    }
}

// MARK: - Little-endian appends

private nonisolated extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8(value >> 24))
    }
}
