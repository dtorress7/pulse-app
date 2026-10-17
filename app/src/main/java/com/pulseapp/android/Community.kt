package com.pulseapp.android

import android.content.Context
import com.pulseapp.android.data.ActivitySession
import com.pulseapp.android.data.AppDatabase
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.time.LocalDate
import java.time.OffsetDateTime
import java.time.ZoneId

/**
 * Comunidad (equipos, chat y clasificaciones entre amigos) sobre Supabase, sin librerías: REST con HttpURLConnection.
 * Igual que en iOS (Core/Community.swift): cada móvil entra con una cuenta anónima y los permisos del servidor
 * (supabase/comunidad.sql) hacen que cada uno solo vea a la gente de sus equipos.
 */
object CommunityConfig {
    /** Datos del proyecto de Supabase (públicos a propósito: la seguridad la ponen los permisos del servidor). */
    const val BUILT_IN_URL = ""
    const val BUILT_IN_KEY = ""

    private const val PREFS = "pulseapp_community"
    fun url(ctx: Context): String {
        val v = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("url", "") ?: ""
        return (v.ifEmpty { BUILT_IN_URL }).trim().trimEnd('/')
    }
    fun key(ctx: Context): String {
        val v = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("key", "") ?: ""
        return v.ifEmpty { BUILT_IN_KEY }.trim()
    }
    fun isConfigured(ctx: Context) = url(ctx).startsWith("https://") && key(ctx).length > 20
    fun set(ctx: Context, url: String, key: String) =
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString("url", url).putString("key", key).apply()
}

data class CTeam(val id: String, val name: String, val inviteCode: String, val createdBy: String, val createdAt: String) : java.io.Serializable
data class CMember(val teamId: String, val userId: String, val role: String, val joinedAt: String)
data class CProfile(val id: String, val name: String, val username: String)
data class CActivity(val type: String, val strain: Double)
data class CDayStat(
    val userId: String, val date: String, val strain: Double?, val kcal: Int?, val activities: List<CActivity>,
    val recovery: Int?, val hrv: Int?, val rhr: Int?, val sleepMinutes: Int?, val sleepScore: Int?, val updatedAt: String?
)
data class CMessage(val id: Long, val teamId: String, val userId: String, val body: String, val createdAt: String)

class CommunityException(msg: String) : Exception(msg)

/** Hora del servidor ("2026-10-17T16:02:31.123456+00:00") → ms unix. */
fun serverMillis(s: String): Long = try { OffsetDateTime.parse(s).toInstant().toEpochMilli() } catch (e: Exception) { 0L }

object CommunityApi {
    private const val PREFS = "pulseapp_community_session"
    private val mutex = Mutex()

    fun hasSession(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).contains("refresh")

    private fun JSONObject.str(k: String) = if (isNull(k)) "" else optString(k, "")
    private fun JSONObject.intOrNull(k: String): Int? = if (!has(k) || isNull(k)) null else optDouble(k).let { Math.round(it).toInt() }
    private fun JSONObject.dblOrNull(k: String): Double? = if (!has(k) || isNull(k)) null else optDouble(k)

    // ---------- Sesión ----------

    suspend fun userId(ctx: Context): String {
        token(ctx)
        return ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("user", "")!!
    }

    /** Token válido: renueva si caduca y, si nunca se ha entrado, crea la cuenta anónima. */
    private suspend fun token(ctx: Context): String = mutex.withLock {
        if (!CommunityConfig.isConfigured(ctx)) throw CommunityException("Comunidad sin configurar")
        val p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val refresh = p.getString("refresh", null)
        if (refresh != null) {
            if (System.currentTimeMillis() < p.getLong("expires_ms", 0L) - 60_000L) return@withLock p.getString("access", "")!!
            storeAuth(ctx, raw(ctx, "POST", "/auth/v1/token?grant_type=refresh_token", JSONObject().put("refresh_token", refresh).toString(), null))
        } else {
            storeAuth(ctx, raw(ctx, "POST", "/auth/v1/signup", JSONObject().put("data", JSONObject()).toString(), null))
        }
        p.getString("access", "")!!
    }

