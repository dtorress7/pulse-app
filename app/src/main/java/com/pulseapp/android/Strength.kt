package com.pulseapp.android

import java.io.File
import java.text.Normalizer
import kotlin.math.max
import kotlin.math.min

/**
 * Entrenador de fuerza (5/11, como el "Strength Trainer" de WHOOP): ejercicios con series (repeticiones, peso y, si se
 * cronometran con "Comenzar / Finalizar serie", su inicio y fin para sacar el pulso de cada serie).
 *
 * Se guarda en archivos de texto (separados por tabuladores) en la carpeta de la app, NO en Room (no hace falta migración):
 *  - strength_logs.tsv       series registradas de cada actividad (enlazadas por id y por hora)
 *  - strength_templates.tsv  tus entrenamientos guardados ("Mis entrenamientos")
 *  - strength_custom.tsv     ejercicios personalizados
 *  - strength_live.tsv       el entrenamiento en curso (sobrevive a cerrar la app)
 * Formato de cada bloque (líneas):
 *   L <tab> sessionId <tab> inicio ms <tab> fin ms <tab> nombre      (T en plantillas, con id en vez de sessionId)
 *   E <tab> exId <tab> superserie (0 = no) <tab> nombre
 *   S <tab> reps <tab> kg <tab> inicio ms (o vacío) <tab> fin ms (o vacío) <tab> hecha (1/0)
 */
object Strength {

    // ---------- Modelo ----------
    class SetEntry(var reps: Int, var kg: Double, var startMs: Long? = null, var endMs: Long? = null, var done: Boolean = false) {
        fun copy() = SetEntry(reps, kg, startMs, endMs, done)
        val volume get() = reps * kg
    }

    class ExerciseEntry(val exId: String, var name: String, var superset: Int = 0, val sets: MutableList<SetEntry> = ArrayList()) {
        fun copy() = ExerciseEntry(exId, name, superset, sets.map { it.copy() }.toMutableList())
        val reps get() = sets.sumOf { it.reps }
        val volume get() = sets.sumOf { it.volume }
    }

    class Workout(
        var id: Long,              // sessionId en registros; id propio en plantillas
        var startMs: Long,
        var endMs: Long,
        var name: String = "",
        val exercises: MutableList<ExerciseEntry> = ArrayList()
    ) {
        fun copy() = Workout(id, startMs, endMs, name, exercises.map { it.copy() }.toMutableList())
        val setCount get() = exercises.sumOf { it.sets.size }
        val reps get() = exercises.sumOf { it.reps }
        val volume get() = exercises.sumOf { it.volume }
    }

    class Exercise(val id: String, val name: String, val group: String, val equipment: String, val bodyweight: Double = 0.0)

