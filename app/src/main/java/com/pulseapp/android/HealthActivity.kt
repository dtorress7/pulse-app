package com.pulseapp.android

import android.content.Intent
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import com.pulseapp.android.data.AppDatabase
import com.pulseapp.android.ui.LiveHrLineView
import com.pulseapp.android.ui.StressDayChartView
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.RandomAccessFile
import java.text.SimpleDateFormat
import java.util.Locale

/**
 * Monitor de salud con el aspecto de WHOOP (17/10): pulso en directo con su zona, y la respiración, la FCR y la VFC de
 * la noche frente a tu rango habitual (media ± 1 desviación de los 14 días anteriores). Es también la pestaña Salud.
 */
class HealthActivity : AppCompatActivity() {

    companion object {
        const val EXTRA_FROM_HOME = "from_home"
    }

    private val livePoints = ArrayList<Pair<Long, Int>>()
    private var hrMax = 190.0
    private val handler = android.os.Handler(android.os.Looper.getMainLooper())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_health)
        window.statusBarColor = Ui.color(this, R.color.w_bg_top)
        Ui.setupDetailHeader(this, "Monitor de salud")
        val fromHome = intent.getBooleanExtra(EXTRA_FROM_HOME, false)
        findViewById<View>(R.id.backButton).visibility = if (fromHome) View.VISIBLE else View.INVISIBLE
        Ui.setupTabBar(this, if (fromHome) Ui.Tab.NONE else Ui.Tab.HEALTH)
        findViewById<View>(R.id.stressCard).setOnClickListener {
            startActivity(Intent(this, StressDetailActivity::class.java))
        }
    }

    override fun onResume() {
        super.onResume()
        load()
        handler.post(ticker)
    }

    override fun onPause() {
        super.onPause()
        handler.removeCallbacks(ticker)
    }

    /** Cada 2 s añade el último pulso recibido de la pulsera. */
    private val ticker = object : Runnable {
        override fun run() {
            val t = WhoopBackgroundService.lastBpmTime
            val bpm = WhoopBackgroundService.lastBpm
            if (bpm != null && t > System.currentTimeMillis() - 15_000 && (livePoints.isEmpty() || livePoints.last().first < t)) {
                livePoints.add(t to bpm)
                while (livePoints.size > 900) livePoints.removeAt(0)
            }
            showLive()
            handler.postDelayed(this, 2000)
        }
    }

    private fun showLive() {
        val now = System.currentTimeMillis()
        val last = livePoints.lastOrNull()
        val fresh = last != null && last.first > now - 15_000
        findViewById<TextView>(R.id.liveBpmText).text = if (fresh) last!!.second.toString() else "--"
        val zone = if (fresh) zoneOf(last!!.second) else -1
        findViewById<TextView>(R.id.liveZoneText).text = if (zone >= 0) "Zona $zone" else ""
        findViewById<TextView>(R.id.liveStatusText).text = when {
            fresh -> ""
            WhoopBackgroundService.findBondedWhoop(this) == null -> "Vincula tu WHOOP en Inicio → Más → Mi WHOOP"
            !WhoopBackgroundService.isRunning -> "WHOOP desconectada"
            else -> "Esperando pulso de la WHOOP…"
        }
        val seg = findViewById<LinearLayout>(R.id.zoneSegments)
        seg.removeAllViews()
        for (z in 1..5) {
            seg.addView(View(this).apply {
                background = W.rounded(this@HealthActivity, if (zone >= z) zoneColor(z) else R.color.w_track, 2f)
                layoutParams = LinearLayout.LayoutParams(Ui.dp(this@HealthActivity, 26f), LinearLayout.LayoutParams.MATCH_PARENT).apply {
                    if (z > 1) marginStart = Ui.dp(this@HealthActivity, 4f)
                }
            })
        }
        findViewById<LiveHrLineView>(R.id.liveLine).setPoints(livePoints.toList())
    }

    private fun zoneOf(bpm: Int): Int = Formulas.zoneOf(bpm, Formulas.zoneBounds(hrMax))

    private fun zoneColor(z: Int) = when (z) {
        1 -> R.color.w_zone1; 2 -> R.color.w_zone2; 3 -> R.color.w_zone3; 4 -> R.color.w_zone4; else -> R.color.w_zone5
    }

    private fun load() {
        lifecycleScope.launch {
            val ctx = this@HealthActivity
            val profile = AppDatabase.getInstance(ctx).userProfileDao().getOnce()
            hrMax = Formulas.hrMax(profile?.ageYears() ?: 30)
            val recent = withContext(Dispatchers.IO) { tailReadings(File(getExternalFilesDir(null), "hr_log.csv"), 10 * 60_000L) }
            if (recent.isNotEmpty()) {
                val merged = (recent + livePoints).sortedBy { it.first }.distinctBy { it.first / 1000 }
                livePoints.clear()
                livePoints.addAll(merged)
            }
            showLive()

            val d = HomeDataLoader(ctx).load(0)
            fillVitals(d)
            fillExtras(d)
            findViewById<TextView>(R.id.stressScoreText).text = d.stressScore?.let { Ui.comma(it.toDouble()) } ?: "--"
            findViewById<TextView>(R.id.stressLevelText).apply {
                text = if (d.stressScore != null) d.stressLevel else ""
                setTextColor(Ui.color(ctx, W.stressColor(d.stressLevel)))
            }
            findViewById<StressDayChartView>(R.id.stressChart)
                .setData(d.stressSeries, d.stressFrom, d.stressTo, d.sleepFromMillis, d.sleepToMillis, true)
        }
    }

    private fun fmt(v: Double, decimals: Int) = if (decimals == 0) "%.0f".format(v) else Ui.comma(v, decimals)

    private fun fillVitals(d: HomeData) {
        val ctx = this
        val grid = findViewById<LinearLayout>(R.id.vitalsGrid)
        grid.removeAllViews()
        val temp = VitalStatus("temp", "Temp. cutánea (dif. valor inicial)", R.drawable.ic_thermo, null, "°C", 1, null, null, true, null)
        val tiles = d.vitals + temp
        tiles.chunked(2).forEachIndexed { rowIndex, pair ->
            val row = LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL
                layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
                    if (rowIndex > 0) topMargin = Ui.dp(ctx, 12f)
                }
            }
            pair.forEachIndexed { i, v ->
                row.addView(tile(v).apply {
                    layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1f).apply {
                        if (i == 0) marginEnd = Ui.dp(ctx, 6f) else marginStart = Ui.dp(ctx, 6f)
                    }
                })
            }
            if (pair.size == 1) row.addView(View(ctx).apply {
                layoutParams = LinearLayout.LayoutParams(0, 1, 1f).apply { marginStart = Ui.dp(ctx, 6f) }
            })
            grid.addView(row)
        }
        findViewById<TextView>(R.id.vitalsNote).text = when {
            d.healthTotal == 0 -> "Tu rango habitual aparece con ${BaselineProvider.MIN_DAYS_REQUIRED} noches guardadas."
            else -> "${d.healthOk}/${d.healthTotal} métricas dentro de tu rango. El oxígeno en sangre no se puede medir sin la nube de WHOOP."
        }
    }

    private fun tile(v: VitalStatus): LinearLayout {
        val ctx = this
        return LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundResource(R.drawable.bg_card_w)
            val p = Ui.dp(ctx, 16f)
            setPadding(p, p, p, p)
            addView(LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                addView(W.icon(ctx, v.iconRes, 22f, R.color.text_secondary))
                addView(W.title(ctx, v.label, 13.5f, R.color.text_secondary).apply {
                    setPadding(Ui.dp(ctx, 12f), 0, 0, 0)
                    setLineSpacing(Ui.dp(ctx, 4f).toFloat(), 1f)
                    layoutParams = W.weight()
                })
            })
            addView(LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.BOTTOM
                setPadding(0, Ui.dp(ctx, 18f), 0, 0)
                addView(W.number(ctx, v.value?.let { fmt(it, v.decimals) } ?: "--", 46f))
                addView(W.body(ctx, v.unit, 18f, R.color.text_primary).apply { setPadding(Ui.dp(ctx, 6f), 0, 0, Ui.dp(ctx, 4f)) })
            })
            val (text, ok) = chipText(v)
            val bg = when (ok) { true -> R.color.w_mint_bg; false -> R.color.w_stress_high_dim; null -> R.color.w_chip }
            val fg = when (ok) { true -> R.color.w_mint; false -> R.color.alert_amber; null -> R.color.text_secondary }
            addView(LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                background = W.rounded(ctx, bg, 6f)
                setPadding(Ui.dp(ctx, 8f), Ui.dp(ctx, 5f), Ui.dp(ctx, 10f), Ui.dp(ctx, 5f))
                layoutParams = W.wrap().apply { topMargin = Ui.dp(ctx, 16f) }
                if (ok != null) addView(W.icon(ctx, if (ok) R.drawable.ic_check else R.drawable.ic_info, 14f, fg))
                addView(W.number(ctx, text, 15.5f, fg).apply { setPadding(Ui.dp(ctx, if (ok != null) 6f else 0f), 0, 0, 0) })
            })
        }
    }

    /** Texto de la etiqueta como WHOOP: "dentro de 54 - 61", "elevado > 107", "baja < 13,4". */
    private fun chipText(v: VitalStatus): Pair<String, Boolean?> {
        val value = v.value ?: return (if (v.key == "temp") "sin datos de la pulsera" else "sin datos esta noche") to null
        val lo = v.lo; val hi = v.hi
        if (lo == null || hi == null || v.ok == null) return "calibrando" to null
        val loS = fmt(lo, v.decimals); val hiS = fmt(hi, v.decimals)
        return when {
            value > hi -> (if (v.key == "hrv") "elevado > $hiS" else "alta > $hiS") to v.ok
            value < lo -> (if (v.key == "hrv") "bajo < $loS" else "baja < $loS") to v.ok
            else -> "dentro de $loS - $hiS" to true
        }
    }

    private fun fillExtras(d: HomeData) {
        val ctx = this
        val list = findViewById<LinearLayout>(R.id.extrasList)
        list.removeAllViews()
        val rows = d.panel.associateBy { it.key }
        listOf(PanelKeys.STEPS, PanelKeys.KCAL, PanelKeys.VO2).forEach { k -> rows[k]?.let { list.addView(W.panelRow(ctx, it)) } }
        val avgHr = d.summary?.avgHr
        list.addView(W.panelRow(ctx, PanelRow("avg_hr", "FC MEDIA DE HOY", R.drawable.ic_heart, avgHr?.toString() ?: "--", null, null, null)))
    }

    /** Lecturas de los últimos [windowMs] leyendo solo el final del archivo (rápido aunque hr_log.csv sea grande). */
    private fun tailReadings(file: File, windowMs: Long): List<Pair<Long, Int>> {
        if (!file.exists()) return emptyList()
        val sdf = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.US)
        val from = System.currentTimeMillis() - windowMs
        return try {
            RandomAccessFile(file, "r").use { raf ->
                val len = raf.length()
                val start = maxOf(0L, len - 200_000L)
                raf.seek(start)
                val bytes = ByteArray((len - start).toInt())
                raf.readFully(bytes)
                String(bytes).lineSequence().drop(if (start > 0) 1 else 0).mapNotNull { line ->
                    val p = line.split(',')
                    if (p.size < 2) return@mapNotNull null
                    val t = try { sdf.parse(p[0])?.time } catch (e: Exception) { null } ?: return@mapNotNull null
                    val b = p[1].toIntOrNull() ?: return@mapNotNull null
                    if (t < from || b <= 0 || b > 250) null else t to b
                }.sortedBy { it.first }.distinctBy { it.first / 1000 }.toList()
            }
        } catch (e: Exception) { emptyList() }
    }
}