    private fun storeAuth(ctx: Context, text: String) {
        val o = try { JSONObject(text) } catch (e: Exception) { null }
        val access = o?.optString("access_token", "") ?: ""
        val refresh = o?.optString("refresh_token", "") ?: ""
        val id = o?.optJSONObject("user")?.optString("id", "") ?: ""
        if (access.isEmpty() || refresh.isEmpty() || id.isEmpty())
            throw CommunityException("No se pudo iniciar sesión en Comunidad. ¿Están activados los accesos anónimos en Supabase?")
        val expiresMs = System.currentTimeMillis() + ((o?.optDouble("expires_in", 3600.0) ?: 3600.0) * 1000).toLong()
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString("access", access).putString("refresh", refresh).putString("user", id).putLong("expires_ms", expiresMs).commit()
    }

    // ---------- HTTP ----------

    private suspend fun raw(ctx: Context, method: String, path: String, body: String?, auth: String?, prefer: String? = null): String =
        withContext(Dispatchers.IO) {
            val conn = URL(CommunityConfig.url(ctx) + path).openConnection() as HttpURLConnection
            try {
                conn.requestMethod = method
                conn.connectTimeout = 20_000
                conn.readTimeout = 20_000
                conn.setRequestProperty("apikey", CommunityConfig.key(ctx))
                if (auth != null) conn.setRequestProperty("Authorization", "Bearer $auth")
                conn.setRequestProperty("Content-Type", "application/json")
                if (prefer != null) conn.setRequestProperty("Prefer", prefer)
                if (body != null) {
                    conn.doOutput = true
                    conn.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
                }
                val code = conn.responseCode
                val stream = if (code >= 300) conn.errorStream else conn.inputStream
                val text = stream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() } ?: ""
                if (code >= 300) {
                    val o = try { JSONObject(text) } catch (e: Exception) { null }
                    val msg = o?.optString("message")?.takeIf { it.isNotEmpty() } ?: o?.optString("msg")?.takeIf { it.isNotEmpty() }
                        ?: o?.optString("error_description")?.takeIf { it.isNotEmpty() } ?: "Error $code del servidor"
                    throw CommunityException(msg)
                }
                text
            } catch (e: CommunityException) {
                throw e
            } catch (e: Exception) {
                throw CommunityException("Sin conexión con el servidor (${e.javaClass.simpleName})")
            } finally {
                conn.disconnect()
            }
        }

    private suspend fun rest(ctx: Context, method: String, path: String, body: String? = null, prefer: String? = null): String =
        raw(ctx, method, "/rest/v1/$path", body, token(ctx), prefer)

    private suspend fun array(ctx: Context, path: String): List<JSONObject> {
        val a = JSONArray(rest(ctx, "GET", path))
        return (0 until a.length()).map { a.getJSONObject(it) }
    }

    private fun nowIso() = java.time.Instant.now().toString()

    private fun team(o: JSONObject) = CTeam(o.str("id"), o.str("name"), o.str("invite_code"), o.str("created_by"), o.str("created_at"))

    // ---------- Perfil ----------

    suspend fun myProfile(ctx: Context): CProfile? {
        val id = userId(ctx)
        return array(ctx, "profiles?id=eq.$id&select=id,name,username").firstOrNull()?.let { CProfile(it.str("id"), it.str("name"), it.str("username")) }
    }

    suspend fun saveProfile(ctx: Context, name: String, username: String) {
        val id = userId(ctx)
        rest(ctx, "POST", "profiles", JSONObject().put("id", id).put("name", name).put("username", username).put("updated_at", nowIso()).toString(),
            "resolution=merge-duplicates,return=minimal")
    }

    // ---------- Equipos ----------

    suspend fun myTeams(ctx: Context): List<CTeam> =
        array(ctx, "teams?select=id,name,invite_code,created_by,created_at&order=created_at.asc").map { team(it) }

    suspend fun createTeam(ctx: Context, name: String): CTeam =
        team(JSONObject(rest(ctx, "POST", "rpc/create_team", JSONObject().put("p_name", name).toString())))

    suspend fun joinTeam(ctx: Context, code: String): CTeam =
        team(JSONObject(rest(ctx, "POST", "rpc/join_team", JSONObject().put("p_code", code).toString())))

    suspend fun leaveTeam(ctx: Context, teamId: String) {
        val id = userId(ctx)
        rest(ctx, "DELETE", "team_members?team_id=eq.$teamId&user_id=eq.$id")
    }

    suspend fun members(ctx: Context, teamId: String): List<CMember> =
        array(ctx, "team_members?team_id=eq.$teamId&select=team_id,user_id,role,joined_at&order=joined_at.asc")
            .map { CMember(it.str("team_id"), it.str("user_id"), it.str("role"), it.str("joined_at")) }

    suspend fun profiles(ctx: Context, ids: List<String>): List<CProfile> {
        if (ids.isEmpty()) return emptyList()
        return array(ctx, "profiles?id=in.(${ids.joinToString(",")})&select=id,name,username").map { CProfile(it.str("id"), it.str("name"), it.str("username")) }
    }

    // ---------- Datos del día ----------

    suspend fun stats(ctx: Context, ids: List<String>, from: String, to: String): List<CDayStat> {
        if (ids.isEmpty()) return emptyList()
        return array(ctx, "day_stats?user_id=in.(${ids.joinToString(",")})&date=gte.$from&date=lte.$to&select=*").map { o ->
            val acts = o.optJSONArray("activities")
            CDayStat(o.str("user_id"), o.str("date"), o.dblOrNull("strain"), o.intOrNull("kcal"),
                (0 until (acts?.length() ?: 0)).map { val a = acts!!.getJSONObject(it); CActivity(a.optString("type"), a.optDouble("strain", 0.0)) },
                o.intOrNull("recovery"), o.intOrNull("hrv"), o.intOrNull("rhr"), o.intOrNull("sleep_minutes"), o.intOrNull("sleep_score"),
                o.str("updated_at").ifEmpty { null })
        }
    }

    suspend fun upload(ctx: Context, rows: List<JSONObject>) {
        if (rows.isEmpty()) return
        val id = userId(ctx)
        val arr = JSONArray()
        rows.forEach { arr.put(JSONObject(it.toString()).put("user_id", id).put("updated_at", nowIso())) }
        rest(ctx, "POST", "day_stats?on_conflict=user_id,date", arr.toString(), "resolution=merge-duplicates,return=minimal")
    }

    // ---------- Chat ----------

    suspend fun messages(ctx: Context, teamId: String, after: Long?): List<CMessage> {
        val list = if (after != null) array(ctx, "messages?team_id=eq.$teamId&id=gt.$after&order=id.asc&select=*")
        else array(ctx, "messages?team_id=eq.$teamId&order=id.desc&limit=200&select=*").reversed()
        return list.map { CMessage(it.optLong("id"), it.str("team_id"), it.str("user_id"), it.str("body"), it.str("created_at")) }
    }

    suspend fun send(ctx: Context, teamId: String, text: String) {
        val id = userId(ctx)
        rest(ctx, "POST", "messages", JSONObject().put("team_id", teamId).put("user_id", id).put("body", text).toString(), "return=minimal")
    }
}