    // ---------- Biblioteca de ejercicios ----------
    // Nombres genéricos en español. bodyweight = fracción del peso corporal que mueve el ejercicio (0 = solo el peso puesto).
    private val LIB: List<Exercise> = run {
        val l = ArrayList<Exercise>()
        fun e(name: String, group: String, eq: String, bw: Double = 0.0) { l.add(Exercise(slug(name), name, group, eq, bw)) }
        // Pecho
        e("Press de banca - Barra", "Pecho", "Barra"); e("Press de banca - Mancuerna", "Pecho", "Mancuernas")
        e("Press de banca - Inclinado - Barra", "Pecho", "Barra"); e("Press de banca - Inclinado - Mancuerna", "Pecho", "Mancuernas")
        e("Press de banca - Declinado - Barra", "Pecho", "Barra"); e("Press de banca - Declinado - Mancuerna", "Pecho", "Mancuernas")
        e("Press de pecho - Máquina", "Pecho", "Máquina"); e("Press de banca - Multipower", "Pecho", "Máquina")
        e("Aperturas - Mancuernas", "Pecho", "Mancuernas"); e("Aperturas - Inclinado - Mancuernas", "Pecho", "Mancuernas")
        e("Cruce de poleas", "Pecho", "Polea"); e("Contractora de pecho - Máquina", "Pecho", "Máquina")
        e("Flexiones", "Pecho", "Peso corporal", 0.64); e("Flexiones - Inclinadas", "Pecho", "Peso corporal", 0.45)
        e("Flexiones - Declinadas", "Pecho", "Peso corporal", 0.74); e("Flexiones diamante", "Tríceps", "Peso corporal", 0.64)
        e("Fondos en paralelas", "Pecho", "Peso corporal", 0.9); e("Pullover - Mancuerna", "Pecho", "Mancuernas")
        // Espalda
        e("Dominada", "Espalda", "Peso corporal", 0.95); e("Dominada supina", "Espalda", "Peso corporal", 0.95)
        e("Dominada asistida - Máquina", "Espalda", "Máquina", 0.95); e("Jalón al pecho - Polea", "Espalda", "Polea")
        e("Jalón al pecho - Agarre estrecho - Polea", "Espalda", "Polea"); e("Remo con barra", "Espalda", "Barra")
        e("Remo con mancuerna - Un brazo", "Espalda", "Mancuernas"); e("Remo sentado - Polea", "Espalda", "Polea")
        e("Remo agachado de un solo brazo - I - Cable", "Espalda", "Polea"); e("Remo agachado de un solo brazo - D - Cable", "Espalda", "Polea")
        e("Remo inclinado con un solo brazo - I - Cable", "Espalda", "Polea"); e("Remo inclinado con un solo brazo - D - Cable", "Espalda", "Polea")
        e("Remo en máquina", "Espalda", "Máquina"); e("Remo en T", "Espalda", "Barra"); e("Remo invertido", "Espalda", "Peso corporal", 0.6)
        e("Remo Pendlay", "Espalda", "Barra"); e("Pulldown con brazos rectos - Polea", "Espalda", "Polea")
        e("Peso muerto - Barra", "Espalda", "Barra"); e("Peso muerto rumano - Barra", "Piernas", "Barra")
        e("Peso muerto rumano - Mancuernas", "Piernas", "Mancuernas"); e("Peso muerto sumo", "Piernas", "Barra")
        e("Hiperextensiones", "Espalda", "Peso corporal", 0.5); e("Buenos días - Barra", "Espalda", "Barra")
        e("Encogimientos - Mancuernas", "Espalda", "Mancuernas"); e("Encogimientos - Barra", "Espalda", "Barra")
        // Hombros
        e("Press de hombros - Sentado - Mancuernas", "Hombros", "Mancuernas"); e("Press de hombros - De pie - Mancuernas", "Hombros", "Mancuernas")
        e("Press militar - Barra", "Hombros", "Barra"); e("Press de hombros - Máquina", "Hombros", "Máquina")
        e("Arnold Press - Sentado - Mancuerna", "Hombros", "Mancuernas"); e("Elevaciones laterales - Mancuernas", "Hombros", "Mancuernas")
        e("Elevaciones laterales - Polea", "Hombros", "Polea"); e("Elevaciones frontales - Mancuernas", "Hombros", "Mancuernas")
        e("Pájaros - Mancuernas", "Hombros", "Mancuernas"); e("Face pull - Polea", "Hombros", "Polea")
        e("Remo al mentón - Barra", "Hombros", "Barra"); e("Aperturas inversas - Máquina", "Hombros", "Máquina")
        e("Flexiones en pica", "Hombros", "Peso corporal", 0.5); e("Alrededor del mundo - Mancuernas", "Hombros", "Mancuernas")
        // Bíceps
        e("Curl de bíceps - Barra", "Bíceps", "Barra"); e("Curl de bíceps - Mancuernas", "Bíceps", "Mancuernas")
        e("Curl martillo - Mancuernas", "Bíceps", "Mancuernas"); e("Curl concentrado - Mancuerna", "Bíceps", "Mancuernas")
        e("Curl en banco Scott", "Bíceps", "Barra"); e("Curl de bíceps - Polea", "Bíceps", "Polea")
        e("Curl inclinado - Mancuernas", "Bíceps", "Mancuernas"); e("Curl con barra Z", "Bíceps", "Barra")
        // Tríceps
        e("Extensión de tríceps - Polea", "Tríceps", "Polea"); e("Extensión de tríceps con cuerda - Polea", "Tríceps", "Polea")
        e("Press francés - Barra", "Tríceps", "Barra"); e("Extensión de tríceps sobre la cabeza - Mancuerna", "Tríceps", "Mancuernas")
        e("Patada de tríceps - Mancuerna", "Tríceps", "Mancuernas"); e("Press de banca agarre estrecho", "Tríceps", "Barra")
        e("Fondos de tríceps en el suelo", "Tríceps", "Peso corporal", 0.5); e("Fondos de tríceps en banco", "Tríceps", "Peso corporal", 0.6)
        // Piernas
        e("Sentadilla - Barra", "Piernas", "Barra"); e("Sentadilla frontal - Barra", "Piernas", "Barra")
        e("Sentadilla goblet - Mancuerna", "Piernas", "Mancuernas"); e("Sentadilla - Peso corporal", "Piernas", "Peso corporal", 0.7)
        e("Sentadilla búlgara - Mancuernas", "Piernas", "Mancuernas", 0.4); e("Sentadilla hack - Máquina", "Piernas", "Máquina")
        e("Sentadilla - Multipower", "Piernas", "Máquina"); e("Prensa de piernas", "Piernas", "Máquina")
        e("Zancadas - Mancuernas", "Piernas", "Mancuernas", 0.4); e("Zancadas - Barra", "Piernas", "Barra", 0.4)
        e("Zancadas caminando", "Piernas", "Peso corporal", 0.6); e("Subida al banco - Mancuernas", "Piernas", "Mancuernas", 0.5)
        e("Extensión de cuádriceps - Máquina", "Piernas", "Máquina"); e("Curl femoral tumbado - Máquina", "Piernas", "Máquina")
        e("Curl femoral sentado - Máquina", "Piernas", "Máquina"); e("Curl nórdico", "Piernas", "Peso corporal", 0.5)
        e("Elevación de gemelos de pie", "Piernas", "Máquina"); e("Elevación de gemelos sentado", "Piernas", "Máquina")
        e("Abductores - Máquina", "Piernas", "Máquina"); e("Aductores - Máquina", "Piernas", "Máquina")
        e("Sentadilla con salto", "Piernas", "Peso corporal", 0.8); e("Pistol squat", "Piernas", "Peso corporal", 0.8)
        // Glúteos
        e("Hip thrust - Barra", "Glúteos", "Barra"); e("Hip thrust - Máquina", "Glúteos", "Máquina")
        e("Puente de glúteo", "Glúteos", "Peso corporal", 0.4); e("Patada de glúteo - Polea", "Glúteos", "Polea")
        e("Peso muerto a una pierna - Mancuerna", "Glúteos", "Mancuernas", 0.3)
        // Core
        e("Abdominales", "Core", "Peso corporal", 0.3); e("Abdominales en bicicleta", "Core", "Peso corporal", 0.3)
        e("Abdominales en la máquina GHD", "Core", "Máquina", 0.5); e("Crunch - Polea", "Core", "Polea")
        e("Plancha", "Core", "Peso corporal", 0.5); e("Plancha lateral", "Core", "Peso corporal", 0.4)
        e("Copenhague", "Core", "Peso corporal", 0.3); e("Elevación de piernas colgado", "Core", "Peso corporal", 0.35)
        e("Elevación de piernas tumbado", "Core", "Peso corporal", 0.25); e("Rueda abdominal", "Core", "Otro", 0.4)
        e("Russian twist", "Core", "Peso corporal", 0.25); e("Pallof press - Polea", "Core", "Polea")
        e("Leñador - Polea", "Core", "Polea"); e("Dead bug", "Core", "Peso corporal", 0.2)
        e("Mountain climbers", "Core", "Peso corporal", 0.3); e("Hollow hold", "Core", "Peso corporal", 0.3)
        // Pesa rusa y cuerpo completo
        e("Swing - Pesa rusa", "Cuerpo completo", "Pesa rusa"); e("Arrancada con un solo brazo - I - Pesa rusa", "Cuerpo completo", "Pesa rusa")
        e("Arrancada con un solo brazo - D - Pesa rusa", "Cuerpo completo", "Pesa rusa"); e("Clean - Pesa rusa", "Cuerpo completo", "Pesa rusa")
        e("Turkish get-up - Pesa rusa", "Cuerpo completo", "Pesa rusa", 0.2); e("Thruster - Barra", "Cuerpo completo", "Barra", 0.2)
        e("Thruster - Mancuernas", "Cuerpo completo", "Mancuernas", 0.2); e("Cargada de potencia - Barra", "Cuerpo completo", "Barra")
        e("Arrancada - Barra", "Cuerpo completo", "Barra"); e("Dos tiempos - Barra", "Cuerpo completo", "Barra")
        e("Burpees", "Cuerpo completo", "Peso corporal", 0.6); e("Paseo del granjero - Mancuernas", "Cuerpo completo", "Mancuernas")
        e("Wall ball", "Cuerpo completo", "Otro", 0.5); e("Box jump", "Piernas", "Peso corporal", 0.7)
        e("Battle ropes", "Cuerpo completo", "Otro"); e("Saltos a la comba", "Cardio", "Otro", 0.1)
        e("Remo - Ergómetro", "Cardio", "Máquina"); e("Bicicleta de asalto", "Cardio", "Máquina")
        l.sortedBy { norm(it.name) }
    }

