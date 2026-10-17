package com.pulseapp.android

import android.content.Context
import com.pulseapp.android.data.ActivitySession
import com.pulseapp.android.data.AppDatabase
import com.pulseapp.android.data.DailyMetrics
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.BitSet
import java.util.Calendar
import java.util.Locale
import kotlin.math.abs
import kotlin.math.sqrt

/**
 * Todo lo que enseña Inicio con el aspecto de WHOOP (17/10), para HOY (en directo) o para un día pasado
 * (con lo guardado en daily_metrics). Las fórmulas son las mismas de siempre (Formulas, SleepPlanner,
 * BaselineProvider): aquí solo se reúnen y se comparan con tu media de los 30 días anteriores.
 */
data class DayRecord(
    val date: LocalDate,
    val hrv: Double?, val rhr: Int?, val resp: Double?,
    val sleepMinutes: Int?, val efficiency: Int?,
    val sleepStartMinute: Int?, val sleepEndMinute: Int?,
    val strain: Double?, val recovery: Int?, val sleepScore: Int?,
    /** Lo que necesitas dormir la noche que empieza ese día. */
    val needTonight: Int?,
    /** Deuda de sueño tras la noche que termina ese día. */
    val debt: Int?,
    val consistency: Int?, val steps: Int?, val kcal: Double?, val vo2: Double?
)

enum class Trend { UP, DOWN, SAME }

/** Fila de "Mi panel de control": [good] true = verde, false = naranja, null = gris (neutro). */
data class PanelRow(
    val key: String, val label: String, val iconRes: Int,
    val value: String, val average: String?, val trend: Trend?, val good: Boolean?
)

/** Señal del Monitor de salud con su rango habitual. [ok] null = aún sin rango (menos de 3 noches). */
data class VitalStatus(
    val key: String, val label: String, val iconRes: Int, val value: Double?, val unit: String, val decimals: Int,
    val lo: Double?, val hi: Double?, val goodWhenHigh: Boolean, val ok: Boolean?
)

data class WeekPoint(val date: LocalDate, val strain: Double?, val recovery: Int?)

data class HomeData(
    val date: LocalDate,
    val isToday: Boolean,
    val summary: DailySummary?,
    val day: DayRecord,
    val vitals: List<VitalStatus>,
    val healthOk: Int,
    val healthTotal: Int,
    val stressScore: Float?,
    val stressLevel: String,
    val stressMinute: Int?,
    val stressSeries: List<StressPoint>,
    val stressFrom: Long,
    val stressTo: Long,
    val sleepFromMillis: Long?,
    val sleepToMillis: Long?,
    val sessions: List<ActivitySession>,
    val bedtime: String?,
    val wakeMinute: Int,
    val panel: List<PanelRow>,
    val week: List<WeekPoint>,
    val streak: Int,
    val insight: String,
    val baselineReady: Boolean,
    val profileMissing: Boolean
)

object PanelKeys {
    const val HRV = "hrv"; const val RHR = "rhr"; const val STEPS = "steps"; const val Z13 = "z13"; const val Z45 = "z45"
    const val STRENGTH = "strength"; const val VO2 = "vo2"; const val KCAL = "kcal"; const val STRESS = "stress_card"
    const val STRAIN_RECOVERY = "strain_recovery_card"; const val REGULARITY = "regularity"; const val NEED = "need"
    const val STRAIN = "strain"; const val EFFICIENCY = "efficiency"; const val SLEEP_SCORE = "sleep_score"; const val DEBT = "debt"

    /** Orden y nombres tal como salen en WHOOP. */
    val ALL = listOf(
        HRV to "Variabilidad de la frecuencia cardíaca", RHR to "Frecuencia cardíaca en reposo", STEPS to "Pasos",
        Z13 to "Zonas de FC 1-3 (semanal)", Z45 to "Zonas de FC 4-5 (semanal)", STRENGTH to "Tiempo de actividad de fuerza",
        VO2 to "VO₂ máx", KCAL to "Calorías", STRESS to "Monitor de estrés", STRAIN_RECOVERY to "Esfuerzo y recuperación",
        REGULARITY to "Regularidad del sueño", NEED to "Sueño necesario", STRAIN to "Esfuerzo del día",
        EFFICIENCY to "Eficiencia del sueño", SLEEP_SCORE to "Calificación del sueño", DEBT to "Deuda de sueño"
    )

