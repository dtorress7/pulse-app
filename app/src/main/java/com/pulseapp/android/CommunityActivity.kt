package com.pulseapp.android

import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.os.Bundle
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.res.ResourcesCompat
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch
import java.time.LocalDate
import java.time.ZoneId

/** Pestaña Comunidad (como la de WHOOP): tus equipos, crear uno o unirte con un código. */
class CommunityActivity : AppCompatActivity() {

    private var profile: CProfile? = null
    private var teams: List<CTeam> = emptyList()
    private var error = ""
    private var editingName = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_activities)
        window.statusBarColor = Ui.color(this, R.color.w_bg_top)
        Ui.setupDetailHeader(this, "Comunidad")
        findViewById<View>(R.id.backButton).visibility = View.INVISIBLE
        Ui.setupTabBar(this, Ui.Tab.COMMUNITY)
    }

    override fun onResume() {
        super.onResume()
        load()
    }

    private fun dp(v: Float) = Ui.dp(this, v)
    private val content get() = findViewById<LinearLayout>(R.id.detailContent)

    private fun load() {
        if (!CommunityConfig.isConfigured(this)) { render(); return }
        if (!CommunityApi.hasSession(this)) { profile = null; render(); return }
        content.removeAllViews()
        content.addView(ProgressBar(this).apply { setPadding(0, dp(60f), 0, 0) })
        lifecycleScope.launch {
            try {
                profile = CommunityApi.myProfile(this@CommunityActivity)
                teams = CommunityApi.myTeams(this@CommunityActivity)
                error = ""
            } catch (e: Exception) { error = e.message ?: "Error" }
            render()
        }
    }

    private fun render() {
        val c = content
        c.removeAllViews()
        when {
            !CommunityConfig.isConfigured(this) -> c.addView(serverCard())
            profile == null || profile!!.name.isEmpty() || editingName -> c.addView(profileCard())
            else -> teamsList(c)
        }
        if (error.isNotEmpty()) c.addView(W.body(this, error, 14f, R.color.alert_amber).apply { setPadding(0, dp(14f), 0, 0) })
    }

    private fun field(hint: String, value: String, caps: Boolean = false): EditText = EditText(this).apply {
        this.hint = hint
        setText(value)
        setTextColor(Ui.color(this@CommunityActivity, R.color.text_primary))
        setHintTextColor(Ui.color(this@CommunityActivity, R.color.text_secondary))
        background = W.rounded(this@CommunityActivity, R.color.w_row, 10f)
        setPadding(dp(12f), dp(12f), dp(12f), dp(12f))
        inputType = if (caps) InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_CHARACTERS else InputType.TYPE_CLASS_TEXT
        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(8f) }
    }

    private fun greenButton(text: String, action: () -> Unit): TextView = W.title(this, text, 14f, R.color.text_on_accent).apply {
        gravity = Gravity.CENTER
        background = W.rounded(this@CommunityActivity, R.color.recovery_green, 12f)
        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(46f)).apply { topMargin = dp(12f) }
        setOnClickListener { action() }
    }

    /** Solo si la app no trae ya los datos del servidor: pegar la dirección y la clave pública de Supabase. */
    private fun serverCard() = W.card(this, 18f).apply {
        addView(W.title(this@CommunityActivity, "Conectar con el servidor"))
        addView(W.body(this@CommunityActivity, "Pega la Project URL y la clave anon/publishable de tu proyecto de Supabase.", 14f).apply { setPadding(0, dp(8f), 0, 0) })
        val u = field("https://xxxx.supabase.co", CommunityConfig.url(this@CommunityActivity))
        val k = field("Clave pública", CommunityConfig.key(this@CommunityActivity))
        addView(u); addView(k)
        addView(greenButton("Guardar") {
            CommunityConfig.set(this@CommunityActivity, u.text.toString().trim(), k.text.toString().trim())
            load()
        })
    }

    /** Primera vez: tu nombre y tu @usuario (es lo que ven tus amigos). */
    private fun profileCard() = W.card(this, 18f).apply {
        addView(W.title(this@CommunityActivity, "¿Cómo te verán tus amigos?"))
        val n = field("Nombre y apellido", profile?.name ?: "")
        val u = field("Usuario (sin @)", profile?.username ?: "")
        addView(n); addView(u)
        addView(greenButton("Continuar") {
            val name = n.text.toString().trim()
            val user = u.text.toString().trim().replace("@", "").replace(" ", "")
            if (name.length < 2 || user.length < 2) { error = "Escribe tu nombre y un usuario."; render(); return@greenButton }
            lifecycleScope.launch {
                try {
                    CommunityApi.saveProfile(this@CommunityActivity, name.take(40), user.take(30))
                    editingName = false
                    error = ""
                    load()
                } catch (e: Exception) { error = e.message ?: "Error"; render() }
            }
        })
        addView(W.body(this@CommunityActivity, "No hace falta correo ni contraseña: tu móvil entra con una cuenta anónima. Si borras la app, " +
            "pierdes el acceso a tus equipos (podrás volver a unirte con el código).", 12.5f).apply { setPadding(0, dp(10f), 0, 0) })
    }

    private fun teamsList(c: LinearLayout) {
        c.addView(W.title(this, "Mis equipos", 14.5f, R.color.text_secondary).apply { setPadding(0, dp(18f), 0, dp(4f)) })
        if (teams.isEmpty()) c.addView(W.body(this, "Aún no estás en ningún equipo. Crea uno y comparte el código, o únete con el código de un amigo. " +
            "Solo veréis los datos de la gente de vuestros equipos.", 15f))
        teams.forEach { t ->
            c.addView(LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setBackgroundResource(R.drawable.bg_card_w)
                setPadding(dp(16f), dp(16f), dp(16f), dp(16f))
                layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(12f) }
                addView(AvatarRingView(this@CommunityActivity).apply {
                    setData(t.name, null, 0, team = true); layoutParams = LinearLayout.LayoutParams(dp(48f), dp(48f))
                })
                addView(LinearLayout(this@CommunityActivity).apply {
                    orientation = LinearLayout.VERTICAL
                    layoutParams = W.weight().apply { marginStart = dp(14f) }
                    addView(W.title(this@CommunityActivity, t.name, 17f))
                    addView(W.body(this@CommunityActivity, "Código ${t.inviteCode}", 13f))
                })
                addView(W.icon(this@CommunityActivity, R.drawable.ic_chevron_right, 18f, R.color.text_secondary))
                setOnClickListener { openTeam(t) }
            })
        }
        c.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(16f) }
            addView(rowButton("Crear equipo") { askCreate() }.apply { layoutParams = W.weight().apply { marginEnd = dp(5f) } })
            addView(rowButton("Unirme con código") { askJoin() }.apply { layoutParams = W.weight().apply { marginStart = dp(5f) } })
        })
        c.addView(W.body(this, "Tú apareces como ${profile?.name} (@${profile?.username}). Lo que compartes: esfuerzo, actividades y calorías, " +
            "recuperación con VFC y FC en reposo, y horas y calificación del sueño.", 13f).apply { setPadding(0, dp(14f), 0, 0) })
        c.addView(W.body(this, "Cambiar mi nombre", 14f, R.color.strain_blue).apply {
            setPadding(0, dp(10f), 0, 0)
            setOnClickListener { editingName = true; render() }
        })
    }

    private fun rowButton(text: String, action: () -> Unit): TextView = W.title(this, text, 13.5f).apply {
        gravity = Gravity.CENTER
        setBackgroundResource(R.drawable.bg_row_w)
        minHeight = dp(50f)
        setOnClickListener { action() }
    }

    private fun openTeam(t: CTeam) {
        startActivity(Intent(this, TeamActivity::class.java).putExtra(TeamActivity.EXTRA_TEAM, t))
    }

    private fun askText(title: String, hint: String, message: String, ok: String, caps: Boolean, onOk: (String) -> Unit) {
        val input = field(hint, "", caps)
        val box = FrameLayout(this).apply { setPadding(dp(20f), dp(8f), dp(20f), 0); addView(input) }
        AlertDialog.Builder(this).setTitle(title).setMessage(message).setView(box)
            .setPositiveButton(ok) { _, _ -> input.text.toString().trim().takeIf { it.isNotEmpty() }?.let(onOk) }
            .setNegativeButton("Cancelar", null).show()
    }

    private fun askCreate() = askText("Crear equipo", "Nombre del equipo", "Luego compartes el código con tus amigos para que se unan.", "Crear", false) { name ->
        lifecycleScope.launch {
            try { openTeam(CommunityApi.createTeam(this@CommunityActivity, name.take(40))) } catch (e: Exception) { error = e.message ?: "Error"; render() }
        }
    }

    private fun askJoin() = askText("Unirme a un equipo", "Código (6 letras)", "Pide el código a quien creó el equipo.", "Unirme", true) { code ->
        lifecycleScope.launch {
            try { openTeam(CommunityApi.joinTeam(this@CommunityActivity, code)) } catch (e: Exception) { error = e.message ?: "Error"; render() }
        }
    }
}