/**
 * Sube el resumen de hoy y de ayer (esfuerzo, actividades, calorías, recuperación, VFC, FCR, sueño) para que lo vean tus equipos.
 * Solo si ya entraste en Comunidad; como mucho cada 10 min si no ha cambiado nada.
 */
object CommunitySync {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    @Volatile private var running = false

    fun upload(ctx: Context, home: HomeData) {
        val app = ctx.applicationContext
        if (!home.isToday || !CommunityConfig.isConfigured(app) || !CommunityApi.hasSession(app) || running) return
        running = true
        scope.launch {
            try {
                val zone = ZoneId.systemDefault()
                val yesterday = home.date.minusDays(1)
                val rows = mutableListOf(row(home.day, home.sessions))
                home.records.firstOrNull { it.date == yesterday }?.let { y ->
                    val s = yesterday.atStartOfDay(zone).toInstant().toEpochMilli()
                    val e = home.date.atStartOfDay(zone).toInstant().toEpochMilli()
                    rows.add(row(y, AppDatabase.getInstance(app).activitySessionDao().getAll().filter { it.startMillis in s until e }))
                }
                val sig = rows.joinToString("|") { it.toString() }
                val p = app.getSharedPreferences("pulseapp_community", Context.MODE_PRIVATE)
                if (p.getString("last_sig", "") == sig && System.currentTimeMillis() - p.getLong("last_t", 0) < 600_000) return@launch
                CommunityApi.upload(app, rows)
                p.edit().putString("last_sig", sig).putLong("last_t", System.currentTimeMillis()).apply()
            } catch (e: Exception) {
            } finally {
                running = false
            }
        }
    }