    private const val PREFS = "pulseapp_home"
    fun hidden(ctx: Context): Set<String> =
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getStringSet("panel_hidden", emptySet()) ?: emptySet()
    fun setHidden(ctx: Context, keys: Set<String>) =
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putStringSet("panel_hidden", keys).apply()
}

class HomeDataLoader(private val ctx: Context) {

    private val zone: ZoneId = ZoneId.systemDefault()
    private val iso = DateTimeFormatter.ISO_LOCAL_DATE

    suspend fun load(dayOffset: Int): HomeData {
        val db = AppDatabase.getInstance(ctx)
        val profile = db.userProfileDao().getOnce()
        val age = profile?.ageYears() ?: 30
        val male = profile?.sex != "F"
        val hrMax = Formulas.hrMax(age)
        val dir = ctx.getExternalFilesDir(null)
        val hrFile = File(dir, "hr_log.csv")
        val motionFile = File(dir, MotionTracker.FILE_NAME)

        val today = LocalDate.now(zone)
        val date = today.plusDays(dayOffset.toLong().coerceAtMost(0))
        val isToday = date == today
        val dayStart = date.atStartOfDay(zone).toInstant().toEpochMilli()
        val dayEnd = date.plusDays(1).atStartOfDay(zone).toInstant().toEpochMilli()
        val now = System.currentTimeMillis()

        val summary = if (isToday) withContext(Dispatchers.IO) { MetricsCalculator(ageYears = age, male = male).analyze(hrFile) } else null

        // Días guardados (la fila D = noche que termina D + esfuerzo de D), de más antiguo a más reciente
        val stored = db.dailyMetricsDao().getLastDays(80).sortedBy { it.date }
        val byDate = stored.associateBy { it.date }
        val allSessions = db.activitySessionDao().getAll()
        val stepsByDay = withContext(Dispatchers.IO) { stepsPerDay(motionFile) }
        val zoneDays = withContext(Dispatchers.IO) { ZoneDayCache(ctx).load(hrFile, hrMax, today, 40) }
        val base = SleepPlanner.baselineForAge(profile?.ageYears())
        val calories = CalorieCalculator()
        val planner = SleepPlanner()
        val wake = SleepPlanner.wakeMinute(ctx)

        fun rowsBefore(d: LocalDate): List<DailyMetrics> = stored.filter { it.date < d.format(iso) }
        fun kcalFor(d: LocalDate, elapsedMinutes: Double): Double? = profile?.let {
            val s = d.atStartOfDay(zone).toInstant().toEpochMilli()
            val e = d.plusDays(1).atStartOfDay(zone).toInstant().toEpochMilli()
            val act = allSessions.filter { x -> x.startMillis in s until e }.sumOf { x -> x.caloriesKcal }
            calories.estimateDailyTotal(elapsedMinutes, act, it.ageYears(), it.weightKg, it.heightCm, it.sex)
        }

        /** Día guardado → el mismo cálculo que hizo Inicio ese día (línea base, necesidad y regularidad de los días anteriores). */
        fun recordFromStored(d: LocalDate, row: DailyMetrics): DayRecord {
            val before = rowsBefore(d)
            val last7 = before.takeLast(7)
            val baseline = BaselineProvider().computeFrom(before.reversed())
            val recovery = if (row.avgHrv != null || row.restingHr != null)
                Formulas.recovery(row.avgHrv, row.restingHr, row.respiratoryRate, baseline).total else null
            val prevStrain = byDate[d.minusDays(1).format(iso)]?.strain
            val debtBefore = SleepPlanner.debtFrom(last7.map { it.sleepMinutes }, base)
            val needLastNight = base + Formulas.sleepNeedFromStrain(prevStrain ?: 0.0) + debtBefore
            val consistency = Formulas.sleepConsistency(last7.mapNotNull { it.sleepStartMinuteOfDay })
            val score = row.sleepMinutes?.let {
                Formulas.sleepScore((it * 100 / needLastNight.coerceAtLeast(1)).coerceAtMost(100), row.sleepEfficiencyPct, consistency)
            }
            val needTonight = base + Formulas.sleepNeedFromStrain(row.strain ?: 0.0) + debtBefore
            val debtAfter = SleepPlanner.debtFrom(last7.takeLast(6).map { it.sleepMinutes } + row.sleepMinutes, base)
            return DayRecord(
                d, row.avgHrv, row.restingHr, row.respiratoryRate, row.sleepMinutes, row.sleepEfficiencyPct,
                row.sleepStartMinuteOfDay, row.sleepEndMinuteOfDay, row.strain, recovery, score, needTonight, debtAfter,
                consistency, stepsByDay[d]?.takeIf { it > 0 }, kcalFor(d, 1440.0), row.vo2Max
            )
        }

        // ---------- Hoy en directo (mismas cuentas que el Inicio anterior) ----------
        var todayRecord: DayRecord? = null
        var bedtime: String? = null
        if (isToday && summary != null) {
            val baseline = BaselineProvider().compute(db)
            val recovery = if (summary.avgHrv != null || summary.restingHr != null)
                RecoveryCalculator().breakdown(summary.avgHrv, summary.restingHr, baseline, summary.respiratoryRate).total else null
            val plan = planner.computeTonightPlan(db, summary.strain, wake / 60, wake % 60)
            bedtime = plan.suggestedBedtime
            val consistency = Formulas.sleepConsistency(db.dailyMetricsDao().getLastDays(7).mapNotNull { it.sleepStartMinuteOfDay })
            val lastNightNeed = planner.planForLastNight(db, summary).totalNeedMinutes
            val score = summary.sleepMinutes?.let {
                Formulas.sleepScore((it * 100 / lastNightNeed.coerceAtLeast(1)).coerceAtMost(100), summary.sleepEfficiencyPct, consistency)
            }
            val last6 = stored.filter { it.date < date.format(iso) }.takeLast(6)
            val debtAfter = SleepPlanner.debtFrom(last6.map { it.sleepMinutes } + summary.sleepMinutes, base)
            // VO2 máx estable: se recalcula solo los martes (o si nunca se ha calculado), como antes
            val isTuesday = Calendar.getInstance().get(Calendar.DAY_OF_WEEK) == Calendar.TUESDAY
            val vo2 = if (profile != null && (isTuesday || profile.vo2Max == null) && summary.vo2Max != null) {
                db.userProfileDao().save(profile.copy(vo2Max = summary.vo2Max, vo2MaxUpdatedDate = date.format(iso)))
                summary.vo2Max
            } else profile?.vo2Max ?: summary.vo2Max
            val cal = Calendar.getInstance()
            val elapsed = cal.get(Calendar.HOUR_OF_DAY) * 60.0 + cal.get(Calendar.MINUTE)
            val liveSteps = withContext(Dispatchers.IO) { Ui.stepsToday(ctx) }
            todayRecord = DayRecord(
                date, summary.avgHrv, summary.restingHr, summary.respiratoryRate, summary.sleepMinutes, summary.sleepEfficiencyPct,
                summary.sleepStartMinuteOfDay, summary.sleepEndMinuteOfDay, summary.strain, recovery, score,
                plan.totalNeedMinutes, debtAfter, consistency, liveSteps.takeIf { it > 0 }, kcalFor(date, elapsed), vo2
            )
        }

        // Registros de los 40 días anteriores + el día elegido
        val records = LinkedHashMap<LocalDate, DayRecord>()
        for (i in 40 downTo 1) {
            val d = date.minusDays(i.toLong())
            byDate[d.format(iso)]?.let { records[d] = recordFromStored(d, it) }
        }
        val day: DayRecord = todayRecord
            ?: byDate[date.format(iso)]?.let { recordFromStored(date, it) }
            ?: DayRecord(date, null, null, null, null, null, null, null, null, null, null, null, null, null,
                stepsByDay[date]?.takeIf { it > 0 }, null, null)
        records[date] = day
        val previous = records.values.filter { it.date < date && it.date >= date.minusDays(30) }

        // ---------- Estrés del día (00:00 → ahora, como WHOOP) ----------
        val baselineNow = BaselineProvider().compute(db)
        val stressCalc = StressCalculator()
        // Una sola lectura del archivo: el día elegido y, si es hoy, también las últimas 24 h (el valor "actual" de siempre)
        val samples = withContext(Dispatchers.IO) { stressCalc.loadSamples(hrFile, if (isToday) minOf(dayStart, now - 86_400_000L) else dayStart) }
        val stressTo = if (isToday) now else dayEnd
        val series = stressCalc.seriesBetween(samples, dayStart, stressTo, day.rhr, baselineNow)
        val current = if (isToday) stressCalc.seriesBetween(samples, now - 86_400_000L, now, day.rhr, baselineNow).lastOrNull() else null
        val lastPoint = (current ?: series.lastOrNull())?.score
        val lastMinute = (current ?: series.lastOrNull())?.minuteOfDay
        val level = when {
            lastPoint == null || lastPoint < 1f -> "BAJO"
            lastPoint < 2f -> "MEDIO"
            else -> "ALTO"
        }

        // Ventana de sueño de la noche que termina ese día
        var sleepFrom: Long? = null
        var sleepTo: Long? = null
        if (isToday && summary?.sleepStartMillis != null && summary.sleepEndMillis != null) {
            sleepFrom = summary.stages?.startMillis ?: summary.sleepStartMillis
            sleepTo = summary.stages?.endMillis ?: summary.sleepEndMillis
        } else if (day.sleepStartMinute != null && day.sleepEndMinute != null) {
            sleepTo = dayStart + day.sleepEndMinute * 60_000L
            sleepFrom = if (day.sleepStartMinute > day.sleepEndMinute) dayStart - (1440 - day.sleepStartMinute) * 60_000L
            else dayStart + day.sleepStartMinute * 60_000L
        }

        // ---------- Monitor de salud ----------
        val hist = records.values.filter { it.date < date && it.date >= date.minusDays(14) }
        val newMethod = BaselineProvider.NEW_METHOD_SINCE
        val vitals = listOf(
            vital("resp", "Frecuencia respiratoria", R.drawable.ic_lungs, day.resp, "rpm", 1,
                hist.filter { it.date.format(iso) >= newMethod }.mapNotNull { it.resp }, goodWhenHigh = false),
            vital("rhr", "FCR", R.drawable.ic_rhr, day.rhr?.toDouble(), "lpm", 0,
                hist.mapNotNull { it.rhr?.toDouble() }, goodWhenHigh = false),
            vital("hrv", "VFC", R.drawable.ic_hrv, day.hrv, "ms", 0,
                hist.filter { it.date.format(iso) >= newMethod }.mapNotNull { it.hrv }, goodWhenHigh = true)
        )
        val withRange = vitals.filter { it.ok != null }
        val healthOk = withRange.count { it.ok == true }

        // ---------- Mi panel de control ----------
        val panel = mutableListOf<PanelRow>()
        fun avgOf(values: List<Double>): Double? = values.takeIf { it.isNotEmpty() }?.average()
        fun add(key: String, icon: Int, value: Double?, avg: Double?, goodWhenHigh: Boolean?, fmt: (Double) -> String, sameTol: Double) {
            val label = PanelKeys.ALL.first { it.first == key }.second.uppercase(Locale("es", "ES"))
            val trend = if (value == null || avg == null) null else when {
                abs(value - avg) <= sameTol -> Trend.SAME
                value > avg -> Trend.UP
                else -> Trend.DOWN
            }
            val good = when {
                trend == null || trend == Trend.SAME || goodWhenHigh == null -> null
                else -> (trend == Trend.UP) == goodWhenHigh
            }
            panel.add(PanelRow(key, label, icon, value?.let(fmt) ?: "--", avg?.let(fmt), trend, good))
        }
        val hm = { v: Double -> Ui.hm(Math.round(v).toInt()) }
        val int0 = { v: Double -> "%.0f".format(v) }
        val pct = { v: Double -> "%.0f %%".format(v) }
        add(PanelKeys.HRV, R.drawable.ic_hrv, day.hrv,
            avgOf(previous.filter { it.date.format(iso) >= newMethod }.mapNotNull { it.hrv }), true, int0, 0.5)
        add(PanelKeys.RHR, R.drawable.ic_rhr, day.rhr?.toDouble(), avgOf(previous.mapNotNull { it.rhr?.toDouble() }), false, int0, 0.5)
        add(PanelKeys.STEPS, R.drawable.ic_steps, day.steps?.toDouble(),
            avgOf(previous.mapNotNull { it.steps?.toDouble() }), true, { Ui.thousands(Math.round(it)) }, 0.5)

        // Zonas de FC semanales (7 días hasta ese día) frente a la media semanal de las 4 semanas anteriores
        fun zoneWeek(endDay: LocalDate, pick: (ZoneDay) -> Int): Double? {
            val days = (0..6).mapNotNull { zoneDays[endDay.minusDays(it.toLong())] }
            return if (days.isEmpty()) null else days.sumOf(pick) / 60.0
        }
        fun zoneAvgWeek(endDay: LocalDate, pick: (ZoneDay) -> Int): Double? {
            val days = (7..34).mapNotNull { zoneDays[endDay.minusDays(it.toLong())] }.filter { it.totalSeconds >= 3600 }
            return if (days.size < 3) null else days.sumOf(pick) / 60.0 / days.size * 7
        }
        add(PanelKeys.Z13, R.drawable.ic_heart_zone, zoneWeek(date) { it.z13Seconds }, zoneAvgWeek(date) { it.z13Seconds }, true, hm, 0.5)
        add(PanelKeys.Z45, R.drawable.ic_heart_up, zoneWeek(date) { it.z45Seconds }, zoneAvgWeek(date) { it.z45Seconds }, true, hm, 0.5)

        // Fuerza: actividades de tipo "fuerza" de los últimos 7 días frente a la media semanal de las 4 anteriores
        val strength = allSessions.filter { it.type.contains("fuerza", ignoreCase = true) }
        fun strengthMinutes(from: LocalDate, toExclusive: LocalDate): Double {
            val s = from.atStartOfDay(zone).toInstant().toEpochMilli()
            val e = toExclusive.atStartOfDay(zone).toInstant().toEpochMilli()
            return strength.filter { it.startMillis in s until e }.sumOf { (it.endMillis - it.startMillis) / 60000.0 }
        }
        val hasHistory = previous.size >= 7
        add(PanelKeys.STRENGTH, R.drawable.ic_dumbbell, strengthMinutes(date.minusDays(6), date.plusDays(1)),
            if (hasHistory) strengthMinutes(date.minusDays(34), date.minusDays(6)) / 4.0 else null, true, hm, 0.5)
        add(PanelKeys.VO2, R.drawable.ic_lungs, day.vo2, avgOf(previous.mapNotNull { it.vo2 }), true, int0, 0.5)
        add(PanelKeys.KCAL, R.drawable.ic_calories, day.kcal, avgOf(previous.mapNotNull { it.kcal }), null, { Ui.thousands(Math.round(it)) }, 0.5)
        add(PanelKeys.REGULARITY, R.drawable.ic_regularity, day.consistency?.toDouble(),
            avgOf(previous.mapNotNull { it.consistency?.toDouble() }), true, pct, 0.5)
        add(PanelKeys.NEED, R.drawable.ic_sleep_need, day.needTonight?.toDouble(),
            avgOf(previous.mapNotNull { it.needTonight?.toDouble() }), false, hm, 0.5)
        add(PanelKeys.STRAIN, R.drawable.ic_strain, day.strain, avgOf(previous.mapNotNull { it.strain }), true, { Ui.comma(it) }, 0.05)
        add(PanelKeys.EFFICIENCY, R.drawable.ic_efficiency, day.efficiency?.toDouble(),
            avgOf(previous.mapNotNull { it.efficiency?.toDouble() }), true, pct, 0.5)
        add(PanelKeys.SLEEP_SCORE, R.drawable.ic_moon, day.sleepScore?.toDouble(),
            avgOf(previous.mapNotNull { it.sleepScore?.toDouble() }), true, pct, 0.5)
        add(PanelKeys.DEBT, R.drawable.ic_debt, day.debt?.toDouble(), avgOf(previous.mapNotNull { it.debt?.toDouble() }), false, hm, 0.5)

        // ---------- Esfuerzo y recuperación: 7 días ----------
        val week = (6 downTo 0).map { i ->
            val d = date.minusDays(i.toLong())
            val r = records[d]
            WeekPoint(d, r?.strain, r?.recovery)
        }

        // ---------- Racha: días seguidos llevando la pulsera (≥ 1 h de pulso) ----------
        var streak = 0
        var cursor = if ((zoneDays[date]?.totalSeconds ?: 0) >= 3600 || !isToday) date else date.minusDays(1)
        while ((zoneDays[cursor]?.totalSeconds ?: 0) >= 3600) { streak++; cursor = cursor.minusDays(1) }

        val sessionsOfDay = allSessions.filter { it.startMillis in dayStart until dayEnd }.sortedBy { it.startMillis }

        return HomeData(
            date = date, isToday = isToday, summary = summary, day = day,
            vitals = vitals, healthOk = healthOk, healthTotal = withRange.size,
            stressScore = lastPoint, stressLevel = level, stressMinute = lastMinute, stressSeries = series,
            stressFrom = dayStart, stressTo = stressTo, sleepFromMillis = sleepFrom, sleepToMillis = sleepTo,
            sessions = sessionsOfDay, bedtime = bedtime, wakeMinute = wake, panel = panel, week = week, streak = streak,
            insight = Insight.build(day, previous, isToday, baselineNow != null),
            baselineReady = baselineNow != null, profileMissing = profile == null
        )
    }

