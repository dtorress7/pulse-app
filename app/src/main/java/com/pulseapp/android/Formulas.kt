package com.pulseapp.android

import android.content.Context
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * Fórmulas de PulseApp, CALIBRADAS CON TU HISTÓRICO REAL DE WHOOP
 * (export del 08/09/2026: 155 noches, 173 entrenamientos, 65 de fútbol).
 *
 * ESFUERZO (0–21)                                         error medio en tu fútbol: 0,7 puntos
 *   TRIMP de Banister con reserva de FC (Karvonen), minuto a minuto:
 *     HRr = (FC − FC reposo) / (FC máx − FC reposo)
 *     carga/min = HRr · 0,64 · e^(1,92·HRr)   (mujeres: 0,86 · e^(1,67·HRr))
 *   Solo cuentan los minutos por encima del 45 % de tu FC máx (el resto es vida normal sin carga).
 *   Esfuerzo = 4,14 · ln(1 + TRIMP / 2,6), máximo 21.
 *   La misma curva sirve para el día (TRIMP de todo el día) y para cada actividad.
 *
 * RECUPERACIÓN (1–99 %)                                   error medio con WHOOP: 5,6 puntos, color igual 88 %
 *   Con tus datos, lo que mueve la nota de WHOOP es casi solo la VFC frente a tu media reciente:
 *     Δ = ln(VFC de esta noche) − media ponderada de ln(VFC) de tus noches anteriores (EWMA, 14 días)
 *     logit = 5,5·Δ − 0,028·(FC reposo − tu media) + 0,84
 *     Recuperación = 100 / (1 + e^−logit)
 *   Una noche con tu VFC media → ~70 %. VFC un 10 % por debajo → ~56 %. Un 20 % por encima → ~86 %.
 *   La respiración solo resta si sube claramente (alerta de enfermedad); el sueño NO entra en la nota
 *   porque en tus 155 noches no la cambia (WHOOP lo usa a través de la VFC, que ya refleja cómo dormiste).
 *
 * CALIFICACIÓN DEL SUEÑO (%)                              error medio con WHOOP: 1,8 puntos
 *   0,281 · horas vs necesidad (máx 100) + 0,202 · eficiencia + 0,288 · regularidad + 19,6
 *
 * NECESIDAD DE SUEÑO = 7:50 + esfuerzo + deuda − siestas, con esfuerzo = max(0, esfuerzo − 8) · 6 min.
 */
object Formulas {

    // ---------- FC máxima ----------

    private const val PREFS = "pulseapp_formulas"
    private const val KEY_HR_MAX = "hr_max_observed"

    fun tanaka(ageYears: Int): Double = 208.0 - 0.7 * ageYears

    /** Copia en memoria de la FC máx registrada (se carga con [init] al abrir la app o los servicios). */
    @Volatile private var cachedObserved = 0

    fun init(context: Context) {
        val sp = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        cachedObserved = sp.getInt(KEY_HR_MAX, 0)
        cachedZoneRhr = sp.getInt(KEY_RHR_ZONE, DEFAULT_RESTING_HR)
        cachedBmr = sp.getFloat(KEY_BMR, 0f).toDouble()
    }

    // ---------- Zonas de FC como WHOOP (20/10) ----------
    // WHOOP (rangos del 19/10: 112 / 141 / 155 / 168 / 182) usa % de la RESERVA de FC: FCR + p·(FCmáx − FCR) con
    // p = 40/60/70/80/90 %. Con el pulso de PulseApp y esos límites, el funcional del 19/10 sale 3:51/21:13/9:07/4:40/0:08
    // (WHOOP 3:48/21:16/9:07/4:40/0:08). FCR = media de tus noches (se guarda al calcular Inicio).
    private const val KEY_RHR_ZONE = "rhr_zone"
    private const val KEY_BMR = "bmr_kcal"
    // Confirmado con "Ajustes de FC" de WHOOP (20/10): FCR 59, FCmáx 195 → 112/141/155/168/182 = ceil(FCR + p·reserva)
    // con p = 0,385 / 0,60 / 0,70 / 0,80 / 0,90 (la zona 1 de WHOOP empieza un poco por debajo del 40 %).
    val ZONE_HRR = doubleArrayOf(0.385, 0.60, 0.70, 0.80, 0.90)
    @Volatile private var cachedZoneRhr = 58
    @Volatile private var cachedBmr = 0.0

