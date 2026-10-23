package com.pulseapp.android

import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.sqrt

/**
 * Fases del sueño aprendidas del hipnograma de WHOOP (23/10).
 *
 * Entrenado con 8 noches (16→23/10) en las que se leyó la fase de WHOOP minuto a minuto de las capturas de la app.
 * Validación dejando cada noche fuera: 81 % de los minutos en la misma fase que WHOOP (el método de umbrales de antes: 49 %).
 * Por minuto se calculan 17 rasgos de pulso, VFC, movimiento y momento de la noche; un conjunto de árboles
 * (sleep_model.json, 150 rondas × 4 fases, profundidad 3) da la probabilidad de cada fase, y Viterbi (permanencia 0,9)
 * elige la secuencia más probable sin saltos sueltos. Lo que más pesa: el profundo tiene el pulso muy estable y llega tras
 * mucho rato sin moverse, sobre todo al principio de la noche; el REM sube el pulso, baja la VFC y suele ir tras un movimiento.
 *
 * Los rasgos se calculan exactamente igual que en el entrenamiento (check/hyp/feat2.py y model3.py). El orden de las fases del
 * modelo (D, L, P, R) coincide con SleepStager.AWAKE/LIGHT/DEEP/REM.
 */
object SleepModel {

    class Second(val bpm: Int, val rr: List<Double>)
    class Minute(val still: Double, val gyro: Double, val steps: Double)

    private class Tree(val f: IntArray, val t: DoubleArray, val l: IntArray, val r: IntArray, val v: DoubleArray)
    private class Model(val baseline: DoubleArray, val bias: DoubleArray, val stay: Double, val trees: List<Tree>)

    @Volatile private var model: Model? = null
    @Volatile private var loadFailed = false

    private fun load(): Model? {
        model?.let { return it }
        if (loadFailed) return null
        return try {
            val text = SleepModel::class.java.getResourceAsStream("/sleep_model.json")!!.bufferedReader().use { it.readText() }
            @Suppress("UNCHECKED_CAST")
            val root = MiniJson(text).parse() as Map<String, Any?>
            fun nums(a: Any?): DoubleArray = (a as List<*>).map { (it as Number).toDouble() }.toDoubleArray()
            val trees = (root["trees"] as List<*>).map { o ->
                val m = o as Map<*, *>
                Tree(nums(m["f"]).map { it.toInt() }.toIntArray(), nums(m["t"]), nums(m["l"]).map { it.toInt() }.toIntArray(),
                    nums(m["r"]).map { it.toInt() }.toIntArray(), nums(m["v"]))
            }
            Model(nums(root["baseline"]), nums(root["bias"]), (root["stay"] as Number).toDouble(), trees).also { model = it }
        } catch (e: Exception) {
            loadFailed = true
            null
        }
    }

    /**
     * Fases de cada minuto. [secs][i] = lecturas de cada segundo del minuto i (en orden), [mot][i] = movimiento del minuto i
     * (null si no hay). null si el modelo no se puede cargar.
     */
    fun classify(secs: List<List<Second>>, mot: List<Minute?>): IntArray? {
        val m = load() ?: return null
        val x = features(secs, mot)
        val n = x.size
        val k = 4
        val emis = Array(n) { DoubleArray(k) }
        for (i in 0 until n) {
            val raw = m.baseline.copyOf()
            for ((idx, t) in m.trees.withIndex()) {
                var node = 0
                while (t.f[node] >= 0) node = if (x[i][t.f[node]] <= t.t[node]) t.l[node] else t.r[node]
                raw[idx % k] += t.v[node]
            }
            val mx = raw.max()
            var s = 0.0
            val p = DoubleArray(k) { exp(raw[it] - mx + m.bias[it]) }
            for (v in p) s += v
            for (c in 0 until k) emis[i][c] = ln(p[c] / s + 1e-9)
        }
        // Viterbi
        val stayL = ln(m.stay); val moveL = ln((1 - m.stay) / (k - 1))
        var d = emis[0].copyOf()
        val back = Array(n) { IntArray(k) }
        for (i in 1 until n) {
            val nd = DoubleArray(k)
            for (c in 0 until k) {
                var best = Double.NEGATIVE_INFINITY; var arg = 0
                for (p in 0 until k) {
                    val v = d[p] + if (p == c) stayL else moveL
                    if (v > best) { best = v; arg = p }
                }
                nd[c] = best + emis[i][c]; back[i][c] = arg
            }
            d = nd
        }
        val st = IntArray(n)
        var bestC = 0
        for (c in 1 until k) if (d[c] > d[bestC]) bestC = c
        st[n - 1] = bestC
        for (i in n - 1 downTo 1) st[i - 1] = back[i][st[i]]
        return st
    }

    // ---------- Rasgos (idénticos a feat2.py / model3.py) ----------

    private fun nanMedian(a: DoubleArray, from: Int, to: Int): Double {
        val v = ArrayList<Double>()
        for (j in from..to) if (!a[j].isNaN()) v.add(a[j])
        if (v.isEmpty()) return Double.NaN
        v.sort(); val h = v.size / 2
        return if (v.size % 2 == 1) v[h] else (v[h - 1] + v[h]) / 2
    }

    private fun nanStd(a: DoubleArray, from: Int, to: Int): Double {
        var s = 0.0; var c = 0
        for (j in from..to) if (!a[j].isNaN()) { s += a[j]; c++ }
        if (c == 0) return Double.NaN
        val m = s / c; var q = 0.0
        for (j in from..to) if (!a[j].isNaN()) q += (a[j] - m) * (a[j] - m)
        return sqrt(q / c)
    }