    fun library(): List<Exercise> = (LIB + customExercises()).sortedBy { norm(it.name) }

    fun exercise(id: String): Exercise? = LIB.firstOrNull { it.id == id } ?: customExercises().firstOrNull { it.id == id }

    val GROUPS = listOf("Pecho", "Espalda", "Hombros", "Bíceps", "Tríceps", "Piernas", "Glúteos", "Core", "Cuerpo completo", "Cardio")
    val EQUIPMENT = listOf("Barra", "Mancuernas", "Polea", "Máquina", "Peso corporal", "Pesa rusa", "Otro")

    fun norm(s: String): String =
        Normalizer.normalize(s.lowercase(), Normalizer.Form.NFD).replace(Regex("\\p{M}+"), "")

    fun slug(s: String): String = norm(s).replace(Regex("[^a-z0-9]+"), "_").trim('_')

    // ---------- Archivos ----------
    @Volatile var dir: File? = null
    private const val LOGS = "strength_logs.tsv"
    private const val TEMPLATES = "strength_templates.tsv"
    private const val CUSTOM = "strength_custom.tsv"
    private const val LIVE = "strength_live.tsv"

    @Volatile private var logCache: List<Workout>? = null
    @Volatile private var customCache: List<Exercise>? = null

    private fun file(name: String): File? = dir?.let { File(it, name) }

