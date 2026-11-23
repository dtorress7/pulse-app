import Foundation
import Compression

/// Datos para calibrar (23/11, igual que Android `DataShare`): cada móvil sube sus archivos crudos (pulso, movimiento, pasos de la pulsera,
/// ediciones y cortes del sueño) a una carpeta privada con su ID en el almacén de Supabase (supabase/datos.sql). Solo el administrador
/// puede descargar las de los demás: en su app, Más → "Datos de amigos", que junta los trozos y comparte los archivos completos.
///
/// Se sube solo lo nuevo, en trozos de ≤ 8 MB que acaban en salto de línea, comprimidos (deflate sin cabecera, el mismo formato que
/// Android). Nombre: `<id>/<archivo>/<generación 3 cifras>-<desde el byte 12 cifras>-<bytes sin comprimir>.dfl`. Si el archivo se
/// reescribe (más corto, o el byte anterior al punto donde iba ya no es un salto de línea) empieza una generación nueva desde 0.
enum DataShare {
    static let bucket = "pulse-data"
    static let files = ["hr_log.csv", "motion_minutes.csv", "band_steps.csv", "sleep_edits.csv", "sleep_caps.csv"]
    private static let chunk = 8 * 1024 * 1024
    private static let minInterval: TimeInterval = 3 * 3600
    private static let d = UserDefaults.standard
    private static let lock = NSLock()
    private static var running = false

