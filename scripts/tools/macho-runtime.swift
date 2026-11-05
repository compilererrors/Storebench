// Fingerprints the runtime of a Mach-O executable independently of link-time name tables.
// Usage: swift scripts/tools/macho-runtime.swift <file>
// Prints one line per architecture: "<cpu> <subtype> <symbol count> <runtime sha256>".
// Stripping symbols must leave every runtime fingerprint unchanged.
import CryptoKit
import Foundation

struct Failure: Error {}
let maximumBytes = 256 * 1024 * 1024

func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

extension Data {
    func u32be(_ at: Int) -> UInt32 { self[startIndex + at ..< startIndex + at + 4].reduce(0) { $0 << 8 | UInt32($1) } }
    func u32le(_ at: Int) -> UInt32 { self[startIndex + at ..< startIndex + at + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) } }
    func u64be(_ at: Int) -> UInt64 { self[startIndex + at ..< startIndex + at + 8].reduce(0) { $0 << 8 | UInt64($1) } }
    func u64le(_ at: Int) -> UInt64 { self[startIndex + at ..< startIndex + at + 8].reversed().reduce(0) { $0 << 8 | UInt64($1) } }
    func slice(_ at: Int, _ length: Int) -> Data { Data(self[startIndex + at ..< startIndex + at + length]) }
}

func check(_ offset: Int, _ length: Int, _ limit: Int) throws {
    guard offset >= 0, length >= 0, offset <= limit, length <= limit - offset else { throw Failure() }
}

struct Image { let cpu: UInt32; let subtype: UInt32; let symbols: UInt32; let runtime: String }

