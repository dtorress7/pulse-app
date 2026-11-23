import Foundation
import Compression

/// Formato de los trozos de "Datos para calibrar" (23/11, igual que Android `DataShare`): deflate sin cabecera (RFC 1951) y nombre
/// `<generación 3 cifras>-<desde el byte 12 cifras>-<bytes sin comprimir>.dfl`. Aparte de DataShare para poder probarlo en CI.
enum DataShareCodec {
    struct Chunk { let file: String; let gen: Int; let offset: Int64; let rawLen: Int }

    static func chunkName(_ gen: Int, _ offset: Int64, _ rawLen: Int) -> String {
        String(format: "%03d-%012lld-%d.dfl", gen, offset, rawLen)
    }

    static func parseChunk(_ file: String) -> Chunk? {
        guard file.hasSuffix(".dfl") else { return nil }
        let p = file.dropLast(4).split(separator: "-")
        guard p.count == 3, p[0].count == 3, p[1].count == 12, let g = Int(p[0]), let o = Int64(p[1]), let l = Int(p[2]) else { return nil }
        return Chunk(file: file, gen: g, offset: o, rawLen: l)
    }

    /// Trozos de la última generación, en orden y seguidos desde el byte 0 (si falta uno, se para ahí).
    static func pickChunks(_ all: [Chunk]) -> [Chunk] {
        guard let gen = all.map({ $0.gen }).max() else { return [] }
        var out = [Chunk](); var next: Int64 = 0
        for c in all.filter({ $0.gen == gen }).sorted(by: { $0.offset < $1.offset }) {
            if c.offset < next { continue }
            if c.offset > next { break }
            out.append(c); next = c.offset + Int64(c.rawLen)
        }
        return out
    }

    static func deflate(_ raw: Data) -> Data? {
        let cap = raw.count + raw.count / 10 + 1024
        var dst = [UInt8](repeating: 0, count: cap)
        let n = raw.withUnsafeBytes { sp in
            dst.withUnsafeMutableBufferPointer { dp in
                compression_encode_buffer(dp.baseAddress!, cap, sp.bindMemory(to: UInt8.self).baseAddress!, raw.count, nil, COMPRESSION_ZLIB)
            }
        }
        return n > 0 ? Data(dst.prefix(n)) : nil
    }

    static func inflate(_ comp: Data, rawLen: Int) -> Data? {
        var dst = [UInt8](repeating: 0, count: max(rawLen, 1))
        let n = comp.withUnsafeBytes { sp in
            dst.withUnsafeMutableBufferPointer { dp in
                compression_decode_buffer(dp.baseAddress!, rawLen, sp.bindMemory(to: UInt8.self).baseAddress!, comp.count, nil, COMPRESSION_ZLIB)
            }
        }
        return n == rawLen ? Data(dst.prefix(n)) : nil
    }

}