    private fun clean(s: String) = s.replace('\t', ' ').replace('\n', ' ').replace('\r', ' ')

    fun encode(list: List<Workout>, tag: String): String {
        val sb = StringBuilder("#pulseapp_strength v1\n")
        for (w in list) {
            sb.append(tag).append('\t').append(w.id).append('\t').append(w.startMs).append('\t').append(w.endMs).append('\t').append(clean(w.name)).append('\n')
            for (e in w.exercises) {
                sb.append("E\t").append(e.exId).append('\t').append(e.superset).append('\t').append(clean(e.name)).append('\n')
                for (s in e.sets) {
                    sb.append("S\t").append(s.reps).append('\t').append(String.format(java.util.Locale.US, "%.2f", s.kg)).append('\t')
                        .append(s.startMs?.toString() ?: "").append('\t').append(s.endMs?.toString() ?: "").append('\t')
                        .append(if (s.done) "1" else "0").append('\n')
                }
            }
        }
        return sb.toString()
    }

    fun decode(text: String, tag: String): List<Workout> {
        val out = ArrayList<Workout>()
        var w: Workout? = null
        var e: ExerciseEntry? = null
        for (line in text.lineSequence()) {
            if (line.isBlank() || line.startsWith("#")) continue
            val p = line.split('\t')
            when (p[0]) {
                tag -> {
                    w = Workout(p.getOrNull(1)?.toLongOrNull() ?: 0L, p.getOrNull(2)?.toLongOrNull() ?: 0L, p.getOrNull(3)?.toLongOrNull() ?: 0L,
                        p.getOrNull(4) ?: "")
                    out.add(w); e = null
                }
                "E" -> {
                    val ww = w ?: continue
                    e = ExerciseEntry(p.getOrNull(1) ?: "", p.getOrNull(3) ?: "", p.getOrNull(2)?.toIntOrNull() ?: 0)
                    ww.exercises.add(e)
                }
                "S" -> {
                    val ee = e ?: continue
                    ee.sets.add(SetEntry(p.getOrNull(1)?.toIntOrNull() ?: 0, p.getOrNull(2)?.toDoubleOrNull() ?: 0.0,
                        p.getOrNull(3)?.toLongOrNull(), p.getOrNull(4)?.toLongOrNull(), p.getOrNull(5) == "1"))
                }
            }
        }
        return out
    }