func runtime(_ bytes: Data) throws -> [Image] {
    guard bytes.count >= 32, bytes.count <= maximumBytes else { throw Failure() }
    var slices: [(offset: Int, size: Int, cpu: UInt32?, subtype: UInt32?)] = []
    let magic = bytes.u32be(0)
    if magic == 0xcafebabe || magic == 0xcafebabf {
        let count = Int(bytes.u32be(4)), width = magic == 0xcafebabe ? 20 : 32
        guard count >= 1, count <= 2 else { throw Failure() }
        try check(8, count * width, bytes.count)
        for index in 0..<count {
            let start = 8 + index * width
            let offset = width == 20 ? Int(bytes.u32be(start + 8)) : Int(bytes.u64be(start + 8))
            let size = width == 20 ? Int(bytes.u32be(start + 12)) : Int(bytes.u64be(start + 16))
            try check(offset, size, bytes.count)
            guard offset >= 8 + count * width, size >= 32,
                  !slices.contains(where: { offset < $0.offset + $0.size && $0.offset < offset + size }) else { throw Failure() }
            slices.append((offset, size, bytes.u32be(start), bytes.u32be(start + 4)))
        }
    } else { slices.append((0, bytes.count, nil, nil)) }
    var images: [Image] = []
    for slice in slices {
        let image = bytes.slice(slice.offset, slice.size)
        guard image.u32le(0) == 0xfeedfacf, image.u32le(12) == 2, image.u32le(24) & 4 != 0 else { throw Failure() }
        let cpu = image.u32le(4), subtype = image.u32le(8), commands = Int(image.u32le(16)), commandBytes = Int(image.u32le(20))
        guard [0x01000007, 0x0100000c].contains(cpu), slice.cpu == nil || (slice.cpu == cpu && slice.subtype == subtype),
              commands >= 1, commands <= 2048 else { throw Failure() }
        try check(32, commandBytes, image.count)
        var sections: [String] = [], payloads: [String] = [], loads: [String] = [], names = Set<String>()
        var offset = 32, symbols: UInt32?
        func data(_ start: Int, _ length: Int) throws -> String { try check(start, length, image.count); return digest(image.slice(start, length)) }
        func name(_ start: Int) -> String { String(decoding: image.slice(start, 16).prefix { $0 != 0 }, as: UTF8.self) }
        for _ in 0..<commands {
            try check(offset, 8, 32 + commandBytes)
            let command = image.u32le(offset), size = Int(image.u32le(offset + 4))
            guard size >= 8, size % 4 == 0 else { throw Failure() }
            try check(offset, size, 32 + commandBytes)
            if command == 0x19 {
                guard size >= 72 else { throw Failure() }
                let count = Int(image.u32le(offset + 64))
                guard count <= 2048, size == 72 + count * 80 else { throw Failure() }
                for section in 0..<count {
                    let start = offset + 72 + section * 80, segment = name(start + 16), sectionName = name(start), key = segment + "/" + sectionName
                    guard !segment.isEmpty, !sectionName.isEmpty, !names.contains(key) else { throw Failure() }
                    names.insert(key)
                    if segment == "__DWARF" { continue }
                    let length = Int(image.u64le(start + 40)), fileOffset = Int(image.u32le(start + 48)), flags = image.u32le(start + 64)
                    let zero = [1, 12, 18].contains(flags & 0xff)
                    let reserved = [68, 72, 76].map { String(image.u32le(start + $0)) }.joined(separator: ",")
                    let contents = zero ? "zero" : try data(fileOffset, length)
                    sections.append([segment, sectionName, String(image.u64le(start + 32)), String(length), String(image.u32le(start + 52)), String(flags), reserved, contents].joined(separator: "|"))
                }
            } else if command == 2 {
                guard size == 24, symbols == nil else { throw Failure() }
                let count = image.u32le(offset + 12)
                symbols = count
                try check(Int(image.u32le(offset + 8)), Int(count) * 16, image.count)
                try check(Int(image.u32le(offset + 16)), Int(image.u32le(offset + 20)), image.count)
            } else if command == 0x22 || command == 0x80000022 {
                guard size == 48 else { throw Failure() }
                for pair in stride(from: 8, to: 48, by: 8) {
                    let hash = try data(Int(image.u32le(offset + pair)), Int(image.u32le(offset + pair + 4)))
                    payloads.append("\(command)|\(pair)|\(hash)")
                }
            } else if [0x80000033, 0x80000034, 0x29, 0x1e].contains(command) {
                guard size == 16 else { throw Failure() }
                let hash = try data(Int(image.u32le(offset + 8)), Int(image.u32le(offset + 12)))
                payloads.append("\(command)|\(hash)")
            } else if [0xc, 0xd, 0x80000018, 0x8000001f, 0x20, 0x80000023, 0x8000001c, 0x80000028, 0x1b].contains(command) {
                loads.append("\(command)|" + digest(image.slice(offset + 8, size - 8)))
            }
            offset += size
        }
        guard offset == 32 + commandBytes, let symbols, sections.contains(where: { $0.hasPrefix("__TEXT|__text|") }), !payloads.isEmpty else { throw Failure() }
        let summary = ([String(cpu), String(subtype)] + sections + ["payloads"] + payloads + ["loads"] + loads).joined(separator: "\n")
        images.append(Image(cpu: cpu, subtype: subtype, symbols: symbols, runtime: digest(Data(summary.utf8))))
    }
    images.sort { $0.cpu < $1.cpu }
    guard Set(images.map(\.cpu)).count == images.count else { throw Failure() }
    return images
}

do {
    let arguments = CommandLine.arguments
    guard arguments.count == 2 else { throw Failure() }
    let url = URL(fileURLWithPath: arguments[1])
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true, (values.fileSize ?? .max) <= maximumBytes else { throw Failure() }
    for image in try runtime(try Data(contentsOf: url)) { print("\(image.cpu) \(image.subtype) \(image.symbols) \(image.runtime)") }
} catch {
    FileHandle.standardError.write(Data("Native executable symbol trimming must preserve its complete runtime.\n".utf8))
    exit(1)
}