    /** Rango habitual = media ± 1 desviación (mínimo ±5 % de la media), como en Salud. Null con menos de 3 noches. */
    private fun vital(key: String, label: String, icon: Int, value: Double?, unit: String, decimals: Int,
                      history: List<Double>, goodWhenHigh: Boolean): VitalStatus {
        if (history.size < BaselineProvider.MIN_DAYS_REQUIRED || value == null) {
            return VitalStatus(key, label, icon, value, unit, decimals, null, null, goodWhenHigh, null)
        }
        val mean = history.average()
        val sd = sqrt(history.map { (it - mean) * (it - mean) }.average())
        val half = maxOf(sd, mean * 0.05)
        val lo = mean - half
        val hi = mean + half
        // Como WHOOP: fuera del rango hacia el lado bueno (VFC alta, FCR o respiración baja) sigue contando como bien
        val ok = value in lo..hi || (goodWhenHigh && value > hi) || (!goodWhenHigh && value < lo)
        return VitalStatus(key, label, icon, value, unit, decimals, lo, hi, goodWhenHigh, ok)
    }

    private fun stepsPerDay(motionFile: File): Map<LocalDate, Int> =
        MotionTracker.readMinutes(motionFile).groupBy {
            java.time.Instant.ofEpochSecond(it.minuteStartUnix).atZone(zone).toLocalDate()
        }.mapValues { (_, v) -> v.sumOf { it.steps } }
}