    private fun read(name: String, tag: String): List<Workout> {
        val f = file(name) ?: return emptyList()
        if (!f.exists()) return emptyList()
        return runCatching { decode(f.readText(), tag) }.getOrDefault(emptyList())
    }

    @Synchronized private fun write(name: String, text: String) {
        val f = file(name) ?: return
        val tmp = File(f.parentFile, "$name.tmp")
        tmp.writeText(text)
        if (!tmp.renameTo(f)) { f.writeText(text); tmp.delete() }
    }

    // Registros (series de cada actividad)
    fun logs(): List<Workout> = logCache ?: read(LOGS, "L").sortedBy { it.startMs }.also { logCache = it }

    fun logFor(sessionId: Long): Workout? = logs().firstOrNull { it.id == sessionId }

    /** El registro que más se solapa con [start, end] (al menos la mitad del más corto). */
    fun logOverlapping(start: Long, end: Long): Workout? {
        var best: Workout? = null; var bestOv = 0L
        for (w in logs()) {
            val ov = min(end, w.endMs) - max(start, w.startMs)
            val shorter = min(end - start, w.endMs - w.startMs)
            if (ov > 0 && ov * 2 >= shorter && ov > bestOv) { best = w; bestOv = ov }
        }
        return best
    }

    @Synchronized fun saveLog(w: Workout) {
        val list = logs().filter { it.id != w.id }.toMutableList()
        if (w.exercises.isNotEmpty()) list.add(w)
        list.sortBy { it.startMs }
        write(LOGS, encode(list, "L")); logCache = list
    }

    @Synchronized fun deleteLog(sessionId: Long) {
        val list = logs().filter { it.id != sessionId }
        write(LOGS, encode(list, "L")); logCache = list
    }

    // Plantillas ("Mis entrenamientos")
    fun templates(): List<Workout> = read(TEMPLATES, "T").sortedByDescending { it.startMs }

    @Synchronized fun saveTemplate(t: Workout) {
        val list = templates().filter { it.id != t.id }.toMutableList()
        list.add(t)
        write(TEMPLATES, encode(list, "T"))
    }

    @Synchronized fun deleteTemplate(id: Long) { write(TEMPLATES, encode(templates().filter { it.id != id }, "T")) }

