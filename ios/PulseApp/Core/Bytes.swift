import Foundation

/// Lectura de enteros y decimales little-endian de un [UInt8] (las tramas de la WHOOP son así).
enum Bytes {
    static func u16(_ b: [UInt8], _ o: Int) -> Int {
        return Int(b[o]) | (Int(b[o + 1]) << 8)
    }

    static func s16(_ b: [UInt8], _ o: Int) -> Int {
        let v = u16(b, o)
        return v >= 0x8000 ? v - 0x10000 : v
    }

    static func u32(_ b: [UInt8], _ o: Int) -> Int64 {
        var v: Int64 = Int64(b[o])
        v |= Int64(b[o + 1]) << 8
        v |= Int64(b[o + 2]) << 16
        v |= Int64(b[o + 3]) << 24
        return v
    }

    static func f32(_ b: [UInt8], _ o: Int) -> Float {
        let bits = UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
        return Float(bitPattern: bits)
    }

    static func hex(_ bytes: [UInt8], separator: String = " ") -> String {
        return bytes.map { String(format: "%02X", $0) }.joined(separator: separator)
    }

    static func fromHex(_ hex: String) -> [UInt8] {
        var out = [UInt8]()
        let chars = Array(hex.utf8)
        var i = 0
        while i + 1 < chars.count {
            let hi = nibble(chars[i]); let lo = nibble(chars[i + 1])
            out.append(UInt8((hi << 4) | lo))
            i += 2
        }
        return out
    }

    private static func nibble(_ c: UInt8) -> Int {
        switch c {
        case 48...57: return Int(c) - 48
        case 65...70: return Int(c) - 55
        case 97...102: return Int(c) - 87
        default: return 0
        }
    }
}

/// CRC de las tramas: CRC16-Modbus para la cabecera y CRC32 (zlib) para el cuerpo.
enum Crc {
    private static let table32: [UInt32] = {
        var t = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            t[i] = c
        }
        return t
    }()

    static func crc32(_ data: [UInt8], from: Int = 0, count: Int? = nil) -> UInt32 {
        let end = count != nil ? from + count! : data.count
        var c: UInt32 = 0xFFFFFFFF
        var i = from
        while i < end {
            c = table32[Int((c ^ UInt32(data[i])) & 0xFF)] ^ (c >> 8)
            i += 1
        }
        return c ^ 0xFFFFFFFF
    }

    static func crc16Modbus(_ data: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for b in data {
            crc ^= UInt16(b)
            for _ in 0..<8 {
                if (crc & 1) != 0 { crc = (crc >> 1) ^ 0xA001 } else { crc = crc >> 1 }
            }
        }
        return crc
    }
}
