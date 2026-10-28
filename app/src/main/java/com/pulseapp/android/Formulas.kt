package com.pulseapp.android

import android.content.Context
import kotlin.math.exp
import kotlin.math.floor
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
        cachedImportUntil = sp.getString(KEY_IMPORT_UNTIL, "") ?: ""
    }

    // ---------- Historial importado de WHOOP (23/10) ----------
    private const val KEY_IMPORT_UNTIL = "whoop_import_until"
    @Volatile private var cachedImportUntil = ""

    /** Último día importado del export de WHOOP ("" = ninguno). Hasta ese día los datos son de WHOOP. */
    fun whoopImportUntil(): String = cachedImportUntil

    fun setWhoopImportUntil(context: Context, date: String) {
        cachedImportUntil = date
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(KEY_IMPORT_UNTIL, date).apply()
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

    // ---------- Siestas (21/10) ----------
    // Como WHOOP: sueño fuera de la noche principal = siesta (en tu export: 17 siestas de 21 a 151 min, casi todas entre 14:20 y 18:30).
    // No cuentan en la calificación del sueño ni en la recuperación; restan de la necesidad de sueño de esa noche.
    // Regla (necesita movimiento grabado): tramo de minutos quietos (≥50 s quieto, giro < 2,5 °/s, 0 pasos; tolera 2 min sueltos) de
    // ≥ 20 min, que empiece entre las 10:00 y las 21:00, con el pulso mediano ≤ FC en reposo + 12. Sentado despierto (sofá, reunión)
    // el giro va de 3 a 10 aunque el pulso sea bajo; dormido está en su suelo (1,3–1,7).
    const val NAP_TYPE = "Siesta"
    const val NAP_MIN_MINUTES = 20

    fun detectNaps(minutes: List<Pair<Long, Double>>, motion: List<MotionMinute>, rhr: Int): List<Pair<Long, Long>> {
        val byMin = HashMap<Long, MotionMinute>(motion.size * 2)
        for (mm in motion) byMin[mm.minuteStartUnix / 60] = mm
        val hrByMin = HashMap<Long, Double>(minutes.size * 2)
        for ((k, v) in minutes) hrByMin[k] = v
        fun still(m: MotionMinute?) = m != null && m.stillSecs >= 50 && m.gyroDps < 2.5f && m.steps == 0
        val keys = byMin.keys.sorted()
        val out = ArrayList<Pair<Long, Long>>()
        var i = 0
        while (i < keys.size) {
            if (!still(byMin[keys[i]])) { i++; continue }
            val a = keys[i]; var b = a
            var k = a + 1
            while (true) {
                if (still(byMin[k])) { b = k; k++ }
                else if (k - b <= 2 && (still(byMin[k + 1]) || still(byMin[k + 2]))) k++
                else break
            }
            val len = b - a + 1
            val h = java.util.Calendar.getInstance().apply { timeInMillis = a * 60_000L }.get(java.util.Calendar.HOUR_OF_DAY)
            // 25/10: la "siesta" del 24/10 10:47–11:12 era el final de la noche. Una siesta va después de estar levantado: en las 3 h
            // de antes tiene que haber ≥ 5 min andando (≥ 10 pasos). Tardes reales 22–24/10: 10–77 min; antes de las 10:47 del 24: 1.
            var walked = 0; var covered = 0
            for (q in a - 180 until a) { val mm = byMin[q] ?: continue; covered++; if (mm.steps >= 10) walked++ }
            val afterNight = covered >= 108 && walked < 5
            if (len >= NAP_MIN_MINUTES && h in 10..20 && !afterNight) {
                val hrs = (a..b).mapNotNull { hrByMin[it] }.sorted()
                if (hrs.size >= len * 0.6 && hrs[hrs.size / 2] <= rhr + 12) out.add(a to b)
            }
            i = keys.indexOfFirst { it > b }.let { if (it < 0) keys.size else it }
        }
        return out
    }

    // ---------- Detección automática de actividades (v2, 20/10) ----------
    // Calibrada con los dos funcionales que WHOOP detectó solo (19/10 18:16–18:54 y 20/10 18:20–19:04, horas de la API).
    //  - Tramo = minutos seguidos con el pulso ≥ 26 % de la reserva (≈95 lpm), tolerando 2 min por debajo o sin dato.
    //  - Núcleo = minutos ≥ 50 % de la reserva. Vale si el tramo tiene ≥ 8 min de núcleo y dura ≥ 12 min (IA de WHOOP: mínimo 12).
    //  - Inicio = primer minuto del tramo elevado.
    //  - Fin = último minuto de núcleo, o más tarde si después el pulso VUELVE A SUBIR ≥ 5 lpm sobre el mínimo desde entonces
    //    (sigues haciendo series aunque más suaves). Si solo va bajando (te estás recuperando), acaba en el último minuto de núcleo.
    const val ACT_ELEVATED_HRR = 0.26
    const val ACT_CORE_HRR = 0.50
    const val ACT_MAX_LOW_MIN = 2
    const val ACT_RERISE_BPM = 5.0
    const val ACT_MIN_MINUTES = 12
    const val ACT_MIN_CORE = 8
    const val ACT_STILL_CUT_MIN = 10
    // Sesiones suaves (28/10): funcional 22/10 (media 106) y fútbol 26/10 (media 108) que WHOOP detectó y la regla de arriba no
    // (casi nunca ≥ 50 % de reserva). Media móvil de 5 min ≥ 28 % de reserva, huecos ≤ 5 min, ≥ 15 min, media ≥ 30 % y ≥ 80 % con pulso.
    const val SOFT_WINDOW_MIN = 5
    const val SOFT_ELEVATED_HRR = 0.28
    const val SOFT_MEAN_HRR = 0.30
    const val SOFT_MAX_LOW_MIN = 5
    const val SOFT_MIN_MINUTES = 15

    // ---------- Paseos (25/10) ----------
    // WHOOP detectó solo los dos paseos del 24/10 (21:26–21:49 y 22:20–22:49, FC media 107/100, casi todo zona 0): con el pulso no
    // basta (no hay minutos intensos). Con movimiento grabado: minuto andando = ≥ 30 pasos; se juntan con pausas ≤ 10 min. Es un paseo si
    // dura ≥ 12 min, tiene ≥ 8 min andando, ≥ 40 pasos/min de media y FC media ≥ 26 % de la reserva (≈ 94 lpm). En 14–25/10 da los dos
    // paseos (21:26–21:48 y 22:20–22:50) y nada más: el paseo largo del 24/10 13:17–14:48 (FC 86) y la vuelta a casa (FC 97, 27 pasos/min)
    // no salen. Sin movimiento grabado no se detectan paseos.
    const val WALK_TYPE = "Caminar"

    fun detectWalks(minutes: List<Pair<Long, Double>>, motion: Map<Long, MotionMinute>, hrMax: Double, rhr: Int = cachedZoneRhr): List<Pair<Long, Long>> {
        val elevated = rhr + ACT_ELEVATED_HRR * (hrMax - rhr)
        val hrBy = HashMap<Long, Double>(minutes.size * 2)
        for ((k, v) in minutes) hrBy[k] = v
        val walk = motion.filterValues { it.steps >= 30 }.keys.sorted()
        val out = ArrayList<Pair<Long, Long>>()
        var i = 0
        while (i < walk.size) {
            val a = walk[i]; var b = a; var cnt = 1; var j = i + 1
            while (j < walk.size && walk[j] - b <= 11) { b = walk[j]; cnt++; j++ }
            val dur = b - a + 1
            val steps = (a..b).sumOf { motion[it]?.steps ?: 0 }
            val hrs = (a..b).mapNotNull { hrBy[it] }
            if (dur >= 12 && cnt >= 8 && steps >= 40 * dur && hrs.size >= dur * 0.6 && hrs.average() >= elevated) out.add(a to b)
            i = j
        }
        return out
    }

    /** [minutes] = (minuto unix, FC media de ese minuto) ordenados. Devuelve (primer minuto, último minuto) de cada actividad. */
    fun detectActivities(
        minutes: List<Pair<Long, Double>>, hrMax: Double, rhr: Int = cachedZoneRhr, motion: Map<Long, MotionMinute>? = null
    ): List<Pair<Long, Long>> {
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
                // Inicio = primer minuto del tramo elevado (22/10: funcional 21/10 empieza a las 18:27 con 102 lpm, como WHOOP;
                // antes, "adelantar mientras ≥ zona 1" daba 18:33). 19/10 y 20/10 siguen exactos.
                val s = s0
                var e = coreIdx.last()
                val lastCore = e
                var low = Double.MAX_VALUE
                for (k in e + 1..e0) {
                    val v = minutes[k].second
                    if (v >= low + ACT_RERISE_BPM) e = k
                    low = minOf(low, v)
                }
                // 25/10 (fútbol 24/10): tras el partido el pulso siguió en 110–125 y los paseos lo alargaban hasta las 21:48 (WHOOP
                // 21:07). Con movimiento grabado: si tras el último minuto intenso estás ≥ 10 min quieto (< 10 pasos y giro < 40),
                // acaba en el último minuto con movimiento. Los otros 7 entrenos con movimiento no cambian.
                if (motion != null) {
                    var lastMove = lastCore; var stillRun = 0
                    for (k in lastCore + 1..e) {
                        val mm = motion[minutes[k].first]
                        if (mm == null) { stillRun = 0; continue }
                        if (mm.steps >= 10 || mm.gyroDps >= 40f) { lastMove = k; stillRun = 0 }
                        else if (++stillRun >= ACT_STILL_CUT_MIN) { e = lastMove; break }
                    }
                }
                if (minutes[e].first - minutes[s].first + 1 >= ACT_MIN_MINUTES) out.add(minutes[s].first to minutes[e].first)
            }
            i = e0 + 1
        }
        return out
    }

    /**
     * Actividades suaves (28/10): pulso moderado sostenido sin minutos intensos (funcional ligero, partido tranquilo). Se usa DESPUÉS
     * de [detectActivities] y [detectWalks]: solo cuenta lo que no se solapa con [taken]. 14 días (14–28/10) con los entrenos de WHOOP:
     * funcional 22/10 18:07–18:42 (WHOOP 18:07–18:41), fútbol 26/10 21:06–22:14 (21:06–22:01), sin ningún falso positivo
     * (lo más parecido que no es entreno: media 95 lpm; aquí hace falta ≥ 100). Muchas combinaciones de parámetros dan lo mismo.
     */
    fun detectSoftActivities(
        minutes: List<Pair<Long, Double>>, hrMax: Double, rhr: Int = cachedZoneRhr, taken: List<Pair<Long, Long>> = emptyList()
    ): List<Pair<Long, Long>> {
        val res = hrMax - rhr
        val thr = rhr + SOFT_ELEVATED_HRR * res
        val meanThr = rhr + SOFT_MEAN_HRR * res
        val n = minutes.size
        if (n == 0) return emptyList()
        val t = LongArray(n) { minutes[it].first }
        val prefix = DoubleArray(n + 1).also { p -> for (k in 0 until n) p[k + 1] = p[k] + minutes[k].second }
        fun lowerBound(x: Long): Int { var lo = 0; var hi = n; while (lo < hi) { val m = (lo + hi) ushr 1; if (t[m] < x) lo = m + 1 else hi = m }; return lo }
        val half = SOFT_WINDOW_MIN / 2
        val sm = DoubleArray(n) { k ->
            val lo = lowerBound(t[k] - half); val hi = lowerBound(t[k] + half + 1)
            (prefix[hi] - prefix[lo]) / (hi - lo)
        }
        val out = ArrayList<Pair<Long, Long>>()
        var i = 0
        while (i < n) {
            if (sm[i] < thr) { i++; continue }
            val s = i; var e = i; var j = i + 1
            while (j < n && t[j] - t[e] <= SOFT_MAX_LOW_MIN + 1) { if (sm[j] >= thr) e = j; j++ }
            val len = t[e] - t[s] + 1
            val count = e - s + 1
            val mean = (prefix[e + 1] - prefix[s]) / count
            if (len >= SOFT_MIN_MINUTES && mean >= meanThr && count >= 0.8 * len &&
                taken.none { it.first < t[e] && it.second > t[s] }) out.add(t[s] to t[e])
            i = e + 1
        }
        return out
    }

    /** FC máx usada en zonas y esfuerzo: la mayor entre la de tu edad y la máxima real registrada. */
    fun hrMax(ageYears: Int): Double = max(tanaka(ageYears), cachedObserved.toDouble())

    fun hrMax(context: Context, ageYears: Int): Double { init(context); return hrMax(ageYears) }

    /** FC máx sin saber la edad (estrés): la registrada, o 195 (la tuya en WHOOP) si no hay. */
    fun hrMaxOrDefault(): Double = if (cachedObserved > 0) cachedObserved.toDouble() else 195.0

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

    // RONDA DE ESFUERZO (22/10) con los 10 entrenos de la API de WHOOP (zonas exactas) + 4 con pulso segundo a segundo:
    //   carga = Σ minutos · r · e^(8,41·r), r = (FC − FCR) / (FCmáx − FCR)   (sin umbral: lo suave apenas suma)
    //   esfuerzo = 2,014 · ln(1 + (carga + 50 · minutos de fuerza) / 10,418)
    // Fuerza/funcional: WHOOP suma carga MUSCULAR ("cardio 50 % / muscular 50 %"); aquí entra en la misma curva, proporcional a la duración
    // (v2 22/10: un bono fijo de +2,72 dejaba los funcionales 19 y 20/10 peor que antes; así quedan todos mejor o igual).
    // Antes (Banister, 0,64·e^(1,92·r), ≥45 % FCmáx, 4,14·ln(1+T/2,6)) daba fútbol 21/10 13,4 (WHOOP 8,8) y pickleball 13,9 (8,7).
    // Ahora (WHOOP): func 19/10 11,6 (11,5) · func 20/10 12,0 (12,6) · func 21/10 11,4 (11,1) · fútbol 21/10 9,8 (8,8) · fútbol 14/10 11,9 (12,6) ·
    // fútbol 15/10 10,3 (9,6) · fútbol 19/10 12,2 (12,8) · pickleball 9,3 (8,7) · paseo 3,3 (4,1). Error medio 2,2 → 0,56 (dejando uno fuera 0,94).
    // Esfuerzo v3 (24/10, 15 casos con pulso segundo a segundo o zonas de la API: 13 entrenos + 2 días): carga por minuto =
    // r·e^(5,005·r) + 0,0951 (r = reserva de FC; el 0,0951 hace que también cuente el rato tranquilo, como WHOOP: mañana 23/10
    // 2,6 = WHOOP 2,6) → esfuerzo = 4,252·ln(1 + (carga + 13,21·min de fuerza)/68,87). Error medio 0,83 → 0,35 (dejando uno
    // fuera 0,50): fútbol 22/10 15,1 (WHOOP 15,1; antes 13,8), fútbol 23/10 7,6 (7,6; antes 8,9), funcional 22/10 9,4 (8,6; 10,5),
    // día 22/10 16,4 (16,3; 14,2). Solo empeora el paseo 17/10, calculado por zonas (1,4 vs 4,1): pendiente de un paseo grabado.
    // Esfuerzo v4 (25/10, + 2 paseos y el partido del 24/10 segundo a segundo): WHOOP da a un paseo de 24–30 min a 100–107 lpm
    // 4,6–4,9 aunque casi todo es zona 0 → los paseos llevan carga por minuto propia, como la fuerza. 18 casos: error medio 0,57 → 0,21
    // (dejando uno fuera 0,46): paseos 24/10 4,9/5,1 (WHOOP 4,8/4,6; antes 2,8/2,4), paseo 17/10 3,7 (4,1), fútbol 24/10 18,4 (18,4).
    const val STRAIN_SCALE = 4.5300296
    const val STRAIN_TRIMP_REF = 90.426399
    const val STRAIN_EXP = 5.1623827
    const val STRAIN_BASE_PER_MIN = 0.1208666
    const val STRENGTH_LOAD_PER_MIN = 14.613395
    const val WALK_LOAD_PER_MIN = 4.3826189
    const val DEFAULT_RESTING_HR = 58

    /** Fuerza / funcional: WHOOP les suma carga muscular. */
    fun isStrength(type: String?): Boolean {
        val t = type?.lowercase() ?: return false
        return "funcional" in t || "fuerza" in t || "crossfit" in t || "gimnasio" in t || "pesas" in t
    }

    /** Paseo / caminar / senderismo: WHOOP también les suma carga por minuto (25/10). */
    fun isWalk(type: String?): Boolean {
        val t = type?.lowercase() ?: return false
        return "caminar" in t || "paseo" in t || "senderismo" in t || "andar" in t
    }

    /** Minutos "de fuerza equivalentes" de una actividad: fuerza = sus minutos; paseo = sus minutos × 4,38/14,61; resto 0. */
    fun muscleMinutes(type: String?, minutes: Double): Double = when {
        minutes <= 0 -> 0.0
        isStrength(type) -> minutes
        isWalk(type) -> minutes * WALK_LOAD_PER_MIN / STRENGTH_LOAD_PER_MIN
        else -> 0.0
    }

    @Suppress("UNUSED_PARAMETER")
    fun trimp(minutes: Double, hr: Int, restingHr: Int, hrMax: Double, male: Boolean = true, withBase: Boolean = true): Double {
        if (minutes <= 0) return 0.0
        val reserve = (hrMax - restingHr).coerceAtLeast(20.0)
        val hrr = ((hr - restingHr) / reserve).coerceIn(0.0, 1.1)
        return minutes * (hrr * exp(STRAIN_EXP * hrr) + if (withBase) STRAIN_BASE_PER_MIN else 0.0)
    }

    fun strainFromTrimp(trimp: Double, strengthMinutes: Double = 0.0): Double =
        (STRAIN_SCALE * ln(1.0 + (max(0.0, trimp) + STRENGTH_LOAD_PER_MIN * max(0.0, strengthMinutes)) / STRAIN_TRIMP_REF)).coerceIn(0.0, 21.0)

    /**
     * Esfuerzo del día + la carga muscular de [strengthMinutes] minutos de fuerza/funcional (se suma en la misma curva)
     * + la base por minuto de las actividades ([activityMinutes], 27/10): el pulso del día va SIN base (ver [strainOf]).
     */
    fun addStrength(strain: Double, strengthMinutes: Double, activityMinutes: Double = 0.0): Double {
        if (strengthMinutes <= 0 && activityMinutes <= 0) return strain
        val t = STRAIN_TRIMP_REF * (kotlin.math.exp(strain / STRAIN_SCALE) - 1.0) + STRAIN_BASE_PER_MIN * max(0.0, activityMinutes)
        return strainFromTrimp(t, max(0.0, strengthMinutes))
    }

    /** Minutos de actividades que llevan la base por minuto en el esfuerzo del día (todas menos las siestas). */
    fun activityLoadMinutes(type: String?, minutes: Double): Double = if (minutes <= 0 || type == NAP_TYPE) 0.0 else minutes

    /**
     * Esfuerzo del DÍA (27/10): sin la base por minuto. Con ella, 24 h de pulso en reposo sumaban 2,5–3 puntos que WHOOP no da
     * (noche 26→27: 2,8 vs 0,2; día 25/10 6,7 vs 4,1). La base solo cuenta dentro de las actividades ([addStrength]).
     */
    fun strainOf(
        readings: List<Pair<Long, Int>>, restingHr: Int?, hrMax: Double, male: Boolean = true, maxGapMinutes: Double = 5.0
    ): Double {
        if (readings.size < 2) return 0.0
        val rhr = restingHr ?: DEFAULT_RESTING_HR
        var total = 0.0
        for (i in 1 until readings.size) {
            val dt = (readings[i].first - readings[i - 1].first) / 60000.0
            if (dt <= 0 || dt > maxGapMinutes) continue
            total += trimp(dt, readings[i].second, rhr, hrMax, male, withBase = false)
        }
        return strainFromTrimp(total)
    }

    // ---------- Recuperación ----------

    /**
     * Recuperación (23/10): lineal, ajustada con 199 noches de WHOOP (export abr–sep + API sep–oct), validación cruzada
     * 4,8 puntos de error medio (la sigmoide de antes: 5,9; en las 39 noches más recientes 4,3 frente a 6,6):
     *   recuperación = 64,28 + 89,74 · (ln VFC − media ln VFC) − 0,4625 · (FCR − media FCR)
     */
    const val REC_BIAS = 64.2755
    const val REC_K_HRV = 89.7396
    const val REC_K_RHR = 0.4625
    /**
     * Línea base de partida (23/10): la de WHOOP el 14/10, antes de usar PulseApp (media ponderada de 14 días de tus
     * 30 noches anteriores en WHOOP: VFC 88 ms, FC reposo 58,5). BaselineProvider parte de aquí y cada noche propia la mueve.
     */
    const val FALLBACK_HRV = 88.0
    const val FALLBACK_RHR = 58.5

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
        var score = REC_BIAS + REC_K_HRV * (delta ?: -0.1) - REC_K_RHR * (rhrDelta ?: 0.0)
        var penalty = false
        if (respiratoryRate != null && respiratoryRate in 8.0..25.0 && b?.respMean != null && b.respSd != null) {
            val z = (respiratoryRate - b.respMean) / b.respSd
            if (z > 2.0) { score -= 12.0 * (z - 2.0); penalty = true }
        }
        val total = floor(score).toInt().coerceIn(1, 99)
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
    /**
     * 26/10: WHOOP mide la regularidad en hora "del cuerpo", sin el cambio de hora (con sus propias horas de 9 noches: en hora
     * local la noche 25→26 da 54 %, sin cambio de hora 67 %, WHOOP 66 %; error medio 4,7 → 3,5). Pasa la noche [date]
     * (inicio [s], fin [e] en minutos del día, hora local) a hora de invierno: en verano se resta 1 h.
     */
    fun standardNight(date: String, s: Int, e: Int): Pair<Int, Int> {
        val d = try { java.time.LocalDate.parse(date) } catch (ex: Exception) { return s to e }
        val tz = java.util.TimeZone.getDefault()
        val zone = java.time.ZoneId.systemDefault()
        fun shift(day: java.time.LocalDate, minute: Int): Int {
            val t = day.atStartOfDay(zone).toInstant().toEpochMilli() + minute * 60_000L
            return (tz.getOffset(t) - tz.rawOffset) / 60_000
        }
        val startDay = if (s > e) d.minusDays(1) else d
        return (s - shift(startDay, s)) to (e - shift(d, e))
    }

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
