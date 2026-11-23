package com.pulseapp.android

import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.RandomAccessFile
import java.util.zip.Deflater
import java.util.zip.Inflater

/**
 * Datos para calibrar (23/11, igual que iOS `DataShare`): cada móvil sube sus archivos crudos (pulso, movimiento, pasos de la pulsera,
 * ediciones y cortes del sueño) a una carpeta privada con su ID en el almacén de Supabase (supabase/datos.sql). Solo el administrador
 * puede descargar las de los demás: en su app, Más → "Datos de amigos", que junta los trozos y comparte los archivos completos.
 *
 * Se sube solo lo nuevo: cada archivo se manda en trozos de ≤ 8 MB que acaban en salto de línea, comprimidos (deflate sin cabecera).
 * Nombre de cada trozo: `<id>/<archivo>/<generación 3 cifras>-<desde el byte 12 cifras>-<bytes sin comprimir>.dfl`. Si el archivo
 * se reescribe (más corto, o el byte anterior al punto donde iba ya no es un salto de línea), se empieza una generación nueva desde 0.
 */
object DataShare {
    const val BUCKET = "pulse-data"
    val FILES = listOf("hr_log.csv", "motion_minutes.csv", "band_steps.csv", "band_battery.csv", "sleep_edits.csv", "sleep_caps.csv",
        "whoop_bio_log.csv", "whoop_service_log.txt", "strength_logs.tsv")
    private const val PREFS = "pulseapp_datashare"
    private const val CHUNK = 8 * 1024 * 1024
    private const val MIN_INTERVAL_MS = 3 * 3_600_000L
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    @Volatile private var running = false