    // Ejercicios personalizados (línea C)
    fun customExercises(): List<Exercise> = customCache ?: run {
        val f = file(CUSTOM)
        val l = if (f == null || !f.exists()) emptyList() else f.readLines().mapNotNull { line ->
            val p = line.split('\t')
            if (p.size < 6 || p[0] != "C") null else Exercise(p[1], p[5], p[2], p[3], p[4].toDoubleOrNull() ?: 0.0)
        }
        customCache = l; l
    }

    @Synchronized fun addCustomExercise(name: String, group: String, equipment: String, bodyweight: Double): Exercise {
        val ex = Exercise("custom_" + slug(name) + "_" + (System.currentTimeMillis() % 100000), clean(name), group, equipment, bodyweight)
        val all = customExercises() + ex
        write(CUSTOM, "#pulseapp_strength_custom v1\n" + all.joinToString("") {
            "C\t${it.id}\t${it.group}\t${it.equipment}\t${it.bodyweight}\t${clean(it.name)}\n"
        })
        customCache = all
        return ex
    }

    // Entrenamiento en curso
    fun live(): Workout? = read(LIVE, "L").firstOrNull()
    @Synchronized fun saveLive(w: Workout?) {
        if (w == null) { file(LIVE)?.delete(); return }
        write(LIVE, encode(listOf(w), "L"))
    }

    // ---------- Carga muscular y esfuerzo ----------
    // 5/11: el entrenador de fuerza de WHOOP separa CARDIO (pulso) y MUSCULAR (series). Entrenamiento del 4/11 18:17–19:08
    // (8 ejercicios, 24 series, 3900 kg, 199 reps): WHOOP 8,1. Con nuestro pulso la parte cardio da una carga de 161 (4,6 solo)
    // → faltan 289 de carga muscular. Volumen efectivo = Σ reps·(kg + fracción·peso corporal) = 6844 con 68 kg → 0,04225 por kg.
    // OJO: calibrado con UNA sola sesión; antes (4,2 por minuto) daba 7,4. Revisar con cada entreno registrado.
    const val LOAD_PER_KG = 0.04225

    fun effectiveVolume(w: Workout, bodyKg: Double): Double = w.exercises.sumOf { e ->
        val bw = exercise(e.exId)?.bodyweight ?: 0.0
        e.sets.sumOf { s -> s.reps * (s.kg + bw * bodyKg) }
    }

    fun muscleLoad(w: Workout, bodyKg: Double): Double = LOAD_PER_KG * effectiveVolume(w, bodyKg)

    /** Carga cardio (pulso) y muscular de una actividad, para la barra CARDIO / MUSCULAR. */
    fun cardioMuscleSplit(cardioLoad: Double, muscleLoad: Double): Pair<Int, Int> {
        val tot = cardioLoad + muscleLoad
        if (tot <= 0) return 100 to 0
        val c = Math.round(cardioLoad * 100 / tot).toInt()
        return c to 100 - c
    }

    // ---------- Récords (medallas) ----------
    /** 1RM estimado (Epley); en ejercicios sin peso, las repeticiones. */
    fun setScore(s: SetEntry): Double = if (s.kg > 0) s.kg * (1 + s.reps / 30.0) else s.reps.toDouble()

    /** Para cada serie de [w]: true si supera tu mejor marca anterior en ese ejercicio (solo si ya lo habías hecho antes). */
    fun records(w: Workout): List<List<Boolean>> {
        val earlier = logs().filter { it.startMs < w.startMs && it.id != w.id }
        return w.exercises.map { e ->
            val prev = earlier.flatMap { o -> o.exercises.filter { it.exId == e.exId }.flatMap { it.sets } }
            if (prev.isEmpty()) return@map e.sets.map { false }
            var best = prev.maxOf { setScore(it) }
            e.sets.map { s -> val sc = setScore(s); if (sc > best + 1e-9) { best = sc; true } else false }
        }
    }