/** Avatar con iniciales y, opcionalmente, un anillo de progreso alrededor (o el degradado del logo para un equipo). */
class AvatarRingView(context: Context) : View(context) {
    private var initials = "?"
    private var progress: Float? = null
    private var ringColor = Color.WHITE
    private var team = false
    private val d = resources.displayMetrics.density
    private val track = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; color = Color.parseColor("#3A4247") }
    private val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeCap = Paint.Cap.ROUND }
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.parseColor("#4A545A") }
    private val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE; textAlign = Paint.Align.CENTER
        typeface = ResourcesCompat.getFont(context, R.font.barlow_condensed_bold) ?: Typeface.DEFAULT_BOLD
    }

    fun setData(name: String, progress0to1: Float?, color: Int, team: Boolean = false) {
        initials = if (team) name.take(1).uppercase() else name.split(" ").filter { it.isNotEmpty() }.take(2).joinToString("") { it.take(1).uppercase() }.ifEmpty { "?" }
        progress = progress0to1; ringColor = color; this.team = team
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        val s = minOf(width, height).toFloat()
        val cx = width / 2f; val cy = height / 2f
        val stroke = 3f * d
        if (team) {
            fill.shader = android.graphics.LinearGradient(0f, s, s, 0f, Color.parseColor("#02A9F7"), Color.parseColor("#16EC06"), android.graphics.Shader.TileMode.CLAMP)
            canvas.drawCircle(cx, cy, s / 2, fill)
            text.textSize = s * 0.48f
        } else {
            fill.shader = null
            val p = progress
            if (p != null) {
                track.strokeWidth = stroke; ring.strokeWidth = stroke; ring.color = ringColor
                val r = s / 2 - stroke / 2
                canvas.drawCircle(cx, cy, r, track)
                if (p > 0f) canvas.drawArc(RectF(cx - r, cy - r, cx + r, cy + r), -90f, 360f * p.coerceIn(0f, 1f), false, ring)
            }
            canvas.drawCircle(cx, cy, s / 2 - (if (p != null) 5f * d else 0f), fill)
            text.textSize = s * 0.32f
        }
        canvas.drawText(initials, cx, cy - (text.ascent() + text.descent()) / 2, text)
    }
}