    fun zoneRestingHr(): Int = cachedZoneRhr

    fun setZoneRestingHr(context: Context, rhr: Int) {
        if (rhr !in 35..100 || rhr == cachedZoneRhr) return
        cachedZoneRhr = rhr
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putInt(KEY_RHR_ZONE, rhr).apply()
    }

    /** Límite inferior (lpm) de las zonas 1..5. */
    fun zoneBounds(hrMax: Double, rhr: Int = cachedZoneRhr): IntArray =
        IntArray(5) { kotlin.math.ceil(rhr + ZONE_HRR[it] * (hrMax - rhr)).toInt() }

    fun zoneOf(bpm: Int, bounds: IntArray): Int = bounds.count { bpm >= it }

    // ---------- Calorías de actividad (20/10) ----------
    // Ajustadas con tus 173 entrenamientos del export de WHOOP: kcal/min por zona (0..5) = factor × metabolismo basal por minuto.
    // Error medio 13 kcal (5 %). Funcional 19/10: ≈291 kcal (WHOOP 271); con Keytel salían 484.
    val ZONE_KCAL_BMR = doubleArrayOf(1.09, 5.13, 10.14, 10.14, 14.56, 16.53)

    fun bmr(): Double = cachedBmr

    fun setBmr(context: Context, bmr: Double) {
        if (bmr < 800 || kotlin.math.abs(bmr - cachedBmr) < 1) return
        cachedBmr = bmr
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putFloat(KEY_BMR, bmr.toFloat()).apply()
    }

    /** [zoneMinutes] = minutos en zonas 0..5. [bmrPerDay] = metabolismo basal (kcal/día). */
    fun activityKcal(zoneMinutes: DoubleArray, bmrPerDay: Double): Double {
        var f = 0.0
        for (i in 0..5) f += zoneMinutes[i] * ZONE_KCAL_BMR[i]
        return f * bmrPerDay / 1440.0
    }

    // ---------- Detección automática de actividades (v2, 20/10) ----------
    // Calibrada con los dos funcionales que WHOOP detectó solo (19/10 18:16–18:54 y 20/10 18:20–19:04, horas de la API).
    //  - Tramo = minutos seguidos con el pulso ≥ 26 % de la reserva (≈95 lpm), tolerando 2 min por debajo o sin dato.
    //  - Núcleo = minutos ≥ 50 % de la reserva. Vale si el tramo tiene ≥ 8 min de núcleo y dura ≥ 12 min (IA de WHOOP: mínimo 12).
    //  - Inicio = primer minuto de núcleo, adelantado mientras los anteriores sigan ≥ zona 1.
    //  - Fin = último minuto de núcleo, o más tarde si después el pulso VUELVE A SUBIR ≥ 5 lpm sobre el mínimo desde entonces
    //    (sigues haciendo series aunque más suaves). Si solo va bajando (te estás recuperando), acaba en el último minuto de núcleo.
    const val ACT_ELEVATED_HRR = 0.26
    const val ACT_CORE_HRR = 0.50
    const val ACT_MAX_LOW_MIN = 2
    const val ACT_RERISE_BPM = 5.0
    const val ACT_MIN_MINUTES = 12
    const val ACT_MIN_CORE = 8

    /** [minutes] = (minuto unix, FC media de ese minuto) ordenados. Devuelve (primer minuto, último minuto) de cada actividad. */
    fun detectActivities(minutes: List<Pair<Long, Double>>, hrMax: Double, rhr: Int = cachedZoneRhr): List<Pair<Long, Long>> {
        val res = hrMax - rhr
        val elevated = rhr + ACT_ELEVATED_HRR * res
        val core = rhr + ACT_CORE_HRR * res
        val z1 = rhr + ZONE_HRR[0] * res
        val out = ArrayList<Pair<Long, Long>>()
        val n = minutes.size
        var i = 0
        while (i < n) {
            if (minutes[i].second < elevated) { i++; continue }
            // Tramo elevado [s0, e0]: se corta con > 2 min por debajo o sin datos
            val s0 = i
            var e0 = i
            var j = i + 1
            while (j < n && minutes[j].first - minutes[e0].first <= ACT_MAX_LOW_MIN + 1) {
                if (minutes[j].second >= elevated) e0 = j
                j++
            }
            val coreIdx = (s0..e0).filter { minutes[it].second >= core }
            if (coreIdx.size >= ACT_MIN_CORE) {
                var s = coreIdx.first()
                while (s > s0 && minutes[s - 1].second >= z1 && minutes[s].first - minutes[s - 1].first == 1L) s--
                var e = coreIdx.last()
                var low = Double.MAX_VALUE
                for (k in e + 1..e0) {
                    val v = minutes[k].second
                    if (v >= low + ACT_RERISE_BPM) e = k
                    low = minOf(low, v)
                }
                if (minutes[e].first - minutes[s].first + 1 >= ACT_MIN_MINUTES) out.add(minutes[s].first to minutes[e].first)
            }
            i = e0 + 1
        }
        return out
    }

