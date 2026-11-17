import Foundation

/* 17/11: catálogo de comportamientos del diario como el de WHOOP (copiado de la pantalla "Seleccionar comportamientos" del vídeo
   del usuario: nombre, pregunta y categoría). El orden es el de "Todo" en WHOOP. La categoría de los que no salieron filtrados en
   el vídeo se ha puesto a mano. Formato: nombre|pregunta|categoría. */
enum JournalCatalog {
    struct Item: Hashable {
        let name: String
        let q: String
        let cat: String
    }

    static let customCat = "custom"

    /// Pestañas (como WHOOP), en orden. La clave vacía = "Todo".
    static let categories: [(key: String, title: String)] = [
        ("", "Todo"), (customCat, "Comportamientos personalizados"), ("M", "Bienestar mental"), ("E", "Estilo de vida"),
        ("T", "Medicamentos y tratamiento"), ("N", "Nutrición"), ("R", "Recuperación"), ("H", "Salud hormonal"),
        ("S", "Salud y síntomas"), ("C", "Sueño y salud circadiana"), ("P", "Suplementos")
    ]

    private static let raw = """
    Alcohol|¿Tomas bebidas alcohólicas?|N
    Medicamento para la alergia|¿Tomaste medicamento para la alergia?|T
    Comiste antes de entrenar|¿Comiste antes de entrenar?|N
    Desayuno|¿Desayunaste?|N
    Creatina|¿Tomaste creatina?|P
    Lácteos|¿Consumiste lácteos?|N
    Cena|¿Cenaste?|N
    Snack de la tarde|¿Comiste un snack por la tarde?|N
    Antojos de comida|¿Has experimentado antojos de comida?|N
    Frutas y verduras|¿Consumiste frutas o verduras?|N
    Adelgazamiento/pérdida del cabello|¿Has notado adelgazamiento o pérdida del cabello?|S
    Cocinado en casa|¿Comiste comida casera?|N
    Hidratación|¿Te hidrataste lo suficiente?|N
    Lesión|¿Tienes una lesión o herida?|S
    Comida tardía|¿Comiste algo cerca de la hora de dormir?|N
    Almuerzo|¿Almorzaste?|N
    Suplemento de magnesio|¿Tomaste un suplemento de magnesio?|P
    Masturbación|¿Te masturbaste?|E
    Suplemento de Omega 3|¿Tomaste un suplemento de omega 3?|P
    Proteína|¿Consumiste proteína?|N
    ¿Lees en la cama?|¿Lees (sin pantalla) mientras estás en la cama?|C
    Restaurante|¿Comiste en un restaurante?|N
    Actividad sexual|¿Tuviste relaciones sexuales?|E
    Cama compartida|¿Compartiste tu cama?|C
    Dormir en cama propia|¿Dormiste en la misma cama de siempre?|C
    Vacaciones|¿Tomaste un día de vacaciones?|E
    Videojuegos|¿Jugaste videojuegos?|E
    Llamadas de trabajo|¿Pasaste tiempo en videollamadas de trabajo?|E
    Desplazamiento al trabajo|¿Fuiste al trabajo?|E
    Accutane|¿Tomaste Accutane?|T
    Acné|¿Has experimentado acné?|S
    La acupuntura|¿Recibiste terapia de acupuntura?|R
    Hongos adaptógenos|¿Tomaste hongos adaptógenos?|P
    Azúcar añadido|¿Consumiste azúcar añadida?|N
    Medicamentos para el TDAH|¿Tomaste medicamentos para el AD(H)D?|T
    Snack por la tarde|¿Comiste un snack por la tarde?|N
    AG1 - Suplemento nutricional fundamental|¿Bebiste AG1?|P
    Viaje en avión|¿Viajaste en avión?|E
    Suplemento de ácido alfa-lipoico (ALA)|¿Tomaste suplementos de ácido alfa-lipoico (ALA)?|P
    Antiandrógeno|¿Has tomado medicamento antiandrógeno (por ejemplo, espironolactona)?|T
    Medicamentos contra la ansiedad|¿Tomaste ansiolíticos?|T
    Medicamentos antiinflamatorios (p. ej., Ibuprofeno)|¿Tomas medicamentos antiinflamatorios?|T
    Ansiedad|¿Sentiste nerviosismo o ansiedad?|M
    Aromaterapia|¿Usaste aceites esenciales o aromaterapia para relajarte?|R
    Luz artificial|¿Viste luz artificial al despertar?|C
    Ashwaganda|¿Tomaste ashwaganda?|P
    Dolor de espalda|¿Tienes dolor de espalda?|S
    Frijoles|¿Comiste frijoles?|N
    Betabloqueadores|¿Tomaste medicamento betabloqueador?|T
    Hinchazón|¿Experimentaste hinchazón?|S
    Donación de sangre|¿Donaste sangre?|E
    Medicamentos para la presión arterial|¿Tomaste medicamentos para la presión arterial?|T
    Gafas con filtro de luz azul|¿Usaste gafas con filtro de luz azul antes de acostarte?|C
    Gafas con filtro de luz azul (lentes WHOOP para todo el día)|¿Usaste gafas con filtro de luz azul (lentes WHOOP para todo el día)?|C
    Gafas con filtro de luz azul (lentes WHOOP nocturnos)|¿Usaste gafas con filtro de luz azul (lentes WHOOP nocturnos)?|C
    Cambios en el olor corporal|¿Has notado cambios en tu olor corporal hoy?|S
    Almohada corporal|¿Has usado una almohada corporal?|C
    Movimientos intestinales|¿Tuviste movimientos intestinales?|S
    Niebla mental|¿Has experimentado niebla mental?|S
    Crecimiento de los senos|¿Has notado crecimiento de los senos?|H
    Sensibilidad en los senos|¿Has sentido sensibilidad en los senos?|H
    Respiración consciente|¿Practicaste la respiración?|R
    Cafeína|¿Consumiste cafeína?|E
    Calcio|¿Consumiste calcio?|N
    Suplemento de calcio|¿Tomaste un suplemento de calcio?|P
    Calorías|¿Hiciste un seguimiento de tus calorías?|N
    Acampar|¿Acampaste al aire libre?|E
    Carbohidratos|¿Consumiste carbohidratos?|N
    Cuidados|¿Cuidaste de la salud de otra persona?|E
    Viajar en coche o tren|¿Viajaste en coche o en tren?|E
    Un gato en la habitación|¿Tenías un gato en la habitación mientras dormías?|C
    CBD|¿Consumiste aceite de CBD en cualquier forma?|P
    Moco cervical: rosa, café o canela|¿Tu moco cervical es rosa, café o canela?|H
    Desafío|¿Te has enfrentado a desafíos?|M
    Quimioterapia|¿Recibiste quimioterapia?|T
    Pollo/aves|¿Comiste pollo/aves?|N
    Niño en la habitación|¿Dormiste con un niño en tu habitación?|C
    Escalofríos|¿Has sentido escalofríos?|S
    El quiropráctico|¿Visitaste al quiropráctico?|R
    Alimentación sana|¿Evitaste alimentos procesados?|N
    Clonidina|¿Has usado clonidina para los síntomas de la menopausia, por ejemplo, sofocos?|H
    Baño con agua fría|¿Tomaste un baño con agua fría?|R
    Terapia de compresión|¿Hiciste terapia de compresión?|R
    Concepción|¿Estás intentando concebir?|H
    Conmoción|¿Te sentiste conmocionado?|S
    Congestión|¿Te sentiste congestionado?|S
    Estreñimiento|¿Has experimentado estreñimiento?|S
    Terapia de contraste|¿Practicaste la terapia de contraste (calor/frío)?|R
    Control|¿Sentiste que tenías control sobre tu vida?|M
    Almohadilla de enfriamiento|¿Usaste una almohadilla de enfriamiento para la recuperación muscular?|R
    Síntomas de COVID-19|¿Tienes síntomas de COVID-19?|S
    Vacunación COVID-19 (refuerzo)|¿Recibiste un refuerzo de la vacuna contra el COVID-19?|T
    Vacunación COVID-19 (segunda dosis)|¿Recibiste la segunda dosis de la vacuna contra el COVID-19?|T
    Máquina CPAP|¿Utilizaste una máquina de CPAP?|C
    Crioterapia|¿Usaste tratamiento de crioterapia?|R
    Ventosas|¿Recibiste terapia de ventosas?|R
    Irregularidad del ciclo|¿Ha sufrido irregularidades en el ciclo o no has tenido algunos periodos?|H
    Una dieta sin lácteos|¿Sigues una dieta sin lácteos?|N
    Chocolate oscuro|¿Comiste chocolate oscuro?|N
    Comer a la luz del día|¿Comiste todas tus comidas durante las horas del día?|C
    Disminución de la libido|¿Has experimentado una disminución de la libido?|H
    Depresión|¿Sentiste depresión o decaimiento?|M
    Dispositivo (por ejemplo, teléfono) en la cama|¿Usaste un dispositivo con pantalla en la cama?|C
    DHEA|¿Tomaste suplementos de DHEA para el apoyo de las glándulas suprarrenales?|P
    Diálisis|¿Recibiste tratamiento de diálisis?|T
    Diarrea|¿Has padecido diarrea?|S
    Luces tenues|¿Atenuaste tus luces después del atardecer?|C
    Mareos/aturdimiento|¿Ha sentido mareos o vértigos hoy?|S
    Perro en la habitación|¿Dormiste con un perro en la habitación?|C
    Piel seca|¿Tu piel está más seca de lo habitual?|S
    Tapones para los oídos|¿Usaste tapones para los oídos al acostarte?|C
    Eficacia|¿Sentiste que tenías los recursos/habilidades necesarios para completar tus objetivos diarios?|M
    Electrolitos|¿Tomaste suplementos de electrolitos?|P
    Estado emocional/mental|¿Te sentiste estable emocional y mentalmente?|M
    Nivel de energía|¿Te sentiste con energía durante todo el día?|M
    Baño de sal de Epsom|¿Te diste un baño con sales de Epsom?|R
    Estrógeno|¿Has tomado suplementos o usado parches de estrógenos?|H
    Familia y amigos|¿Conectaste con familiares o amigos?|E
    Fatiga|¿Has experimentado fatiga?|S
    Grasas|¿Consumiste grasas?|N
    Alimentar al bebé por la noche|¿Te despertaste para alimentar por la noche?|E
    Fiebre|¿Tienes fiebre?|S
    Fibra|¿Consumiste fibra?|N
    Aceite de pescado|¿Tomaste aceite de pescado?|P
    Estado de flujo|¿Has experimentado el estado de flujo?|M
    Rodillo de espuma|¿Usaste un rodillo de espuma para la tensión muscular?|R
    Sensibilidad a los alimentos|¿Tuviste sensibilidad a los alimentos?|S
    Olvidos|¿Has experimentado pérdida de memoria u olvidos?|S
    Gabapentina|¿Has usado gabapentina para los síntomas de la menopausia?|H
    Gases|¿Has experimentado un exceso de gases?|S
    GLP-1|¿Tomaste tu medicamento GLP-1?|T
    Dieta sin gluten|¿Sigues una dieta sin gluten?|N
    Gratitud|¿Expresaste gratitud?|M
    Puesta a tierra o conexión a tierra|¿Practicaste grounding o earthing?|R
    Hoja de puesta a tierra|¿Dormiste con una sábana de grounding o earthing?|C
    La dieta halal|¿Sigues una dieta halal?|N
    Dolor de cabeza|¿Tuviste dolor de cabeza?|S
    Acidez estomacal|¿Has experimentado acidez estomacal?|S
    Palpitaciones del corazón|¿Has sentido palpitaciones en el corazón hoy?|S
    Almohadilla térmica|¿Usaste una almohadilla térmica para la recuperación muscular?|R
    Té de hierbas|¿Bebiste té de hierbas?|N
    Bochornos durante el sueño|¿Tuviste sofocos mientras dormías?|H
    Bochornos durante el día|¿Has experimentado sofocos durante el día?|H
    Ducha caliente antes de acostarse|¿Tomaste una ducha caliente antes de acostarte?|C
    Jacuzzi|¿Pasaste tiempo en un jacuzzi?|R
    TRH|¿Has usado terapia de reemplazo hormonal combinada (TRH)?|H
    Humidificador|¿Utilizaste un humidificador mientras dormías?|C
    La cámara hiperbárica|¿Usaste una cámara hiperbárica?|R
    Baño helado|¿Tomaste un baño de hielo?|R
    Aumento de la libido|¿Has experimentado un aumento de la libido?|H
    Indigestión|¿Tuviste indigestión?|S
    Alfombrilla de infrarrojos PEMF|¿Usaste una esterilla PEMF infrarroja?|R
    Ayuno intermitente|¿Seguiste una dieta de ayuno intermitente?|E
    Tabla de inversión|¿Usaste una tabla de inversión?|R
    Hierro|¿Tomaste suplementos de hierro?|P
    Irritabilidad|¿Te sentiste irritable?|M
    Ivabradina|¿Tomaste Ivabradina?|T
    Desfase horario|¿Experimentaste jet lag?|E
    Dolor o rigidez en las articulaciones|¿Has tenido dolor o rigidez en las articulaciones?|S
    Escribir un diario|¿Escribiste tus pensamientos en un diario?|M
    Ketamina|¿Tomaste ketamina?|T
    La dieta cetogénica|¿Seguiste una dieta cetogénica?|N
    Dieta kosher|¿Sigues una dieta kosher?|N
    Aprendizaje|¿Aprendiste algo interesante o importante?|M
    Levotiroxina|¿Tomaste medicamento de levotiroxina?|P
    Soledad|¿Sentiste soledad?|M
    Entorno de sueño ruidoso|¿Dormiste en un ambiente ruidoso?|C
    LSD|¿Tomaste LSD (dietilamida del ácido lisérgico)?|T
    L-teanina|¿Tomaste suplementos de L-teanina?|P
    Prueba de hormona luteinizante (LH)|¿Te hiciste una prueba de la hormona luteinizante?|H
    Magnesio|¿Consumiste magnesio?|N
    Avanzar|¿Avanzaste en un objetivo importante?|M
    Marihuana|¿Consumiste marihuana?|T
    Terapia de masajes|¿Recibiste masajes terapéuticos?|R
    Carne|¿Consumiste carne?|N
    Meditación|¿Meditaste?|M
    Melatonina|¿Tomaste un suplemento de melatonina?|P
    Calambres menstruales|¿Sufres dolores menstruales?|H
    Menstruación|¿Estás menstruando?|H
    Migraña|¿Tuviste migraña?|S
    Paquete Momentous para dormir|¿Tomaste el paquete Momentous para dormir?|P
    Síntomas de la viruela del mono|¿Tienes síntomas de viruela del mono?|S
    Cambios de humor|¿Has experimentado cambios de humor?|M
    Snack de la mañana|¿Comiste un snack por la mañana?|N
    Luz solar matutina|¿Viste la luz directa del sol al despertarte?|C
    Motivación|¿Te sentiste motivado?|M
    Guarda dental|¿Usaste una guarda bucal para dormir?|C
    Cinta bucal|¿Usaste cinta bucal para dormir?|C
    Multivitaminas|¿Tomaste un multivitamínico?|P
    Dolores musculares/corporales|¿Has tenido dolor en los músculos o en el cuerpo?|S
    Las tiras nasales|¿Usaste una tira nasal para dormir?|C
    Náuseas|¿Has sufrido náuseas?|S
    Nicotina|¿Has consumido nicotina?|T
    Guarda nocturna o retenedor|¿Dormiste con una guarda nocturna o retenedor?|C
    Pesadilla|¿Tuviste una pesadilla?|C
    Cambios nocturnos|¿Trabajaste en el turno de la noche?|E
    Sudores nocturnos|¿Has notado que los sudores nocturnos interrumpen tu sueño?|H
    Sin flujo menstrual|¿Tuviste tu periodo pero sin flujo menstrual?|H
    Enfermería|¿Estás cuidando a alguien?|E
    Los bebés lactantes|¿Estás amamantando a un bebé?|H
    Nueces|¿Comiste nueces?|N
    Turnos de guardia|¿Trabajaste en un turno de guardia?|E
    Tiempo al aire libre|¿Pasas tiempo al aire libre?|E
    Agobio|¿Te sientes abrumado?|M
    Ovulación|¿Estás ovulando?|H
    Relaciones sexuales dolorosas|¿Tuviste molestias o dolor durante las relaciones sexuales?|H
    La dieta paleo|¿Sigues una dieta paleo?|N
    Crianza|¿Estás criando a un bebé?|E
    Criar a un niño enfermo|¿Crías a un niño enfermo?|E
    Dolor pélvico|¿Has experimentado dolor pélvico?|H
    Masaje de percusión|¿Usaste un masajeador de percusión (por ejemplo, Hypervolt, Theragun)?|R
    Perimenopausia|¿Tienes síntomas de perimenopausia?|H
    Fisioterapia|¿Recibiste fisioterapia?|R
    Proteína de origen vegetal|¿Consumiste proteína de origen vegetal?|N
    Donación de plasma|¿Donaste plasma?|E
    Donación de plaquetas|¿Donaste plaquetas?|E
    Positividad|¿Te sientes generalmente optimista sobre el futuro?|M
    Caminata después de comer|¿Caminaste después de comer?|R
    Posmenopausia|¿Tienes síntomas de posmenopausia?|H
    Vitaminas posnatales|¿Tomaste suplementos posnatales?|P
    Embarazo|¿Estás embarazada?|H
    Vitaminas prenatales|¿Tomaste suplementos prenatales?|P
    Analgésicos con receta|¿Tomaste analgésicos recetados?|T
    Medicamentos recetados para dormir|¿Tomaste medicamentos recetados para el sueño?|T
    Los probióticos|¿Tomaste un probiótico?|P
    Progesterona|¿Tomaste suplementos o inyecciones de progesterona?|H
    Cremas de progesterona|¿Usaste cremas de progesterona de venta libre?|H
    Psilocibina|¿Tomaste psilocibina (hongos mágicos)?|T
    Extracción|¿Extracción de leche materna?|H
    Propósito|¿Sientes que tienes un propósito?|M
    Radioterapia|¿Recibiste terapia de radiación?|T
    El ramadán|¿Celebras el Ramadán?|E
    Recuperación|¿Te sentiste recuperado/a?|R
    Terapia de luz roja|¿Recibiste terapia de luz roja?|R
    Disminución de la motivación|¿Te has sentido menos motivado?|M
    Estado sentimental|¿Eres soltero/a?|E
    Estrés en la relación|¿Tuviste estrés en una relación?|M
    Trabajo remoto|¿Trabajaste desde casa?|E
    Día de descanso|¿Te tomaste un día de descanso?|R
    Rhodiola Rosea|¿Tomaste extracto de Rhodiola rosea?|P
    El sauna|¿Usaste una sauna?|R
    Alergias estacionales|¿Tuviste alergias estacionales?|S
    Privación sensorial|¿Usaste un tanque de aislamiento sensorial?|R
    Habitación compartida con un niño|¿Has compartido un espacio para dormir con un niño?|C
    Enfermedad|¿Te sientes enfermo?|S
    Cambios en la piel|¿Has notado cambios en la piel, como resequedad o sensibilidad?|S
    Dormiste a gran altitud|¿Dormiste en altitud?|C
    Interrupción del sueño|¿Tuviste una interrupción del sueño?|C
    Duermes en una habitación oscura|¿Dormiste en una habitación oscura?|C
    Antifaz|¿Usaste un antifaz para dormir?|C
    Disminución de la calidad del sueño|¿Ha experimentado una reducción de la calidad del sueño debido a los síntomas de la menopausia?|H
    Comer entre comidas|¿Comiste entre comidas?|N
    Roncar (pareja)|¿Tu pareja roncó?|C
    La realización social|¿Te sentiste socialmente realizado/a?|M
    Socialmente agotado|¿Te sentiste socialmente agotado?|M
    Redes sociales|¿Usaste redes sociales?|E
    Aislamiento social|¿Te has aislado socialmente?|M
    Sodio|¿Consumiste sodio?|N
    Tiempo a solas|¿Tuviste algún tiempo a solas?|M
    Dolor|¿Sentiste dolor muscular?|S
    Baño de sonido|¿Participaste en un baño de sonido?|R
    Máquina de sonido (por ejemplo, ruido blanco)|¿Escuchaste ruidos mientras dormías?|C
    Espiritualidad|¿Realizaste alguna actividad espiritual?|M
    Medicamento ISRS|¿Tomaste medicamentos ISRS?|T
    Escritorio de pie|¿Usaste un escritorio de pie?|E
    Sala de vapor|¿Usaste una sala de vapor?|R
    Estrés|¿Experimentaste estrés?|M
    Estiramiento|¿Pasaste tiempo estirándote?|R
    Puesta del sol|¿Viste la puesta de sol?|C
    Comida para llevar|¿Comiste comida para llevar?|N
    Jugo de cereza ácida|¿Bebiste jugo de cereza ácida?|P
    Sensibilidad a la temperatura|¿Te has sentido inusualmente sensible a los cambios de temperatura?|S
    Gel/crema de testosterona|¿Usaste gel o crema de testosterona?|H
    Suplementos de testosterona|¿Tomaste suplementos de testosterona?|H
    Sesión de terapia|¿Tuviste una sesión de terapia?|M
    Amenaza|¿Te has enfrentado a amenazas?|M
    Medicamento para la tiroides|¿Tomaste medicamentos para la tiroides para manejar los desequilibrios hormonales?|T
    Hormigueo/entumecimiento|¿Has sentido hormigueo o entumecimiento en las extremidades?|S
    Tinnitus|¿Tuviste tinnitus?|S
    El tabaco|¿Consumiste tabaco en cualquiera de sus formas?|T
    Tofu|¿Comiste tofu?|N
    Dificultad para concentrarte|¿Tienes problemas para concentrarte?|S
    Cúrcuma|¿Tomaste cúrcuma?|P
    Síntomas urinarios|¿Tuviste síntomas urinarios (por ejemplo, urgencia o incontinencia)?|S
    Secreción vaginal - espesa|¿Has notado flujo vaginal espeso?|H
    Secreción vaginal - clara de huevo|¿Has notado flujo vaginal con una consistencia similar a la clara de huevo?|H
    Secreción vaginal - gris|¿Has notado que el flujo vaginal es gris?|H
    Secreción vaginal - pegajosa|¿Has notado flujo vaginal pegajoso?|H
    Secreción vaginal - Acuosa|¿Has notado que el flujo vaginal es acuoso?|H
    Sequedad vaginal|¿Has experimentado sequedad vaginal?|H
    Crema de estrógeno vaginal|¿Has utilizado cremas de estrógeno vaginal?|H
    Anillos de estrógeno vaginal|¿Has utilizado anillos de estrógeno vaginal?|H
    Tabletas vaginales de estrógeno|¿Has usado tabletas de estrógeno vaginal?|H
    Manchado vaginal|¿Has notado manchado vaginal?|H
    Estimulación del nervio vago|¿Usaste dispositivo de estimulación del nervio vago?|R
    Valerian|¿Tomaste un suplemento de valeriana para dormir?|P
    La dieta vegana|¿Sigues una dieta vegana?|N
    Dieta vegetariana|¿Sigues una dieta vegetariana?|N
    Vitamina B-12|¿Tomaste vitamina B-12?|P
    Vitamina C|¿Tomaste vitamina C?|P
    Vitamina D|¿Tomaste vitamina D?|P
    Vómitos|¿Has experimentado vómitos?|S
    Baño caliente|¿Tomaste un baño caliente?|R
    Las cobijas con peso|¿Usaste una manta pesada para dormir?|C
    Medicamentos para perder peso|¿Tomaste medicamentos para perder peso?|T
    Trabajar hasta tarde|¿Trabajaste hasta tarde?|E
    Zinc|¿Tomaste un suplemento de zinc?|P
    Cardio de Zona 2|¿Hiciste cardio de Zona 2?|R
    """