/** Segundos con pulso de un día y segundos en zonas 1–3 (50–80 % FC máx) y 4–5 (≥ 80 %), como las zonas de la app. */
data class ZoneDay(val totalSeconds: Int, val z13Seconds: Int, val z45Seconds: Int)

/**
 * Tiempo por zonas de cada día sacado de hr_log.csv en UNA pasada, con caché de los días cerrados
 * (zone_days.csv en la carpeta privada). Hoy siempre se recalcula. Si cambia la FC máx se rehace todo.
 */
class ZoneDayCache(private val cacheFile: File) {
    constructor(ctx: Context) : this(File(ctx.filesDir, "zone_days.csv"))

    fun load(hrFile: File, hrMax: Double, today: LocalDate, days: Int): Map<LocalDate, ZoneDay> {
        val result = HashMap<LocalDate, ZoneDay>()
        val hrMaxKey = Math.round(hrMax).toInt()
        try {
            if (cacheFile.exists()) {
                val lines = cacheFile.readLines()
                if (lines.firstOrNull() == "hrmax=$hrMaxKey") {
                    lines.drop(1).forEach { l ->
                        val p = l.split(',')
                        if (p.size == 4) result[LocalDate.parse(p[0])] = ZoneDay(p[1].toInt(), p[2].toInt(), p[3].toInt())
                    }
                }
            }
        } catch (e: Exception) { result.clear() }

        val wanted = (0..days).map { today.minusDays(it.toLong()) }.filter { it > today.minusDays(3) || it !in result }.toSet()
        if (wanted.isEmpty() || !hrFile.exists()) return result
        val wantedKeys = wanted.associateBy { it.toString() }
        val total = HashMap<LocalDate, BitSet>()
        val z13 = HashMap<LocalDate, BitSet>()
        val z45 = HashMap<LocalDate, BitSet>()
        try {
            hrFile.forEachLine { line ->
                if (line.length < 21 || line[10] != 'T') return@forEachLine
                val d = wantedKeys[line.substring(0, 10)] ?: return@forEachLine
                val h = line.substring(11, 13).toIntOrNull() ?: return@forEachLine
                val m = line.substring(14, 16).toIntOrNull() ?: return@forEachLine
                val s = line.substring(17, 19).toIntOrNull() ?: return@forEachLine
                val comma2 = line.indexOf(',', 20)
                val bpm = (if (comma2 > 0) line.substring(20, comma2) else line.substring(20)).trim().toIntOrNull() ?: return@forEachLine
                if (bpm <= 0 || bpm > 250) return@forEachLine
                val sec = h * 3600 + m * 60 + s
                if (sec !in 0 until 86400) return@forEachLine
                total.getOrPut(d) { BitSet(86400) }.set(sec)
                val pct = bpm / hrMax
                if (pct >= 0.8) z45.getOrPut(d) { BitSet(86400) }.set(sec)
                else if (pct >= 0.5) z13.getOrPut(d) { BitSet(86400) }.set(sec)
            }
        } catch (e: Exception) { return result }
        for (d in wanted) {
            val t = total[d]?.cardinality() ?: 0
            result[d] = ZoneDay(t, z13[d]?.cardinality() ?: 0, z45[d]?.cardinality() ?: 0)
        }
        // Guarda solo días cerrados hace ≥ 3 días y con datos: el historial de la pulsera puede llegar tarde y rellenar huecos
        try {
            val sb = StringBuilder("hrmax=$hrMaxKey\n")
            result.filter { (d, z) -> d <= today.minusDays(3) && d >= today.minusDays(days.toLong()) && z.totalSeconds > 0 }
                .toSortedMap().forEach { (d, z) ->
                sb.append(d).append(',').append(z.totalSeconds).append(',').append(z.z13Seconds).append(',').append(z.z45Seconds).append('\n')
            }
            cacheFile.writeText(sb.toString())
        } catch (e: Exception) { }
        return result
    }
}