    static var enabled: Bool {
        get { d.object(forKey: "pulseapp_datashare_enabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "pulseapp_datashare_enabled") }
    }
    static var lastUpload: Double { d.double(forKey: "pulseapp_datashare_last_ok") }

    /// Sube lo nuevo como mucho cada 3 h (lo llama Inicio al calcular).
    static func maybeUpload(force: Bool = false) {
        guard enabled, CommunityConfig.isConfigured else { return }
        lock.lock()
        let now = Date().timeIntervalSince1970
        if running || (!force && now - d.double(forKey: "pulseapp_datashare_last_try") < minInterval) { lock.unlock(); return }
        running = true
        d.set(now, forKey: "pulseapp_datashare_last_try")
        lock.unlock()
        Task.detached(priority: .utility) {
            do {
                try await uploadAll()
                d.set(Date().timeIntervalSince1970, forKey: "pulseapp_datashare_last_ok")
            } catch {}
            lock.lock(); running = false; lock.unlock()
        }
    }

    private static func uploadAll() async throws {
        let uid = try await CommunityAPI.shared.userId()
        for name in files {
            let url = AppPaths.file(name)
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value, size > 0,
                  let h = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? h.close() }
            var gen = d.integer(forKey: "pulseapp_datashare_\(name).gen")
            var off = Int64(d.integer(forKey: "pulseapp_datashare_\(name).off"))
            if off > size || (off > 0 && byteAt(h, off - 1) != 0x0A) { gen += 1; off = 0 }
            while off < size {
                let len = Int(min(Int64(chunk), size - off))
                try h.seek(toOffset: UInt64(off))
                guard let buf = try h.read(upToCount: len), !buf.isEmpty else { break }
                guard let nl = buf.lastIndex(of: 0x0A) else { break }   // línea a medio escribir: la próxima vez
                let cut = buf.distance(from: buf.startIndex, to: nl) + 1
                let raw = buf.prefix(cut)
                guard let comp = DataShareCodec.deflate(Data(raw)) else { break }
                try await CommunityAPI.shared.storageUpload(bucket: bucket, path: "\(uid)/\(name)/\(DataShareCodec.chunkName(gen, off, cut))",
                                                            data: comp, contentType: "application/octet-stream")
                off += Int64(cut)
                d.set(gen, forKey: "pulseapp_datashare_\(name).gen")
                d.set(Int(off), forKey: "pulseapp_datashare_\(name).off")
            }
        }
        let prof: CProfile? = (try? await CommunityAPI.shared.myProfile()) ?? nil
        let profileName = prof?.name ?? ""
        let info: [String: Any] = ["name": profileName.isEmpty ? "Sin nombre" : profileName, "platform": "iPhone",
                                   "version": BuildInfo.text, "updated": Int64(Date().timeIntervalSince1970 * 1000)]
        let data = try JSONSerialization.data(withJSONObject: info)
        try await CommunityAPI.shared.storageUpload(bucket: bucket, path: "\(uid)/info.json", data: data, contentType: "application/json")
    }

    // MARK: - Administrador

    struct Person: Identifiable, Hashable {
        let uid: String; let name: String; let platform: String; let updated: Int64
        var id: String { uid }
    }

    static func isAdmin() async throws -> Bool { try await CommunityAPI.shared.rpcBool("is_data_admin") }
    static func claimAdmin() async throws -> Bool { try await CommunityAPI.shared.rpcBool("claim_data_admin") }

    static func people() async throws -> [Person] {
        let folders = try await CommunityAPI.shared.storageList(bucket: bucket, prefix: "")
            .filter { $0["id"] == nil || $0["id"] is NSNull }.compactMap { $0["name"] as? String }.filter { !$0.isEmpty }
        var out = [Person]()
        for uid in folders {
            var o: [String: Any]? = nil
            if let data = try? await CommunityAPI.shared.storageDownload(bucket: bucket, path: "\(uid)/info.json") {
                o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            let name = (o?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? String(uid.prefix(8))
            let updated = (o?["updated"] as? NSNumber)?.int64Value ?? 0
            out.append(Person(uid: uid, name: name, platform: o?["platform"] as? String ?? "", updated: updated))
        }
        return out.sorted { $0.updated > $1.updated }
    }

    /// Descarga (solo los trozos que faltan, guardados en la carpeta de la app) y junta los archivos completos de [person].
    static func download(_ person: Person, progress: @escaping (String) -> Void) async throws -> [URL] {
        let base = AppPaths.baseDir.appendingPathComponent("amigos", isDirectory: true)
        let cache = base.appendingPathComponent("trozos/\(person.uid)", isDirectory: true)
        let outDir = base.appendingPathComponent("archivos", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let tag = safe(person.name)
        var out = [URL]()
        for name in files {
            let listed = try await CommunityAPI.shared.storageList(bucket: bucket, prefix: "\(person.uid)/\(name)/")
            let parts = DataShareCodec.pickChunks(listed.compactMap { ($0["name"] as? String).flatMap(DataShareCodec.parseChunk) })
            if parts.isEmpty { continue }
            let target = outDir.appendingPathComponent("\(tag)_\(name)")
            FileManager.default.createFile(atPath: target.path, contents: nil)
            guard let w = try? FileHandle(forWritingTo: target) else { continue }
            defer { try? w.close() }
            for (i, c) in parts.enumerated() {
                progress("\(name): \(i + 1) de \(parts.count)")
                let local = cache.appendingPathComponent("\(name)_\(c.file)")
                let comp: Data
                if let saved = try? Data(contentsOf: local) { comp = saved } else {
                    comp = try await CommunityAPI.shared.storageDownload(bucket: bucket, path: "\(person.uid)/\(name)/\(c.file)")
                    try? comp.write(to: local)
                }
                guard let raw = DataShareCodec.inflate(comp, rawLen: c.rawLen) else { throw CommunityError(message: "Trozo dañado: \(c.file)") }
                w.write(raw)
            }
            out.append(target)
        }
        return out
    }

    private static func byteAt(_ h: FileHandle, _ pos: Int64) -> UInt8? {
        guard (try? h.seek(toOffset: UInt64(pos))) != nil, let b = try? h.read(upToCount: 1), let x = b.first else { return nil }
        return x
    }

    private static func safe(_ s: String) -> String {
        let t = String(s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }.prefix(20))
        return t.isEmpty ? "amigo" : t
    }
}