    /** FC máx usada en zonas y esfuerzo: la mayor entre la de tu edad y la máxima real registrada. */
    fun hrMax(ageYears: Int): Double = max(tanaka(ageYears), cachedObserved.toDouble())

    fun hrMax(context: Context, ageYears: Int): Double { init(context); return hrMax(ageYears) }

    fun observedHrMax(context: Context): Int? =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getInt(KEY_HR_MAX, 0).takeIf { it > 0 }

    /** 0 = borrar (volver a la fórmula por edad). */
    fun setObservedHrMax(context: Context, bpm: Int) {
        // Si cambia, se rehacen zonas/esfuerzo/calorías de las actividades guardadas (AutoActivityScanner)
        val sp = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (sp.getInt(KEY_HR_MAX, 0) != bpm) sp.edit().putInt(KEY_HR_MAX, bpm).putInt("act_recalc", 0).apply()
        cachedObserved = bpm
    }

    /** Si en una actividad alcanzas una FC más alta (y creíble), pasa a ser tu FC máx (como hace WHOOP). */
    fun updateObservedHrMax(context: Context, bpm: Int) {
        if (bpm !in 150..220) return
        val current = observedHrMax(context) ?: 0
        // Un salto de más de 8 lpm sobre tu máximo suele ser un artefacto del sensor: no se acepta.
        if (bpm > current && (current == 0 || bpm <= current + 8)) setObservedHrMax(context, bpm)
    }

    // ---------- Esfuerzo ----------

    const val STRAIN_SCALE = 4.14
    const val STRAIN_TRIMP_REF = 2.6
    const val MIN_HR_FRACTION = 0.45
    const val DEFAULT_RESTING_HR = 58

    fun trimp(minutes: Double, hr: Int, restingHr: Int, hrMax: Double, male: Boolean = true): Double {
        if (minutes <= 0 || hr < MIN_HR_FRACTION * hrMax) return 0.0
        val reserve = (hrMax - restingHr).coerceAtLeast(20.0)
        val hrr = ((hr - restingHr) / reserve).coerceIn(0.0, 1.1)
        if (hrr <= 0.0) return 0.0
        return if (male) minutes * hrr * 0.64 * exp(1.92 * hrr)
        else minutes * hrr * 0.86 * exp(1.67 * hrr)
    }

    fun strainFromTrimp(trimp: Double): Double =
        (STRAIN_SCALE * ln(1.0 + max(0.0, trimp) / STRAIN_TRIMP_REF)).coerceIn(0.0, 21.0)

    fun strainOf(
        readings: List<Pair<Long, Int>>, restingHr: Int?, hrMax: Double, male: Boolean = true, maxGapMinutes: Double = 5.0
    ): Double {
        if (readings.size < 2) return 0.0
        val rhr = restingHr ?: DEFAULT_RESTING_HR
        var total = 0.0
        for (i in 1 until readings.size) {
            val dt = (readings[i].first - readings[i - 1].first) / 60000.0
            if (dt <= 0 || dt > maxGapMinutes) continue
            total += trimp(dt, readings[i].second, rhr, hrMax, male)
        }
        return strainFromTrimp(total)
    }

    // ---------- Recuperación ----------