    private fun nanPercentile(a: DoubleArray, p: Double): Double {
        val v = a.filter { !it.isNaN() }.sorted()
        if (v.isEmpty()) return Double.NaN
        val pos = p / 100.0 * (v.size - 1)
        val lo = pos.toInt(); val hi = minOf(lo + 1, v.size - 1)
        return v[lo] + (v[hi] - v[lo]) * (pos - lo)
    }

    private fun rmssdLn(rr: List<Double>): Double {
        val out = ArrayList<Double>(rr.size)
        for (x in rr) {
            if (out.isNotEmpty() && abs(x - out.last()) / out.last() > 0.2) continue
            out.add(x)
        }
        if (out.size < 20) return Double.NaN
        var s = 0.0
        for (i in 1 until out.size) { val dd = out[i] - out[i - 1]; s += dd * dd }
        return ln(sqrt(s / (out.size - 1)))
    }

    fun features(secs: List<List<Second>>, mot: List<Minute?>): Array<DoubleArray> {
        val n = secs.size
        fun lo(i: Int, k: Int) = maxOf(0, i - k)
        fun hi(i: Int, k: Int) = minOf(n - 1, i + k)
        val hr = DoubleArray(n) { i -> if (secs[i].isEmpty()) Double.NaN else secs[i].sumOf { it.bpm }.toDouble() / secs[i].size }
        val hr5 = DoubleArray(n) { nanMedian(hr, lo(it, 2), hi(it, 2)) }
        val lnr = DoubleArray(n) { i ->
            val rr = ArrayList<Double>()
            for (j in lo(i, 3)..hi(i, 3)) for (s in secs[j]) rr.addAll(s.rr)
            rmssdLn(rr)
        }
        val hsd = DoubleArray(n) { i ->
            val v = ArrayList<Double>()
            for (j in lo(i, 2)..hi(i, 2)) for (s in secs[j]) v.add(s.bpm.toDouble())
            if (v.size > 30) { val m = v.average(); sqrt(v.sumOf { (it - m) * (it - m) } / v.size) } else Double.NaN
        }
        fun locmed(a: DoubleArray, k: Int) = DoubleArray(n) { nanMedian(a, lo(it, k), hi(it, k)) }
        val med30h = locmed(hr5, 30); val med10h = locmed(hr5, 10); val med90h = locmed(hr5, 90)
        val med30l = locmed(lnr, 30); val med90l = locmed(lnr, 90)
        val still = DoubleArray(n) { mot[it]?.still ?: Double.NaN }
        val gyro = DoubleArray(n) { mot[it]?.gyro ?: Double.NaN }
        val steps = DoubleArray(n) { mot[it]?.steps ?: Double.NaN }
        val since = DoubleArray(n)
        var last = -999
        for (i in 0 until n) {
            if (!(still[i] >= 50 && gyro[i] < 3)) last = i
            since[i] = (i - last).toDouble()
        }
        val hsd10 = DoubleArray(n) { nanStd(hr, lo(it, 5), hi(it, 5)) }
        val gmax5 = DoubleArray(n) { i ->
            var mx = Double.NaN
            for (j in lo(i, 5)..hi(i, 5)) if (!gyro[j].isNaN() && (mx.isNaN() || gyro[j] > mx)) mx = gyro[j]
            mx
        }
        val p10 = nanPercentile(hr5, 10.0)
        val lnrMed = nanMedian(lnr, 0, n - 1)
        return Array(n) { i ->
            val prog = i.toDouble() / n
            val row = doubleArrayOf(
                hr5[i] - med30h[i], lnr[i] - med30l[i], ln(1 + hsd[i]), ln(1 + minOf(since[i], 240.0)), prog, prog * prog,
                ln(1 + gyro[i]), still[i] / 60, minOf(steps[i], 20.0), hr5[i] - p10, lnr[i] - lnrMed,
                ln(1 + hsd10[i]), hr5[i] - med10h[i], hr5[i] - med90h[i], lnr[i] - med90l[i], minOf(i.toDouble(), 300.0) / 300, ln(1 + gmax5[i]))
            for (c in row.indices) if (row[c].isNaN()) row[c] = 0.0
            row
        }
    }
}

/** Lector JSON mínimo (objetos, listas, números, textos, true/false/null) para no depender de org.json. */
class MiniJson(private val s: String) {
    private var i = 0
    fun parse(): Any? { ws(); return value() }
    private fun ws() { while (i < s.length && s[i].isWhitespace()) i++ }
    private fun value(): Any? {
        ws()
        return when (s[i]) {
            '{' -> obj()
            '[' -> arr()
            '"' -> str()
            't' -> { i += 4; true }
            'f' -> { i += 5; false }
            'n' -> { i += 4; null }
            else -> num()
        }
    }
    private fun obj(): Map<String, Any?> {
        val m = LinkedHashMap<String, Any?>(); i++; ws()
        if (s[i] == '}') { i++; return m }
        while (true) {
            ws(); val k = str(); ws(); i++ // ':'
            m[k] = value(); ws()
            if (s[i] == ',') { i++; continue }
            i++; return m
        }
    }
    private fun arr(): List<Any?> {
        val a = ArrayList<Any?>(); i++; ws()
        if (s[i] == ']') { i++; return a }
        while (true) {
            a.add(value()); ws()
            if (s[i] == ',') { i++; continue }
            i++; return a
        }
    }
    private fun str(): String {
        val b = StringBuilder(); i++
        while (s[i] != '"') { if (s[i] == '\\') { i++ }; b.append(s[i]); i++ }
        i++; return b.toString()
    }
    private fun num(): Double {
        val st = i
        while (i < s.length && (s[i].isDigit() || s[i] in "+-.eE")) i++
        return s.substring(st, i).toDouble()
    }
}