/** "Perspectiva diaria": texto corto con lo más importante del día, hecho con tus propios datos. */
object Insight {
    fun build(day: DayRecord, previous: List<DayRecord>, isToday: Boolean, baselineReady: Boolean): String {
        val parts = mutableListOf<String>()
        val rec = day.recovery
        if (rec != null) {
            val state = when {
                rec >= 67 -> "Recuperación en verde ($rec %): tu cuerpo está preparado para un día exigente."
                rec >= 34 -> "Recuperación en amarillo ($rec %): puedes entrenar, pero sin pasarte."
                else -> "Recuperación en rojo ($rec %): hoy toca priorizar el descanso."
            }
            parts.add(state)
            val target = when {
                rec >= 67 -> "14 y 18"
                rec >= 34 -> "10 y 14"
                else -> "0 y 10"
            }
            parts.add("Esfuerzo recomendado para ${if (isToday) "hoy" else "ese día"}: entre $target.")
        }
        val avgHrv = previous.mapNotNull { it.hrv }.takeIf { it.size >= 3 }?.average()
        if (day.hrv != null && avgHrv != null) {
            val diff = (day.hrv / avgHrv - 1) * 100
            parts.add(when {
                diff >= 5 -> "Tu VFC (%.0f ms) está un %.0f %% por encima de tu media.".format(day.hrv, diff)
                diff <= -5 -> "Tu VFC (%.0f ms) está un %.0f %% por debajo de tu media.".format(day.hrv, -diff)
                else -> "Tu VFC (%.0f ms) está en tu media.".format(day.hrv)
            })
        }
        val avgRhr = previous.mapNotNull { it.rhr }.takeIf { it.size >= 3 }?.average()
        if (day.rhr != null && avgRhr != null) {
            val d = day.rhr - avgRhr
            if (d >= 2) parts.add("La FC en reposo (%d lpm) sube %.0f lpm sobre lo normal.".format(day.rhr, d))
            else if (d <= -2) parts.add("La FC en reposo (%d lpm) baja %.0f lpm respecto a lo normal.".format(day.rhr, -d))
        }
        if (day.sleepMinutes != null) {
            parts.add("Dormiste ${Ui.hm(day.sleepMinutes)}" + (day.sleepScore?.let { " (calificación $it %)" } ?: "") + ".")
        }
        if (day.debt != null && day.debt >= 30) parts.add("Arrastras ${Ui.hm(day.debt)} de deuda de sueño.")
        if (!baselineReady) parts.add("Aún estoy aprendiendo tu línea base: con 3 noches más los números serán más tuyos.")
        if (parts.isEmpty()) return "Todavía no hay datos suficientes de este día. Lleva la pulsera puesta y vuelve más tarde."
        return parts.joinToString(" ")
    }
}