/** Un equipo: Información, Chat, Esfuerzo, Recuperación y Sueño (como el de WHOOP). */
class TeamActivity : AppCompatActivity() {

    companion object { const val EXTRA_TEAM = "team" }

    private enum class Tab(val label: String) { INFO("Información"), CHAT("Chat"), STRAIN("Esfuerzo"), RECOVERY("Recuperación"), SLEEP("Sueño") }
    private enum class Range(val label: String) { DAY("Diario"), WEEK("Lun - Dom"), MONTH("Mensual") }

    private lateinit var team: CTeam
    private var me = ""
    private var tab = Tab.INFO
    private var range = Range.DAY
    private var members: List<CMember> = emptyList()
    private var profiles: Map<String, CProfile> = emptyMap()
    private var stats: List<CDayStat> = emptyList()
    private val messages = mutableListOf<CMessage>()
    private var lastId: Long? = null
    private var error = ""
    private var loaded = false

    private lateinit var content: LinearLayout
    private lateinit var scroll: ScrollView
    private lateinit var tabStrip: LinearLayout
    private lateinit var chatBar: LinearLayout
    private val handler = android.os.Handler(android.os.Looper.getMainLooper())
    private var ticks = 0
    private val zone = ZoneId.systemDefault()

    private fun dp(v: Float) = Ui.dp(this, v)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        @Suppress("DEPRECATION")
        team = intent.getSerializableExtra(EXTRA_TEAM) as? CTeam ?: run { finish(); return }
        window.statusBarColor = Ui.color(this, R.color.w_bg_top)
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundResource(R.drawable.bg_screen_whoop)
        }
        // Cabecera: atrás · NOMBRE · menú
        root.addView(FrameLayout(this).apply {
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(56f))
            addView(W.title(this@TeamActivity, team.name, 15f).apply {
                layoutParams = FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER)
            })
            addView(W.icon(this@TeamActivity, R.drawable.ic_chevron_left, 26f).apply {
                layoutParams = FrameLayout.LayoutParams(dp(44f), dp(44f), Gravity.START or Gravity.CENTER_VERTICAL).apply { marginStart = dp(8f) }
                setPadding(dp(9f), dp(9f), dp(9f), dp(9f))
                setOnClickListener { finish() }
            })
            addView(W.title(this@TeamActivity, "···", 22f).apply {
                gravity = Gravity.CENTER
                layoutParams = FrameLayout.LayoutParams(dp(48f), dp(44f), Gravity.END or Gravity.CENTER_VERTICAL).apply { marginEnd = dp(8f) }
                setOnClickListener { showMenu() }
            })
        })
        tabStrip = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; setPadding(dp(16f), 0, dp(16f), dp(6f)) }
        root.addView(HorizontalScrollView(this).apply { isHorizontalScrollBarEnabled = false; addView(tabStrip) })
        scroll = ScrollView(this).apply {
            isFillViewport = true
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f)
        }
        content = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(16f), 0, dp(16f), dp(30f)) }
        scroll.addView(content)
        root.addView(scroll)
        chatBar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setBackgroundColor(Ui.color(this@TeamActivity, R.color.w_bg_bottom))
            setPadding(dp(16f), dp(8f), dp(8f), dp(12f))
            visibility = View.GONE
        }
        val input = EditText(this).apply {
            hint = "Decir algo"
            setTextColor(Ui.color(this@TeamActivity, R.color.text_primary))
            setHintTextColor(Ui.color(this@TeamActivity, R.color.text_secondary))
            background = W.rounded(this@TeamActivity, R.color.w_row, 10f)
            setPadding(dp(14f), dp(11f), dp(14f), dp(11f))
            maxLines = 4
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES or InputType.TYPE_TEXT_FLAG_MULTI_LINE
            layoutParams = W.weight()
        }
        chatBar.addView(input)
        chatBar.addView(W.icon(this, R.drawable.ic_chevron_right, 44f, R.color.recovery_green).apply {
            setPadding(dp(10f), dp(10f), dp(10f), dp(10f))
            setOnClickListener {
                val t = input.text.toString().trim()
                if (t.isEmpty()) return@setOnClickListener
                input.setText("")
                lifecycleScope.launch {
                    try { CommunityApi.send(this@TeamActivity, team.id, t.take(1000)); pollMessages() } catch (e: Exception) { toast(e.message) }
                }
            }
        })
        root.addView(chatBar)
        setContentView(root)
        buildTabs()
        lifecycleScope.launch {
            try { me = CommunityApi.userId(this@TeamActivity) } catch (e: Exception) { }
            loadAll()
            pollMessages()
        }
    }

    override fun onResume() { super.onResume(); handler.postDelayed(ticker, 5000) }
    override fun onPause() { super.onPause(); handler.removeCallbacks(ticker) }

    private val ticker = object : Runnable {
        override fun run() {
            ticks++
            lifecycleScope.launch {
                if (tab == Tab.CHAT) pollMessages()
                if (ticks % 12 == 0) loadAll()
            }
            handler.postDelayed(this, 5000)
        }
    }

    private fun toast(m: String?) = Toast.makeText(this, m ?: "Error", Toast.LENGTH_LONG).show()

    private fun buildTabs() {
        tabStrip.removeAllViews()
        Tab.values().forEach { t ->
            tabStrip.addView(LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER_HORIZONTAL
                layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { marginEnd = dp(18f) }
                addView(W.title(this@TeamActivity, t.label, 13f, if (t == tab) R.color.text_primary else R.color.text_secondary))
                addView(View(this@TeamActivity).apply {
                    setBackgroundColor(if (t == tab) Ui.color(this@TeamActivity, R.color.text_primary) else Color.TRANSPARENT)
                    layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(2f)).apply { topMargin = dp(6f) }
                })
                setOnClickListener {
                    tab = t
                    buildTabs()
                    render()
                    if (t == Tab.CHAT) lifecycleScope.launch { pollMessages() }
                }
            })
        }
        chatBar.visibility = if (tab == Tab.CHAT) View.VISIBLE else View.GONE
    }

    private fun fromDate(): String {
        val today = LocalDate.now(zone)
        val monday = today.minusDays((today.dayOfWeek.value - 1).toLong())
        return minOf(monday.minusDays(63), today.withDayOfMonth(1)).toString()
    }

    private suspend fun loadAll() {
        try {
            val m = CommunityApi.members(this, team.id)
            val ids = m.map { it.userId }
            profiles = CommunityApi.profiles(this, ids).associateBy { it.id }
            stats = CommunityApi.stats(this, ids, fromDate(), LocalDate.now(zone).toString())
            members = m
            error = ""
        } catch (e: Exception) { error = e.message ?: "Error" }
        loaded = true
        if (tab != Tab.CHAT) render()
    }

    private suspend fun pollMessages() {
        try {
            val new = CommunityApi.messages(this, team.id, lastId)
            if (lastId == null) messages.clear()
            messages.addAll(new)
            lastId = messages.lastOrNull()?.id ?: 0L
            if (tab == Tab.CHAT && (new.isNotEmpty() || content.childCount == 0)) render()
        } catch (e: Exception) { error = e.message ?: "Error" }
    }

    private fun name(id: String) = profiles[id]?.name ?: "Miembro"
    private fun username(id: String) = profiles[id]?.username ?: ""

    private fun showMenu() {
        AlertDialog.Builder(this).setItems(arrayOf("Compartir invitación", "Salir del equipo")) { _, which ->
            if (which == 0) share() else AlertDialog.Builder(this).setTitle("¿Salir de ${team.name}?")
                .setMessage("Dejarás de ver a sus miembros y ellos a ti. Puedes volver con el código.")
                .setPositiveButton("Salir") { _, _ ->
                    lifecycleScope.launch {
                        try { CommunityApi.leaveTeam(this@TeamActivity, team.id); finish() } catch (e: Exception) { toast(e.message) }
                    }
                }.setNegativeButton("Cancelar", null).show()
        }.show()
    }

    private fun share() {
        val text = "Únete a mi equipo «${team.name}» en PulseApp: abre PulseApp → Equipos → Unirme con código y escribe ${team.inviteCode}"
        startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply { type = "text/plain"; putExtra(Intent.EXTRA_TEXT, text) }, "Invitar"))
    }

    private fun render() {
        content.removeAllViews()
        when (tab) {
            Tab.INFO -> renderInfo()
            Tab.CHAT -> renderChat()
            Tab.STRAIN, Tab.RECOVERY, Tab.SLEEP -> renderBoard()
        }
        if (error.isNotEmpty()) content.addView(W.body(this, error, 13f, R.color.alert_amber).apply { setPadding(0, dp(16f), 0, 0) })
    }

    // ---------- Información ----------

    private fun renderInfo() {
        content.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(20f), 0, 0)
            addView(AvatarRingView(this@TeamActivity).apply { setData(team.name, null, 0, team = true); layoutParams = LinearLayout.LayoutParams(dp(64f), dp(64f)) })
            addView(W.title(this@TeamActivity, team.name, 28f).apply { setPadding(dp(16f), 0, 0, 0) })
        })
        content.addView(W.title(this, "Uso compartido de datos", 12.5f).apply { setPadding(0, dp(28f), 0, 0) })
        content.addView(W.body(this, "Esfuerzo, recuperación y sueño", 15f).apply { setPadding(0, dp(6f), 0, 0) })
        content.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, dp(26f), 0, 0)
            addView(W.title(this@TeamActivity, "${members.size} miembros", 12.5f).apply { layoutParams = W.weight() })
            addView(W.title(this@TeamActivity, "Código ${team.inviteCode}", 12.5f, R.color.text_secondary))
        })
        content.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(16f), 0, 0)
            addView(W.icon(this@TeamActivity, R.drawable.ic_people, 40f, R.color.alert_red).apply { setPadding(dp(8f), dp(8f), dp(8f), dp(8f)) })
            addView(W.title(this@TeamActivity, "Agregar miembros", 14f, R.color.alert_red).apply { setPadding(dp(12f), 0, 0, 0) })
            setOnClickListener { share() }
        })
        members.forEach { m ->
            content.addView(LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(0, dp(16f), 0, 0)
                addView(AvatarRingView(this@TeamActivity).apply { setData(name(m.userId), null, 0); layoutParams = LinearLayout.LayoutParams(dp(40f), dp(40f)) })
                addView(LinearLayout(this@TeamActivity).apply {
                    orientation = LinearLayout.VERTICAL
                    setPadding(dp(14f), 0, 0, 0)
                    layoutParams = W.weight()
                    addView(W.title(this@TeamActivity, name(m.userId) + if (m.userId == me) " (tú)" else "", 13.5f))
                    addView(W.body(this@TeamActivity, "@" + username(m.userId), 12f))
                })
                if (m.role == "admin") addView(W.title(this@TeamActivity, "Admin", 11f, R.color.text_secondary))
            })
        }
    }

    // ---------- Chat ----------

    private fun renderChat() {
        data class E(val time: Long, val userId: String?, val body: String)
        val entries = messages.map { E(serverMillis(it.createdAt), it.userId, it.body) } +
            WeeklyWinners.entries(team, stats) { username(it) }.map { E(it.time, null, it.body) }
        val today = LocalDate.now(zone)
        val tf = java.text.SimpleDateFormat("HH:mm", java.util.Locale.US)
        val df = java.text.SimpleDateFormat("d/M HH:mm", java.util.Locale.US)
        if (entries.isEmpty()) content.addView(W.body(this, "Todavía no hay mensajes. ¡Saluda a tu equipo!", 15f).apply { setPadding(0, dp(20f), 0, 0) })
        entries.sortedBy { it.time }.forEach { e ->
            val bot = e.userId == null
            val n = if (bot) "PulseApp" else name(e.userId!!)
            val day = java.time.Instant.ofEpochMilli(e.time).atZone(zone).toLocalDate()
            val time = (if (day == today) tf else df).format(java.util.Date(e.time))
            content.addView(LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                setPadding(0, dp(18f), 0, 0)
                addView(AvatarRingView(this@TeamActivity).apply { setData(if (bot) "P" else n, null, 0, team = bot); layoutParams = LinearLayout.LayoutParams(dp(36f), dp(36f)) })
                addView(LinearLayout(this@TeamActivity).apply {
                    orientation = LinearLayout.VERTICAL
                    setPadding(dp(12f), 0, 0, 0)
                    layoutParams = W.weight()
                    addView(LinearLayout(this@TeamActivity).apply {
                        orientation = LinearLayout.HORIZONTAL
                        addView(W.title(this@TeamActivity, n, 12.5f))
                        addView(W.body(this@TeamActivity, "  " + (if (bot) "@pulseapp" else "@" + username(e.userId!!)) + if (e.userId == me) " · tú" else "", 11f))
                    })
                    addView(W.body(this@TeamActivity, time, 11f))
                    addView(W.body(this@TeamActivity, e.body, 16f, R.color.text_primary).apply { setPadding(0, dp(4f), 0, 0) })
                })
            })
        }
        scroll.post { scroll.fullScroll(View.FOCUS_DOWN) }
    }

    // ---------- Clasificaciones ----------

    private fun renderBoard() {
        // Selector Diario / Lun-Dom / Mensual
        content.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            background = android.graphics.drawable.GradientDrawable().apply {
                cornerRadius = dp(22f).toFloat(); setStroke(dp(1f), Color.parseColor("#806F767B"))
            }
            setPadding(dp(3f), dp(3f), dp(3f), dp(3f))
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(16f) }
            Range.values().forEach { r ->
                addView(W.title(this@TeamActivity, r.label, 13f, if (r == range) R.color.text_primary else R.color.text_secondary).apply {
                    gravity = Gravity.CENTER
                    layoutParams = LinearLayout.LayoutParams(0, dp(38f), 1f)
                    if (r == range) background = android.graphics.drawable.GradientDrawable().apply {
                        cornerRadius = dp(19f).toFloat(); setStroke(dp(1.5f), Color.WHITE)
                    }
                    setOnClickListener { range = r; render() }
                })
            }
        })
        val today = LocalDate.now(zone)
        val from = when (range) {
            Range.DAY -> today
            Range.WEEK -> today.minusDays((today.dayOfWeek.value - 1).toLong())
            Range.MONTH -> today.withDayOfMonth(1)
        }.toString()
        val to = today.toString()
        fun value(s: CDayStat): Double? = when (tab) {
            Tab.STRAIN -> s.strain
            Tab.RECOVERY -> s.recovery?.toDouble()
            else -> s.sleepScore?.toDouble()
        }
        fun fmt(v: Double) = if (tab == Tab.STRAIN) Ui.comma(v) else "${Math.round(v)}%"
        fun colorOf(v: Double?): Int = Ui.color(this, when (tab) {
            Tab.STRAIN -> R.color.strain_blue
            Tab.RECOVERY -> v?.let { W.recoveryColor(Math.round(it).toInt()) } ?: R.color.w_recovery_high
            else -> R.color.w_ring_sleep
        })
        data class L(val userId: String, val v: Double?, val sub: List<String>)
        val inRange = stats.filter { it.date >= from && it.date <= to }
        val lines = members.map { m ->
            val rows = inRange.filter { it.userId == m.userId }
            val v = rows.mapNotNull { value(it) }.takeIf { it.isNotEmpty() }?.average()
            val sub = mutableListOf<String>()
            when (tab) {
                Tab.STRAIN -> if (range == Range.DAY) rows.firstOrNull()?.let { r ->
                    if (r.activities.isNotEmpty()) sub.add(r.activities.joinToString(", ") { "${it.type} ${Ui.comma(it.strain)}" })
                    r.kcal?.let { sub.add("${Ui.thousands(it.toLong())} Calorías") }
                } else {
                    val n = rows.sumOf { it.activities.size }
                    if (n > 0) sub.add("$n actividades")
                    rows.mapNotNull { it.kcal }.takeIf { it.isNotEmpty() }?.average()?.let { sub.add("${Ui.thousands(Math.round(it))} Calorías de media") }
                }
                Tab.RECOVERY -> {
                    val h = rows.mapNotNull { it.hrv }.takeIf { it.isNotEmpty() }?.average()
                    val r = rows.mapNotNull { it.rhr }.takeIf { it.isNotEmpty() }?.average()
                    if (h != null || r != null) sub.add("VFC: ${h?.let { Math.round(it) } ?: "--"}, FCREP: ${r?.let { Math.round(it) } ?: "--"}")
                }
                else -> rows.mapNotNull { it.sleepMinutes }.takeIf { it.isNotEmpty() }?.average()?.let {
                    sub.add("${Ui.hm(Math.round(it).toInt())} horas de sueño" + if (range == Range.DAY) "" else " de media")
                }
            }
            L(m.userId, v, sub)
        }.sortedByDescending { it.v ?: -1.0 }
        val withV = lines.mapNotNull { it.v }
        val mean = withV.takeIf { it.isNotEmpty() }?.average()
        val title = when (tab) { Tab.STRAIN -> if (range == Range.DAY) "Esfuerzo del día" else "Esfuerzo"; Tab.RECOVERY -> "Recuperación"; else -> "Calificación del sueño" }
        val latest = inRange.mapNotNull { it.updatedAt?.let { u -> serverMillis(u) } }.maxOrNull()
        content.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, dp(22f), 0, 0)
            addView(LinearLayout(this@TeamActivity).apply {
                orientation = LinearLayout.VERTICAL
                layoutParams = W.weight()
                addView(W.title(this@TeamActivity, title, 12.5f).apply { setTextColor(colorOf(mean)) })
                addView(W.body(this@TeamActivity, mean?.let { fmt(it) + " prom." } ?: "Sin datos", 12f).apply { setTextColor(colorOf(mean)) })
            })
            addView(LinearLayout(this@TeamActivity).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.END
                addView(W.title(this@TeamActivity, when (range) { Range.DAY -> "Hoy"; Range.WEEK -> "Esta semana"; Range.MONTH -> "Este mes" }, 12.5f))
                addView(W.body(this@TeamActivity, latest?.let { "Última actualización: " + java.text.SimpleDateFormat("HH:mm", java.util.Locale.US).format(java.util.Date(it)) } ?: "", 12f))
            })
        })
        lines.forEachIndexed { i, l ->
            content.addView(LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                setPadding(0, dp(20f), 0, 0)
                alpha = if (l.v == null) 0.5f else 1f
                addView(AvatarRingView(this@TeamActivity).apply {
                    val p = l.v?.let { (if (tab == Tab.STRAIN) it / 21 else it / 100).toFloat() } ?: 0f
                    setData(name(l.userId), p, colorOf(l.v)); layoutParams = LinearLayout.LayoutParams(dp(52f), dp(52f))
                })
                addView(LinearLayout(this@TeamActivity).apply {
                    orientation = LinearLayout.VERTICAL
                    setPadding(dp(14f), 0, 0, 0)
                    layoutParams = W.weight()
                    addView(TextView(this@TeamActivity).apply {
                        val head = "${i + 1}. ${name(l.userId)}  "
                        val v = l.v?.let { fmt(it) } ?: "--"
                        val sb = android.text.SpannableStringBuilder(head + v)
                        sb.setSpan(android.text.style.ForegroundColorSpan(colorOf(l.v)), head.length, sb.length, android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                        text = sb
                        textSize = 16f
                        setTypeface(typeface, Typeface.BOLD)
                        setTextColor(Ui.color(this@TeamActivity, R.color.text_primary))
                    })
                    l.sub.forEach { addView(W.body(this@TeamActivity, it, 14.5f)) }
                })
            })
        }
        if (!loaded) content.addView(ProgressBar(this).apply { setPadding(0, dp(40f), 0, 0) })
    }
}