    private fun row(d: DayRecord, sessions: List<ActivitySession>): JSONObject {
        val acts = JSONArray()
        sessions.sortedByDescending { it.strain }.forEach { acts.put(JSONObject().put("type", it.type).put("strain", Math.round(it.strain * 10) / 10.0)) }
        return JSONObject()
            .put("date", d.date.toString())
            .put("strain", d.strain?.let { Math.round(it * 10) / 10.0 } ?: JSONObject.NULL)
            .put("kcal", d.kcal?.let { Math.round(it).toInt() } ?: JSONObject.NULL)
            .put("activities", acts)
            .put("recovery", d.recovery ?: JSONObject.NULL)
            .put("hrv", d.hrv?.let { Math.round(it).toInt() } ?: JSONObject.NULL)
            .put("rhr", d.rhr ?: JSONObject.NULL)
            .put("sleep_minutes", d.sleepMinutes ?: JSONObject.NULL)
            .put("sleep_score", d.sleepScore ?: JSONObject.NULL)
    }
}

/** Cada lunes a las 17:00: campeones de la semana anterior (lun–dom) en esfuerzo, recuperación y sueño (medias). */
object WeeklyWinners {
    data class Entry(val key: String, val time: Long, val userId: String?, val body: String)

    fun entries(team: CTeam, stats: List<CDayStat>, username: (String) -> String): List<Entry> {
        val zone = ZoneId.systemDefault()
        val now = System.currentTimeMillis()
        val today = LocalDate.now(zone)
        val thisMonday = today.minusDays((today.dayOfWeek.value - 1).toLong())
        val created = serverMillis(team.createdAt)
        val out = mutableListOf<Entry>()
        for (k in 1..8) {
            val start = thisMonday.minusDays(7L * k)
            val end = start.plusDays(6)
            val post = start.plusDays(7).atTime(17, 0).atZone(zone).toInstant().toEpochMilli()
            if (post > now || post < created) continue
            val rows = stats.filter { val d = LocalDate.parse(it.date); !d.isBefore(start) && !d.isAfter(end) }
            fun best(pick: (CDayStat) -> Double?): Pair<String, Double>? =
                rows.mapNotNull { r -> pick(r)?.let { r.userId to it } }.groupBy({ it.first }, { it.second })
                    .map { (u, v) -> u to v.average() }.maxByOrNull { it.second }
            val lines = mutableListOf<String>()
            best { it.strain }?.let { lines.add("@${username(it.first)} — Esfuerzo prom. de ${Ui.comma(it.second)} 💪") }
            best { it.recovery?.toDouble() }?.let { lines.add("@${username(it.first)} — Recuperación prom. del ${Math.round(it.second)}% 🎯") }
            best { it.sleepScore?.toDouble() }?.let { lines.add("@${username(it.first)} — Calificación del sueño prom. del ${Math.round(it.second)}% 😴") }
            if (lines.isEmpty()) continue
            val range = "${start.dayOfMonth}/${start.monthValue} - ${end.dayOfMonth}/${end.monthValue}"
            out.add(Entry("w$start", post, null, "👑 ¡Felicidades a los campeones de la semana pasada! ($range)\n\n" + lines.joinToString("\n")))
        }
        return out
    }
}