    const val K_HRV = 5.5
    const val K_RHR = 0.028
    const val BIAS = 0.84
    /**
     * Referencias mientras no haya 3 noches propias: tu media reciente en WHOOP (9–14/10: VFC 119, 70, 68, 113, 101, 62
     * → media geométrica 86 ms; FC reposo 54, 61, 63, 57, 56, 64 → 59 lpm). Con 95 ms (media de 30 días) la
     * recuperación del 15/10 salía 33 % frente al 43 % de WHOOP; con estas, ~38 %.
     */
    const val FALLBACK_HRV = 86.0
    const val FALLBACK_RHR = 59.0

    data class RecoveryResult(
        val total: Int,
        val hrvDeltaPct: Double?,   // % de tu VFC frente a tu media (+10 = un 10 % por encima)
        val rhrDelta: Double?,      // lpm frente a tu media
        val respPenalty: Boolean,
        val usedPersonalBaseline: Boolean
    )

    fun recovery(hrv: Double?, restingHr: Int?, respiratoryRate: Double?, b: PersonalBaseline?): RecoveryResult {
        val lnRef = b?.lnHrvMean ?: ln(FALLBACK_HRV)
        val delta = hrv?.takeIf { it > 0 }?.let { ln(it) - lnRef }
        val rhrDelta = if (restingHr != null) restingHr - (b?.avgRestingHr ?: FALLBACK_RHR) else null
        var logit = BIAS + K_HRV * (delta ?: -0.1) - K_RHR * (rhrDelta ?: 0.0)
        var penalty = false
        if (respiratoryRate != null && respiratoryRate in 8.0..25.0 && b?.respMean != null && b.respSd != null) {
            val z = (respiratoryRate - b.respMean) / b.respSd
            if (z > 2.0) { logit -= 0.5 * (z - 2.0); penalty = true }
        }
        val total = (100.0 / (1.0 + exp(-logit))).toInt().coerceIn(1, 99)
        return RecoveryResult(total, delta?.let { (exp(it) - 1) * 100 }, rhrDelta, penalty, b != null)
    }

    // ---------- Sueño ----------

    /** Calificación del sueño como WHOOP. [consistency] null → se usa 66 (tu media en WHOOP). */
    fun sleepScore(hoursVsNeedPct: Int, efficiencyPct: Int?, consistencyPct: Int?): Int =
        (0.281 * hoursVsNeedPct.coerceIn(0, 100) + 0.202 * (efficiencyPct ?: 93) +
            0.288 * (consistencyPct ?: 66) + 19.6).toInt().coerceIn(0, 100)

    /**
     * Regularidad 0–100 como WHOOP (18/10): cuánto se solapa la última noche con cada una de las 3 anteriores
     * (intersección / unión del tramo en cama, por hora del día), en media, menos 7.
     * Ajustado con las 145 noches del export de WHOOP: error medio 4,9 puntos, 87 % a ±10 (la fórmula anterior, por la
     * desviación de la hora de dormirse, fallaba 27 puntos de media). [nightsOldestFirst] = (minuto de inicio, minuto de fin)
     * de cada noche, la última es la que se califica. Null con menos de 2 noches.
     */
    fun sleepConsistency(nightsOldestFirst: List<Pair<Int, Int>>): Int? {
        if (nightsOldestFirst.size < 2) return null
        // Eje desde las 12:00: la noche queda en un tramo continuo [ini, fin)
        fun axis(n: Pair<Int, Int>): Pair<Int, Int> {
            val s = ((n.first - 720) % 1440 + 1440) % 1440
            var e = ((n.second - 720) % 1440 + 1440) % 1440
            if (e <= s) e += 1440
            return s to e
        }
        val last = axis(nightsOldestFirst.last())
        val prev = nightsOldestFirst.dropLast(1).takeLast(3).map { axis(it) }
        val j = prev.map { p ->
            val inter = (minOf(last.second, p.second) - maxOf(last.first, p.first)).coerceAtLeast(0)
            val union = (last.second - last.first) + (p.second - p.first) - inter
            if (union > 0) inter.toDouble() / union else 0.0
        }.average()
        return (j * 100 - 7).roundToInt().coerceIn(0, 100)
    }

    /** Minutos extra de sueño por el esfuerzo del día (0 hasta 8, luego 6 min por punto: 16 → +48 min). */
    fun sleepNeedFromStrain(strain: Double): Int = (max(0.0, strain - 8.0) * 6.0).toInt()
}
