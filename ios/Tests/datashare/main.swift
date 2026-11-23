import Foundation

// Comprueba que el iPhone lee los trozos que sube Android (y al revés: mismo formato deflate sin cabecera) — 23/11
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let raw = try! Data(contentsOf: dir.appendingPathComponent("raw.csv"))
let names = try! FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("chunks").path)
var all = names.compactMap(DataShareCodec.parseChunk)
// un trozo repetido y uno de una generación vieja no deben cambiar nada
all.append(DataShareCodec.Chunk(file: names[0], gen: 0, offset: 0, rawLen: all.first { $0.offset == 0 }!.rawLen))
let parts = DataShareCodec.pickChunks(all)
var out = Data()
for c in parts {
    let comp = try! Data(contentsOf: dir.appendingPathComponent("chunks").appendingPathComponent(c.file))
    guard let r = DataShareCodec.inflate(comp, rawLen: c.rawLen) else { print("FALLO: no se pudo descomprimir \(c.file)"); exit(1) }
    out.append(r)
}
guard out == raw else { print("FALLO: reconstruido \(out.count) bytes, esperado \(raw.count)"); exit(1) }
// ida y vuelta en Swift
guard let comp = DataShareCodec.deflate(raw), let back = DataShareCodec.inflate(comp, rawLen: raw.count), back == raw else {
    print("FALLO: ida y vuelta en Swift"); exit(1)
}
guard DataShareCodec.chunkName(2, 1234, 99) == "002-000000001234-99.dfl" else { print("FALLO: nombre \(DataShareCodec.chunkName(2, 1234, 99))"); exit(1) }
print("OK: \(parts.count) trozos de Android → \(out.count) bytes iguales; Swift comprime \(raw.count) → \(comp.count)")