    /** Hitos: número de entrenamientos registrados → (hechos, siguiente hito). */
    val MILESTONES = intArrayOf(1, 3, 5, 10, 25, 50, 100, 250, 500)
    fun milestone(count: Int): Pair<Int, Int> = count to (MILESTONES.firstOrNull { it > count } ?: (count + 100))

    /** Última vez que hiciste [exId] (para rellenar series y pesos como WHOOP). */
    fun lastSetsOf(exId: String, before: Long = Long.MAX_VALUE): List<SetEntry>? =
        logs().filter { it.startMs < before }.sortedByDescending { it.startMs }
            .firstNotNullOfOrNull { w -> w.exercises.firstOrNull { it.exId == exId }?.sets?.map { SetEntry(it.reps, it.kg) } }

    // ---------- Generar un entrenamiento a partir de un texto ----------
    /**
     * Convierte un texto como "Press banca 4x8 40 kg, dominadas 4x8, remo con polea 3 series de 10 con 35kg" en ejercicios
     * de la biblioteca (el nombre más parecido) con sus series. Una línea que empieza por "+" va en superserie con la anterior.
     * Sin conexión no hay IA de verdad: esto entiende las formas habituales de escribir una rutina.
     */
    fun parse(text: String): Workout {
        val w = Workout(System.currentTimeMillis(), 0, 0, "")
        var group = 0
        val parts = text.split('\n', ';').flatMap { line ->
            // "press 4x8, dominadas 3x10" → partir por comas solo si hay varios ejercicios con números
            val pieces = line.split(',')
            if (pieces.size > 1 && pieces.count { Regex("\\d").containsMatchIn(it) && Regex("[a-zA-ZáéíóúñÁÉÍÓÚÑ]{3,}").containsMatchIn(it) } >= 2) pieces else listOf(line)
        }
        for (raw in parts) {
            var line = raw.trim().trimStart('-', '•', '*', '·').trim()
            if (line.isEmpty()) continue
            val joins = line.startsWith("+")
            if (joins) line = line.trimStart('+').trim()
            val n = norm(line).replace(',', '.')
            var sets = 3; var reps = 10; var kg = 0.0
            Regex("(\\d+)\\s*[x×*]\\s*(\\d+)").find(n)?.let { sets = it.groupValues[1].toInt(); reps = it.groupValues[2].toInt() }
                ?: Regex("(\\d+)\\s*series?\\s*(?:de\\s*)?(\\d+)").find(n)?.let { sets = it.groupValues[1].toInt(); reps = it.groupValues[2].toInt() }
                ?: run {
                    Regex("(\\d+)\\s*series?").find(n)?.let { sets = it.groupValues[1].toInt() }
                    Regex("(\\d+)\\s*(?:rep|repeticion)").find(n)?.let { reps = it.groupValues[1].toInt() }
                }
            Regex("(\\d+(?:\\.\\d+)?)\\s*(kg|kilos?)").find(n)?.let { kg = it.groupValues[1].toDouble() }
            val nameText = n.replace(Regex("\\d+(?:\\.\\d+)?\\s*(kg|kilos?)"), " ").replace(Regex("\\d+\\s*[x×*]\\s*\\d+"), " ")
                .replace(Regex("\\d+\\s*series?\\s*(de\\s*)?\\d*"), " ").replace(Regex("\\d+\\s*(reps?|repeticiones?)"), " ")
                .replace(Regex("\\b(con|de|del|la|el|en|a|al|y|los|las)\\b"), " ").replace(Regex("[^a-z ]"), " ").trim()
            if (nameText.isBlank()) continue
            val ex = bestMatch(nameText)
            val entry = ExerciseEntry(ex?.id ?: ("custom_" + slug(nameText)), ex?.name ?: nameText.replaceFirstChar { it.uppercase() })
            if (joins && w.exercises.isNotEmpty()) {
                val prev = w.exercises.last()
                if (prev.superset == 0) { group++; prev.superset = group }
                entry.superset = prev.superset
            }
            repeat(sets.coerceIn(1, 12)) { entry.sets.add(SetEntry(reps.coerceIn(1, 100), kg.coerceIn(0.0, 500.0))) }
            w.exercises.add(entry)
        }
        return w
    }