    fun enabled(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean("enabled", true)
    fun setEnabled(ctx: Context, on: Boolean) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean("enabled", on).apply()
    fun lastUpload(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getLong("last_ok", 0L)

    /** Sube lo nuevo como mucho cada 3 h (lo llaman Inicio y el servicio de la pulsera). */
    fun maybeUpload(ctx: Context, force: Boolean = false) {
        val app = ctx.applicationContext
        if (!enabled(app) || !CommunityConfig.isConfigured(app) || running) return
        val p = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (!force && System.currentTimeMillis() - p.getLong("last_try", 0L) < MIN_INTERVAL_MS) return
        running = true
        p.edit().putLong("last_try", System.currentTimeMillis()).apply()
        scope.launch {
            try {
                uploadAll(app)
                p.edit().putLong("last_ok", System.currentTimeMillis()).apply()
            } catch (_: Exception) {
            } finally {
                running = false
            }
        }
    }

    private suspend fun uploadAll(ctx: Context) {
        val dir = ctx.getExternalFilesDir(null) ?: return
        val uid = CommunityApi.userId(ctx)
        val p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        for (name in FILES) {
            val f = File(dir, name)
            if (!f.exists() || f.length() == 0L) continue
            var gen = p.getInt("$name.gen", 0)
            var off = p.getLong("$name.off", 0L)
            val size = f.length()
            if (off > size || (off > 0 && byteAt(f, off - 1) != '\n'.code.toByte())) { gen++; off = 0L }
            RandomAccessFile(f, "r").use { raf ->
                while (off < size) {
                    val len = minOf(CHUNK.toLong(), size - off).toInt()
                    val buf = ByteArray(len)
                    raf.seek(off); raf.readFully(buf)
                    val cut = lastNewline(buf) + 1
                    if (cut <= 0) break   // línea a medio escribir: la próxima vez
                    CommunityApi.storageUpload(ctx, BUCKET, "$uid/$name/${chunkName(gen, off, cut)}", deflate(buf, cut), "application/octet-stream")
                    off += cut
                    p.edit().putInt("$name.gen", gen).putLong("$name.off", off).apply()
                }
            }
        }
        val name = runCatching { CommunityApi.myProfile(ctx)?.name }.getOrNull()?.takeIf { it.isNotBlank() } ?: "Sin nombre"
        val info = JSONObject().put("name", name).put("platform", "Android").put("version", BuildConfig.BUILD_INFO)
            .put("updated", System.currentTimeMillis()).toString()
        CommunityApi.storageUpload(ctx, BUCKET, "$uid/info.json", info.toByteArray(Charsets.UTF_8), "application/json")
    }

    // ---------- Administrador ----------

    data class Person(val uid: String, val name: String, val platform: String, val updated: Long)

    suspend fun isAdmin(ctx: Context): Boolean = CommunityApi.rpcBool(ctx, "is_data_admin")
    suspend fun claimAdmin(ctx: Context): Boolean = CommunityApi.rpcBool(ctx, "claim_data_admin")
    suspend fun myId(ctx: Context): String = CommunityApi.userId(ctx)

    suspend fun people(ctx: Context): List<Person> {
        val folders = CommunityApi.storageList(ctx, BUCKET, "").filter { it.isNull("id") }.map { it.optString("name") }.filter { it.isNotEmpty() }
        return folders.map { uid ->
            val o = runCatching { JSONObject(String(CommunityApi.storageDownload(ctx, BUCKET, "$uid/info.json"), Charsets.UTF_8)) }.getOrNull()
            Person(uid, o?.optString("name")?.takeIf { it.isNotEmpty() } ?: uid.take(8), o?.optString("platform") ?: "", o?.optLong("updated") ?: 0L)
        }.sortedByDescending { it.updated }
    }

    /** Descarga (solo los trozos que faltan, guardados en la carpeta de la app) y junta los archivos completos de [person]. */
    suspend fun download(ctx: Context, person: Person, progress: (String) -> Unit): List<File> {
        val base = ctx.getExternalFilesDir("amigos") ?: throw CommunityException("Sin espacio en el móvil")
        val cache = File(base, "trozos/${person.uid}").apply { mkdirs() }
        val outDir = File(base, "archivos").apply { mkdirs() }
        val tag = safe(person.name)
        val out = ArrayList<File>()
        for (name in FILES) {
            val chunks = CommunityApi.storageList(ctx, BUCKET, "${person.uid}/$name/").mapNotNull { parseChunk(it.optString("name")) }
            val parts = pickChunks(chunks)
            if (parts.isEmpty()) continue
            val target = File(outDir, "${tag}_$name")
            target.outputStream().use { os ->
                for ((i, c) in parts.withIndex()) {
                    progress("$name: ${i + 1} de ${parts.size}")
                    val local = File(cache, "${name}_${c.file}")
                    val comp = if (local.exists()) local.readBytes()
                    else CommunityApi.storageDownload(ctx, BUCKET, "${person.uid}/$name/${c.file}").also { local.writeBytes(it) }
                    os.write(inflate(comp, c.rawLen))
                }
            }
            out.add(target)
        }
        return out
    }

    // ---------- Piezas puras (probadas en JVM) ----------

    data class Chunk(val file: String, val gen: Int, val offset: Long, val rawLen: Int)

    fun chunkName(gen: Int, offset: Long, rawLen: Int) = String.format(java.util.Locale.US, "%03d-%012d-%d.dfl", gen, offset, rawLen)

    fun parseChunk(file: String): Chunk? {
        val m = Regex("^(\\d{3})-(\\d{12})-(\\d+)\\.dfl$").find(file) ?: return null
        return Chunk(file, m.groupValues[1].toInt(), m.groupValues[2].toLong(), m.groupValues[3].toInt())
    }

    /** Trozos de la última generación, en orden y seguidos desde el byte 0 (si falta uno, se para ahí). */
    fun pickChunks(all: List<Chunk>): List<Chunk> {
        val gen = all.maxOfOrNull { it.gen } ?: return emptyList()
        val sorted = all.filter { it.gen == gen }.sortedBy { it.offset }
        val out = ArrayList<Chunk>()
        var next = 0L
        for (c in sorted) {
            if (c.offset < next) continue        // repetido
            if (c.offset > next) break           // hueco
            out.add(c); next = c.offset + c.rawLen
        }
        return out
    }

    fun lastNewline(buf: ByteArray): Int {
        for (i in buf.indices.reversed()) if (buf[i] == '\n'.code.toByte()) return i
        return -1
    }

    fun deflate(buf: ByteArray, len: Int): ByteArray {
        val d = Deflater(6, true)
        d.setInput(buf, 0, len); d.finish()
        val bos = ByteArrayOutputStream(len / 4 + 64)
        val tmp = ByteArray(64 * 1024)
        while (!d.finished()) { val n = d.deflate(tmp); bos.write(tmp, 0, n) }
        d.end()
        return bos.toByteArray()
    }

    fun inflate(comp: ByteArray, rawLen: Int): ByteArray {
        val inf = Inflater(true)
        inf.setInput(comp + ByteArray(1))   // deflate sin cabecera: Inflater pide un byte de relleno al final
        val out = ByteArray(rawLen)
        var n = 0
        while (n < rawLen) {
            val k = inf.inflate(out, n, rawLen - n)
            if (k == 0 && (inf.finished() || inf.needsInput())) break
            n += k
        }
        inf.end()
        return if (n == rawLen) out else out.copyOf(n)
    }

    private fun byteAt(f: File, pos: Long): Byte = RandomAccessFile(f, "r").use { it.seek(pos); it.readByte() }

    private fun safe(s: String) = s.lowercase().map { if (it.isLetterOrDigit()) it else '_' }.joinToString("").take(20).ifEmpty { "amigo" }
}