    /// Preguntas de versiones antiguas del export / de PulseApp que no salen en la lista de WHOOP: solo para el nombre.
    private static let legacy: [(q: String, name: String)] = [
        ("¿Usaste pantallas en la cama?", "Pantallas en la cama"),
        ("¿Tomaste cafeína por la tarde?", "Cafeína tardía")
    ]

    static let items: [Item] = raw.split(separator: "\n").compactMap { line in
        let p = line.trimmingCharacters(in: .whitespaces).components(separatedBy: "|")
        guard p.count == 3 else { return nil }
        return Item(name: p[0], q: p[1], cat: p[2])
    }

    // MARK: Personalizados (nombre + pregunta, en UserDefaults)

    private static let customKey = "pulseapp_journal_custom"

    static func custom() -> [Item] {
        let a = UserDefaults.standard.array(forKey: customKey) as? [[String]] ?? []
        return a.compactMap { $0.count == 2 ? Item(name: $0[0], q: $0[1], cat: customCat) : nil }
    }

    /// Añade un comportamiento propio. La pregunta se forma sola si no se da ("¿<nombre>?").
    @discardableResult
    static func addCustom(name: String, question: String) -> Item? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return nil }
        var q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { q = n }
        if !q.hasPrefix("¿") { q = "¿" + q }
        if !q.hasSuffix("?") { q += "?" }
        if all().contains(where: { $0.q == q }) { return all().first { $0.q == q } }
        var a = UserDefaults.standard.array(forKey: customKey) as? [[String]] ?? []
        a.append([n, q])
        UserDefaults.standard.set(a, forKey: customKey)
        return Item(name: n, q: q, cat: customCat)
    }

    static func all() -> [Item] { return custom() + items }

    static func item(_ q: String) -> Item? { return all().first { $0.q == q } }

    static func name(_ q: String) -> String {
        if let i = item(q) { return i.name }
        if let n = legacy.first(where: { $0.q == q })?.name { return n }
        return q.trimmingCharacters(in: CharacterSet(charactersIn: "¿?"))
    }

    /// Para buscar sin tildes ni mayúsculas.
    static func fold(_ s: String) -> String {
        return s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_ES"))
    }
}