    private val STOP = setOf("de", "la", "el", "en", "con", "un", "una", "solo", "a", "y", "al", "del", "los", "las")

    private fun stem(t: String) = t.removeSuffix("es").removeSuffix("s")

    /** Ejercicio de la biblioteca más parecido a [q] (palabras en común), o null si no se parece a ninguno. */
    fun bestMatch(q: String): Exercise? {
        val qt = norm(q).split(Regex("[^a-z0-9]+")).filter { it.isNotEmpty() && it !in STOP }.map { stem(it) }.toSet()
        if (qt.isEmpty()) return null
        var best: Exercise? = null; var bestScore = 0.0
        for (ex in library()) {
            val et = norm(ex.name).split(Regex("[^a-z0-9]+")).filter { it.isNotEmpty() && it !in STOP }.map { stem(it) }.toSet()
            if (et.isEmpty()) continue
            val common = qt.count { a -> et.any { b -> a == b || (a.length >= 4 && b.startsWith(a)) || (b.length >= 4 && a.startsWith(b)) } }
            if (common == 0) continue
            // Cubre lo que has escrito y, a igualdad, el nombre más corto (el más general)
            val score = common.toDouble() / qt.size + 0.3 * common / et.size
            if (score > bestScore + 1e-9) { bestScore = score; best = ex }
        }
        return if (bestScore >= 0.5) best else null
    }

    // ---------- Entrenamientos de ejemplo (pestaña ENTRENAMIENTOS) ----------
    fun presets(): List<Workout> {
        fun w(name: String, vararg ex: Triple<String, Int, Int>): Workout {
            val wk = Workout(-1, 0, 0, name)
            for ((exName, sets, reps) in ex) {
                val e = LIB.firstOrNull { it.name == exName } ?: continue
                wk.exercises.add(ExerciseEntry(e.id, e.name, 0, MutableList(sets) { SetEntry(reps, 0.0) }))
            }
            return wk
        }
        return listOf(
            w("Torso: empuje", Triple("Press de banca - Mancuerna", 4, 8), Triple("Press de banca - Inclinado - Mancuerna", 3, 10),
                Triple("Press de hombros - Sentado - Mancuernas", 3, 10), Triple("Elevaciones laterales - Mancuernas", 3, 12),
                Triple("Extensión de tríceps - Polea", 3, 12)),
            w("Torso: tirón", Triple("Dominada", 4, 8), Triple("Remo con barra", 4, 8), Triple("Jalón al pecho - Polea", 3, 10),
                Triple("Face pull - Polea", 3, 15), Triple("Curl de bíceps - Mancuernas", 3, 12)),
            w("Pierna", Triple("Sentadilla - Barra", 4, 8), Triple("Peso muerto rumano - Barra", 3, 10), Triple("Prensa de piernas", 3, 12),
                Triple("Curl femoral tumbado - Máquina", 3, 12), Triple("Elevación de gemelos de pie", 4, 15)),
            w("Cuerpo completo", Triple("Sentadilla goblet - Mancuerna", 3, 10), Triple("Press de banca - Mancuerna", 3, 10),
                Triple("Remo con mancuerna - Un brazo", 3, 10), Triple("Hip thrust - Barra", 3, 10), Triple("Plancha", 3, 1)),
            w("Peso corporal", Triple("Flexiones", 4, 12), Triple("Dominada", 4, 6), Triple("Sentadilla - Peso corporal", 4, 20),
                Triple("Zancadas caminando", 3, 12), Triple("Abdominales en bicicleta", 3, 20)),
            w("Core", Triple("Plancha", 3, 1), Triple("Elevación de piernas colgado", 3, 10), Triple("Russian twist", 3, 20),
                Triple("Dead bug", 3, 12), Triple("Copenhague", 3, 8))
        )
    }
}
