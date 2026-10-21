# PulseApp — contexto del proyecto para Claude

App Android propia (`com.pulseapp.android`) que lee una **WHOOP 5.0** por Bluetooth y calcula
todo en local, **sin suscripción ni API de WHOOP**. Debe parecerse y comportarse como la app de WHOOP.
El usuario habla español: responde siempre en español, claro y paso a paso.

## Cómo trabaja el usuario (importante)
- No tiene Mac ni Android Studio. Compila con **GitHub Actions** (`.github/workflows/build.yml`,
  `gradle assembleDebug`, SDK instalado a mano) y se instala el APK del artefacto `PulseAndroid-apk`.
  A veces el workflow no salta solo y lo lanza a mano.
- Prefiere **lotes grandes de cambios** antes de reinstalar; una sola prueba por instalación.
- No quiere que se adivine: verificar con datos reales antes de afirmar algo.
- **Nunca perder datos al actualizar**: cualquier cambio en Room = nueva versión + `Migration`.
- La app debe funcionar **siempre en segundo plano** (servicios en primer plano `connectedDevice`).
- Zona horaria: Europe/Madrid. Los CSV usan hora unix (UTC).

## Stack
Kotlin, minSdk 26, target/compile 34, Java 17. Room 2.6.1 con **KSP** (kapt no funciona).
`gradle.properties`: `android.useAndroidX=true`, `android.enableJetifier=false`, `org.gradle.jvmargs=-Xmx2048m`.
Archivos Gradle en **Groovy**. Usar `Locale.US` al escribir números en CSV. Trabajo pesado en `Dispatchers.IO`.
Base de datos: versión 9, migraciones 1→9 registradas en `AppDatabase.kt` (9 = fases de cada noche en daily_metrics).

## Pantallas y archivos principales (`app/src/main/java/com/pulseapp/android/`)
- `MainActivity` (inicio: Recuperación, Esfuerzo/Strain, Sueño, Estrés, calorías, actividades),
  `RecoveryDetailActivity`, `SleepDetailActivity`, `StressDetailActivity`, `ActivitiesListActivity`,
  `EditSessionActivity`, `ProfileActivity` ("Sobre mí"), `WhoopExperimentalActivity` (pruebas BLE WHOOP).
- **`WhoopBackgroundService` = LA conexión** (desde 14/10): servicio en primer plano, WHOOP vinculada, `autoConnect=true`,
  cola de operaciones GATT, suscripciones → HELLO → orden 3 (pulso en directo) → GET_CLOCK + orden 22 (historial).
  Pulso (estándar 2A37 si existe + registros v18 con su hora) → `hr_log.csv` vía `DataStore.appendAt` → Inicio funciona igual.
  Todo lo recibido (menos IMU) → `whoop_history_raw.txt` ("ms,RX/TX,uuid,HEX"); registro → `whoop_service_log.txt`.
  Estado estático (`state`, `lastBpm`, `liveCount`, `historyCount`) que leen Inicio (cada 2 s) y "Mi WHOOP".
  Acciones por Intent: CONNECT, HISTORY, IMU_ON/OFF, STOP. `BootReceiver` reconecta al encender. `LiveHrProcessor`:
  actividad automática y cálculo del día con la hora de cada lectura. `ActivityState`: actividad manual guardada en disco.
- `WhoopExperimentalActivity` = pantalla "Mi WHOOP": vincular (1 buscar → 2 vincular) y luego solo muestra/controla el servicio.
- `BleForegroundService` (modo estándar 0x180D) — YA NO SE USA; Inicio lo para al abrir.
- Los parsers de `hr_log.csv` ordenan y quitan duplicados por segundo (el historial llega desordenado).
- Cálculos: `MetricsCalculator`, `DailyMetricsUpdater`, `RecoveryCalculator`, `BaselineProvider`,
  `SleepPlanner`, `StressCalculator`, `CalorieCalculator`, `ActivityRecorder`, `RespiratoryRateCalculator` (espectral desde 17/10), `NightMetrics`.
- IMU (nuevo, verificado): `WhoopImuReassembler`, `WhoopImuRawStore` (`whoop_imu_raw.txt`),
  `WhoopImuDecoder`, `ImuStepCounter`, `MotionTracker` (`motion_minutes.csv`), `MotionTrackerHolder`.

## Perfil obligatorio
Inicio no deja usar la app sin fecha de nacimiento, peso, altura y sexo (`checkSetupComplete`). Edad → FC máx (Tanaka) y zonas,
esfuerzo, VO₂ máx, sueño base por edad (`SleepPlanner.baselineForAge`: <14 10 h, <18 9 h, 18–64 7:50, ≥65 7:30).
Peso/altura/edad/sexo → calorías (Mifflin + Keytel). Sexo → TRIMP. Recuperación y estrés son relativos a tu propia línea base.

## Fórmulas actuales (calibradas con el export de WHOOP del usuario, 08/09/2026 — todo en `Formulas.kt`)
- FCmáx = max(Tanaka 208 − 0,7·edad, FC máx observada). La observada se guarda en SharedPreferences
  `pulseapp_formulas/hr_max_observed`, se edita en Sobre mí ("FC máxima"; la suya en WHOOP = 199) y sube sola
  al guardar una actividad con FC más alta (150–220 y ≤ +8 lpm sobre la actual). `Formulas.init(ctx)` en Main y servicios.
  Zonas 0–5 por % FCmáx (<50, 50–60, 60–70, 70–80, 80–90, >90).
- Esfuerzo = TRIMP Banister con reserva de FC, sólo minutos con FC ≥ 45 % FCmáx → 4,14·ln(1+TRIMP/2,6), máx 21.
  Misma curva para día y actividades. Error vs WHOOP: fútbol 0,7, global 1,7 (173 entrenos).
- Recuperación = sigmoide(0,84 + 5,5·(ln VFC − EWMA14 ln VFC previas) − 0,028·(FCR − EWMA FCR)) − penalización si
  respiración z>2. Sin línea base: referencia 86 ms y 59 lpm. El SUEÑO NO entra (en sus datos no cambia la nota).
  Comprobado en Kotlin con 155 noches: MAE 6,4, ±10 puntos 84 %, color igual 85 %.
- Calificación sueño = 0,281·horas vs necesidad (máx 100) + 0,202·eficiencia + 0,288·regularidad + 19,6 (MAE 1,9).
  Es lo que muestra el anillo de Sueño del inicio. Regularidad = 100 − sd(hora de dormirse, 7 noches)/120·100.
- FC reposo = mediana de la ventana de sueño (cuadra con WHOOP: 58 vs 57, 59 vs 59).
- VFC (17/10, `NightMetrics`) = con fases (≥20 min de profundo): media de los RMSSD de los tramos de PROFUNDO ponderada por duración;
  sin fases, RMSSD de toda la ventana. Filtra saltos >20 %. 15→16: 87 (WHOOP 80); 16→17: 104 (WHOOP 108). Toda la noche daba 70 / 87.
  `BaselineProvider` solo usa VFC y respiración de días ≥ `NEW_METHOD_SINCE` (2026-10-17) para no mezclar escalas.
- Sueño (`SleepDetector`, ajustado 15/10 con la noche 14→15 vs WHOOP): 20:00–12:00, medias por minuto suavizadas 3 min,
  umbral 1,30 × media del 10 % más bajo, tolera 30 min por encima, hueco >10 min = desconexión, mínimo 90 min, la última
  ventana. Resultado: 23:20–07:24, 39 min despierto, 91 % (WHOOP 23:17–07:20, 42 min, 92 %). VFC de esa ventana ≈ 69 (WHOOP 69),
  FC reposo mediana 64 (WHOOP 64). Ciclo del día = desde que te duermes (o 00:00): esfuerzo y FC media solo de ese ciclo
  (antes usaba todo el archivo). `DailyMetricsUpdater` guarda la noche que TERMINA ese día (18:00 víspera → 14:00).
  `BaselineProvider` solo usa días con ≥ 3 h dormido. Sin 3 noches propias: referencia 86 ms / 59 lpm (media reciente WHOOP).
- Necesidad de sueño = 470 min + max(0, strain−8)·6 + deuda. **Deuda (18/10, ajustada con 152 noches del export)** = max(0, (necesidad
  de esa noche − dormido) / 2) (`SleepPlanner.nextDebt`, MAE 1,5 min; la de antes ×0,7 sobre la base salía el doble). Sin dato esa noche: deuda/2.
  Hora de despertar editable (7:30 por defecto).
- **Regularidad (18/10, 145 noches del export)** = media de intersección/unión del tramo en cama de la última noche con cada una de las 3
  anteriores (eje desde las 12:00) × 100 − 7 (`Formulas.sleepConsistency(noches)`), MAE 4,9, 87 % a ±10. La de antes (sd de la hora de
  dormirse, 7 noches) tenía MAE 27. Ojo: esta semana WHOOP salió ~7 puntos por encima del export (92/89/64/76 vs J3 89/91/65/77 sin restar 7);
  revisar el −7 en la ronda grande.
- Calorías = Mifflin-St Jeor × (min transcurridos/1440) × 1,15 + kcal de actividades (Keytel).
- VO2máx = 15,3 × FCmáx / FC reposo, se recalcula sólo los martes.
- Estrés (15/10): ventanas de 5 min de las últimas 24 h, 4,8·(0,7·(FC−FCRbase)/FCRbase + 0,3·ln(VFCbase/VFC)) → 0–3.
  Noche 14→15: 54/38/8 % vs WHOOP 53/42/5 %. Gráfica: eje = últimas 24 h, se corta en huecos >15 min.
- Actividad automática: media 4 min >60 % FCmáx durante 8 min empieza; <55 % 5 min termina.
- SpO₂ es imposible offline (los canales rojo/IR no se muestrean a la vez). Las puntuaciones oficiales de WHOOP
  se calculan en su nube y no se pueden leer.

## Fases del sueño (16/10, `SleepStager.kt`)
Solo se ejecuta si esa noche hay `motion_minutes.csv` (≥60 % de los minutos de la ventana de `SleepDetector`); sin movimiento no se inventan fases.
- Despierto: minuto agitado = (≥10 s moviéndose o pasos) y pulso ≥ +6 lpm sobre la base local (percentil 33 de ±20 min), o ≥30 s de movimiento,
  o pulso ≥ +15 con giro/cambio de postura. Grupos con huecos ≤2 min, 1 min antes y hasta 2 después; vale si dura ≥3 min o el pulso sube ≥12.
- Profundo / REM: respecto a la MEDIANA LOCAL de ±45 min (quita la subida circadiana de VFC y la bajada de pulso) de pulso (mediana 5 min) y ln RMSSD
  (ventana 7 min, ≥40 diferencias RR). Profundo: ΔlnRMSSD ≥ 0,3·(progreso−0,5) y Δpulso ≤ −0,5; REM (17/10): ΔlnRMSSD ≤ −0,2 + 0,4·(progreso−0,5) y Δpulso ≥ 0.
  Sin REM en los primeros 45 min ni profundo en los últimos 45. Lejos (±2 min) de un despertar. Tramos <4 min → ligero.
- Calibración con 2 noches de WHOOP (14→15: despierto 42/ligero 266/profundo 120/REM 54; 15→16: 33/240/126/52, 9 despertares, eficiencia 93 %).
  Resultado 15→16 con movimiento: 34/236/125/52 min, 10 despertares, 92 %. Solo se ajustaron totales: no hay hipnograma minuto a minuto de WHOOP,
  así que la COLOCACIÓN de las fases no está validada. Referencia de tus 155 noches de WHOOP: ligero 298±52, profundo 100±16, REM 86±27, despierto 33±13
  (estas dos noches tuvieron más profundo y menos REM de lo normal, venían de gimnasio/fútbol).
- Recorte (17/10): la noche empieza en el primer tramo de ≥15 min sin despertar y acaba en el último minuto dormido
  (`trimBounds`). `MetricsCalculator`/`DailyMetricsUpdater` usan esa ventana para horas, FC reposo, VFC y respiración.
- Noche 16→17 (3.ª referencia, WHOOP 01:10–09:08: despierto 15 / ligero 206 / profundo 126 / REM 131, 7 despertares, 97 %,
  VFC 108, FCR 56, resp 13,1, recuperación 86). Antes: 00:22–09:11, 65/264/125/76, 15 despertares, 87 %, VFC 87, resp 8,2, rec. 72.
  Ahora: 01:11–09:08, 23/204/125/125, 9 despertares, 95 %, VFC 104, FCR 57, resp 12,6, recuperación 87.
  15→16 con el ajuste: 34/226/126/63 (WHOOP 33/240/126/52).
- Respiración (17/10): espectral, tramos de 2 min → RR a 4 Hz, sin tendencia, Hann, pico 0,1–0,5 Hz, mediana (≥10 tramos).
  La media móvil de 5 latidos de antes borraba la respiración (≈4–5 latidos por respiración).
- Inicio: `hrvText` nunca se rellenaba (VFC salía siempre "–"). Corregido 17/10.
- `MetricsCalculator.analyze` usa el resultado para tiempo despierto, dormido y eficiencia (si hay fases); `DailyMetricsUpdater` también.
  `SleepDetailActivity` muestra `HypnogramView` + 4 fases. `SleepPlanner.planForLastNight` = necesidad de la noche dormida con el esfuerzo de AYER.
- Movimiento por noche: ENMO NO sirve parado (el offset de calibración da 0–40 mg según la postura); usar `still_secs`, `gyro_dps` (suelo 1,4) y cambio de gravedad.
- AVISO horario: `hr_log.csv` guarda hora LOCAL sin zona; el 25/10/2026 (fin del horario de verano) la hora 02:00–03:00 se repite y esas lecturas se pisan.

## Protocolo WHOOP 5.0 (lo que funciona)
- Servicio `fd4b0001-cce1-4033-93ce-002d5875f58a`; órdenes a `fd4b0002` (write con respuesta);
  notificaciones en `fd4b0003/0004/0005/0007`. Suscribirse **de una en una** esperando `onDescriptorWrite`.
- Un único bond cifrado a la vez (modo emparejar: tocar la pulsera hasta LED azul). Tras el bond: cerrar GATT y reconectar.
  Comprobar `BOND_BONDED` antes de `createBond`.
- CLIENT_HELLO fijo: `AA0108000001E67123019101363E5C8D`.
- Trama: `[AA][01][declLen u16 LE][00 01][CRC16-Modbus de la cabecera] [0x23][seq][cmd][payload, relleno a 4] [CRC32 zlib LE]`.
- Opcodes usados: 3 TOGGLE_REALTIME_HR, 10 SET_CLOCK, 11 GET_CLOCK, 22 SEND_HISTORICAL_DATA, 23 HISTORICAL_DATA_RESULT,
  26 GET_BATTERY, 34 GET_DATA_RANGE, 63 SEND_R10_R11_REALTIME, 97 EXIT_HIGH_FREQ_SYNC, 0x78 SET_CONFIG, 81 START_RAW_DATA, 106 TOGGLE_IMU_MODE.
- **PROHIBIDO enviar** (destructivos): 25, 29, 32, 36, 37, 38, 45, 99.
- **Acelerómetro**: START_RAW_DATA (81, payload `[0]`) y luego TOGGLE_IMU_MODE (106, payload `[1,1]`).
  Llega 1 mensaje tipo 43 por segundo (1244 bytes, troceado 5×244+24 en fd4b0005):
  - [11..12] contador u16 · [15..18] hora unix · [22..23]=100 muestras · [24..25] válidas · [26..27]=3
  - [28..627] acelerómetro 100 X, 100 Y, 100 Z (int16 LE), **4096 = 1 g**, ±8 g
  - [628..639] sub-cabecera giro · [640..1239] giroscopio 100 X/Y/Z, **16,4 = 1 °/s**, ±2000 °/s
  - [1240..1243] CRC32 de [8..1239]. `-32768` = muestra no válida.
  - Gasta 1,5–2,3× batería. **PARAR (16/10): TOGGLE_IMU_MODE 106 con payload `[0,0]` responde código 0 (igual que 81 al arrancar) y DEJAN de llegar datos: el último minuto de movimiento es el de la orden (07:21:43) aunque el pulso siguió 1 min más. Funciona.**
- **Historial (14/10, basado en los proyectos abiertos goose y noop, que ya descargan la 5.0)** — en `WhoopBackgroundService`:
  conexión: HELLO → SET_CLOCK (10, **8 bytes** [unix u32][0×4]; si no, la pulsera cree que perdió la hora y no entrega
  historial) → GET_CLOCK (11, vacío) → EXIT_HIGH_FREQ_SYNC (97,[0]) → orden 3 [1] → a los 1,5 s SEND_HISTORICAL_DATA (22,[0]),
  y repetir cada 15 min. Tramas: tipo en [8], seq/versión en [9], clase en [10]. METADATA 49 (o 56, clase u16 en [10..11]):
  1 START, 2 END, 3 COMPLETE. Confirmar cada END con HISTORICAL_DATA_RESULT (23) payload `[01] + frame[21..29)`.
  Lo confirmado la pulsera lo da por entregado → la app de WHOOP ya no lo tiene: por eso `ackMode` (−1 sin decidir,
  0 WHOOP conserva, 1 PulseApp descarga todo), se pregunta con `AckModeDialog`. Sin confirmar solo llega el 1.er bloque.
  Reensamblado genérico por característica (AA 01 declLen; total = declLen+8). 43/51 = IMU. 36/38 respuestas (cmd [10], resultado [12]).
  Orden 63 SEND_R10_R11_REALTIME [0]/[1] = parar/activar el chorro crudo (IMU). `buildCommand` rechaza las órdenes prohibidas.
  **Prueba real 14/10 19:11–19:19 (modo "WHOOP conserva")**: SET_CLOCK/GET_CLOCK/97/3/22 → OK; orden 63 → "fallo" (no existe
  en la 5.0). Historial: START (49, clase 1) → registros v18 de 124 B (hora @15 real, FC @22 correcta, nRR @23 = 0: sin RR)
  → END (clase 2) repetido cada ~2,5 s esperando la confirmación. El 1.er bloque solo trae **15–22 s** y empieza donde se
  quedó la app de WHOOP del iPhone (19:10:29): sin confirmar, el modo "WHOOP conserva" no sirve para rellenar huecos.
  Tiempo real propietario tipo 40 (32 B, 1/s): hora @10, **FC @16** (verificado contra 2A37); se usa de respaldo.
  **Modo confirmar probado 14/10 19:41**: 36 bloques (≤60 registros cada uno) y COMPLETE en 11 s, 1852 registros 19:10→19:41.
  Después la app de WHOOP del iPhone NO tenía ese tramo → confirmar = WHOOP pierde esos datos (confirmado).
  Aparecen también registros de historial versión 26 (88 B) sin descifrar. Zonas de actividad daban 0 (se truncaba cada
  segundo a 0 min) → corregido. FC reposo del día sin noche = vacía (antes salía la diurna, 74).
- Registro bio v18 (tipo 47): hora @15, FC @22, nRR @23, RR @24.., gravedad f32 @45/49/53, temp piel u16/128 @73.

## Prueba del acelerómetro (14/10, 12:15–12:22)
Quieto → 0 pasos, ENMO ≈0–5 mg; andando ~2 min → 153 pasos (≈90/min, real ≈175), ENMO 90–220 mg;
brazo fuerte → 91 pasos falsos, ENMO 700–2700 mg, picos 8 g. Código verificado en JVM con el archivo real.

## Diseño (rediseño oct-2026, aprobado)
Maqueta aprobada: artefacto "PulseApp rediseño" (Inicio, Sueño, Esfuerzo, Salud, Recuperación, Estrés, Sobre mí).
- Colores en `colors.xml` (convertidos desde OKLCH): fondo #0F1519, tarjeta #1B2126, elevada #292F33, pista #33393E,
  verde #00F88A, ámbar #F9C718, rojo #F04C55, sueño #8FB3D2, esfuerzo #02A9F7, texto #F4F5F6 / #95999D.
  Fases de sueño: stage_awake/rem/light/deep. Zonas: zone1..zone5.
- Fuentes en `res/font`: Barlow Condensed (números y etiquetas en mayúsculas, 0,14 de espaciado) + Archivo (texto).
- Estilos: TitleLabel, BigNumber, StatNumber, LargeTitle, SectionTitle, RowText, Caption, PillButton, TabItem.
- Tarjetas radio 16 (`bg_card`), tarjeta de estrés radio 20 (`bg_card_elevated`), barra inferior flotante + botón Coach.
- Números con coma decimal. Umbrales: recuperación ≥67 verde, 34–66 ámbar, <34 rojo; estrés <1 bajo (azul), 1–2 medio (verde), ≥2 alto (ámbar).
- Hecho: Inicio, Salud (`HealthActivity`, nueva), Sueño, Esfuerzo (`ActivitiesListActivity`), Recuperación, Estrés y Sobre mí.
  Piezas compartidas en `Ui.kt` (barra inferior `include_tab_bar`, cabecera `include_detail_header`, barras apiladas,
  barras de 7 días, filas de lista). Pestañas: Inicio · Salud · Sueño · Esfuerzo + botón Coach.
- Pendiente de diseño: hipnograma de 4 fases en Sueño (cuando exista el clasificador), EditSession y la pantalla experimental.
- Firma: `app/debug.keystore` fijo (contraseña `android`) para que cada APK se instale encima sin perder datos.

## Método de calibración con WHOOP (acordado 17/10)
- Objetivo: que PulseApp dé lo mismo que WHOOP SIN que el usuario tenga que mandar datos. No ajustar para que "una noche" cuadre.
- Cada noche que manda (hr_log, motion_minutes, capturas de WHOOP) se guarda como referencia; todo cambio se valida contra TODAS
  las noches a la vez (error medio por métrica) y solo se acepta si mejora el conjunto. Se cambian reglas generales, no casos.
- No sacar versión cada día: juntar ~7–10 noches variadas (descanso, deporte, acostarse tarde, desvelos) y hacer UNA ronda grande.
- Criterio para dar por cerrado: errores medios dentro de lo que WHOOP varía de por sí (aprox. horas ±10 min, fases ±15 min,
  VFC ±5 ms, FC reposo ±1, recuperación ±5 puntos). Después: igualar el aspecto/pantallas a la app de WHOOP.
- Noches de referencia hasta ahora: 15→16 (deporte la víspera), 16→17 (deporte la víspera). 14→15 sin movimiento.
- **17→18 (4.ª referencia, sábado tranquilo)**: WHOOP 01:06–09:04, dormido 7:30, cama 7:58, despierto 0:28 / ligero 4:03 / profundo 1:47 / REM 1:40,
  13 despertares, 94 %, VFC 98, FCR 56, resp 13,3, necesidad 8:29 (7:50 + 0:02 + deuda 0:37), horas vs necesidad 88 %, regularidad 76 %,
  calificación 85 %, estrés del sueño alto 0 % (0:00/0:25/7:34), recuperación 78 % (medias WHOOP 30 d: VFC 94, FCR 58).
  PulseApp Android: 01:02–09:04, 7:27, cama 8:02, 0:35/4:05/1:55/1:27, 12 desp., 92 %, VFC 99, FCR 57, resp 12,9 → crudo casi igual.
  Porcentajes: necesidad 8:56 (deuda 1:06) → 83 %, regularidad 61 %, calificación 79 %, recuperación 84 % (sin línea base propia: solo hay
  2 noches ≥17/10 → referencia genérica 86/59), estrés alto 2 %. Con deuda y regularidad nuevas: ≈ 89 % / 71 % / 83 %.
  Archivos: hr_log_14.csv, motion_minutes_2.csv, whoop_bio_log.csv (subidos 18/10).
- **18→19 (5.ª referencia, domingo tranquilo, acostarse pronto, noche larga)**: WHOOP 22:36–07:48, dormido 8:34, cama 9:11,
  despierto 0:37 / ligero 4:31 / profundo 1:51 / REM 2:12, 13 despertares, 94 %, VFC 103, FCR 52, resp 13,2, necesidad 8:21
  (7:50 + 0:02 + deuda 0:29), horas vs necesidad 100 %, regularidad 66 %, calificación 85 %, estrés 0:00/0:10/9:04, recuperación 77 %.
  PulseApp (iPhone, compilación con deuda/regularidad nuevas): 22:37–07:47, 8:32, cama 9:10, 0:38/6:00/1:11/1:21, 14 desp., 93 %, VFC 104,
  FCR 53, resp 12,9, necesidad 8:16 (+0:00 + deuda 0:26), 100 %, regularidad 63 %, calificación 84 %, estrés 0:00/0:15/9:00,
  recuperación 88 % (aún referencia genérica; con la línea base de 17 y 18 saldría ≈75 %). Android da las mismas fases (38/360/71/81).
  **Fallo claro: fases.** Profundo −40 min y REM −51 min (todo va a ligero). Las otras 3 noches con movimiento cuadran a ±15.
  Hipótesis para la ronda grande: noche más larga y temprana → la mediana local ±45 min y los umbrales por "progreso" no encajan.
  Archivos: hr_log_15.csv (contiene desde el 14/10, sirve para TODAS las noches), motion_minutes_3.csv (desde el 14/10), whoop_bio_log_1.csv.
  Arnés: /home/claude/check/ftest5/A.kt (fases de todas las noches de referencia de una vez).
- **19→20 (6.ª referencia, 2 h de entrenamiento funcional la víspera, esfuerzo WHOOP 12+)**: WHOOP 23:11–07:29, dormido 7:47, cama 8:18,
  despierto 0:31 / ligero 4:52 / profundo 1:41 / REM 1:14, 13 desp., 96 %, VFC 78, FCR 62, resp 13,4, necesidad 8:28 (7:49 + 0:39),
  horas vs necesidad 92 %, regularidad 73 %, calificación 82 %, estrés 0:25/1:44/6:09, recuperación 45 %.
  PulseApp iPhone: 00:50–07:29, 5:53, 0:46/4:17/0:54/0:42, 15 desp., 88 %, VFC 91, FCR 58, resp 13,2, necesidad 8:19 (+0:29), 70 %,
  regularidad 69 %, calificación 76 %, recuperación 56 % (ya con línea base propia).
  **Dos fallos generales encontrados y corregidos (20/10, Android + iOS):**
  1. `MetricsCalculator.analyze` usaba las últimas 30 h → entraba el final de la noche anterior, el umbral bajaba (64 vs 69) y el inicio
     dependía de la hora de abrir la app (00:50 a las 08:19; 00:00 desde las 18:00). Ahora: desde las 18:00 de ayer, como DailyMetricsUpdater.
  2. Tras entrenar, el pulso siguió en 75 la primera hora dormido (quietud total desde 23:11) y el detector, solo pulso, empezaba a las 00:00.
     Nuevo `SleepStager.extendOnsetByStillness` (dentro de stageNight): hacia atrás, ráfagas ≤5 min/≤12 pasos + tramos de quietud total
     (≥50 s quieto, giro <3, 0 pasos) ≥15 min. 19→20 → 23:12, 52/303/79/63; las otras 4 noches con movimiento salen IGUAL.
  Pendiente: con el inicio bien, despierto 52 (WHOOP 31) y profundo 79 (WHOOP 101): el pulso alto tras entrenar confunde las fases.
- **Doble conexión (19/10, descubierto por el usuario)**: con la app de WHOOP del iPhone conectada a la vez que PulseApp (sin desvincular),
  las dos funcionan toda la noche. PulseApp recibe las respuestas de las órdenes de WHOOP (34, 22, 23, 20, 66, 115, 116) y TODO el historial
  que descarga la app de WHOOP cada 10 min ("Historial completo: ~600 registros"), y ahora los registros v18 traen RR (27 048 de 30 715)
  y temperatura de piel. Lo confirma la app de WHOOP, así que WHOOP no pierde nada. Es el modo recomendado.
  Archivos: hr_log_16.csv, motion_minutes_4.csv, whoop_bio_log_2.csv. Arnés: /home/claude/check/ftest6/B.kt.

- **20→21 (7.ª referencia, sofá 22:00–23:10 y desayuno sentado 08:04–08:11)**: WHOOP (API) 23:14:53–07:39:53, cama 8:25, dormido 8:02,
  despierto 23 / ligero 259 / profundo 98 / REM 126, 15 desp., 96 %, resp 13,4, necesidad 8:33 (7:50+0:23 esfuerzo+0:21 deuda), calificación 90,
  regularidad 82, recuperación 73 (VFC 91,7, FCR 54). PulseApp iPhone: 22:14–08:12, 8:48, 1:10/5:23/2:13/1:12, rec. 57 (VFC 88 vs base 99).
  **Causa**: en el sofá el pulso (62–70) estaba tan bajo como dormido y el detector solo mira pulso; al desayunar sentado, igual.
  **Arreglo (21/10, Android + iOS)**: `SleepStager.motionBounds` sustituye a `extendOnsetByStillness`. Minuto quieto = ≥50 s quieto, giro <2,5, 0 pasos
  (dormido el giro está en 1,3–1,7; en el sofá 3–10). Ancla = primer tramo quieto ≥15 min (tolera 1 min suelto) que llega a la ventana del pulso;
  inicio = hacia atrás saltando giros (≤5 min, ≤12 pasos) hasta el primer tramo ≥15; fin = último tramo ≥15 que empieza antes del fin del pulso
  (si hay movimiento grabado después) + ratos quietos separados por ≤2 min de giros (≤15 pasos). Resultado (inicio/fin vs WHOOP):
  16 23:55–07:25 (23:54–07:25), 17 01:11–09:08 (01:10–09:08), 18 01:02–09:05 (01:06–09:04), 19 22:37–07:48 (22:36–07:48),
  20 23:12–07:30 (23:11–07:29), 21 23:11–07:37 (23:14–07:39) → todas ±4 min. 20→21: 24/297/121/64, dormido 8:02 (WHOOP 8:02).
  Recuperación 57 vs 73: la línea base de VFC (4 noches nuevas, incluida la 19→20 con 91 vs WHOOP 78) sale alta (99 vs ~94 de WHOOP). Se
  corregirá sola con más noches bien recortadas. iOS: en "Sobre mí" faltaba el campo FC máxima → añadido; cambiarla rehace las actividades.

- **Reunión quieto 9:30–11:29 tomada como noche (21/10, versión antigua)**: `SleepDetector.detect` cogía la ÚLTIMA ventana de pulso bajo.
  Ahora elige la ventana con más minutos entre 00:00 y 06:00 (si ninguna, la más larga). Las 6 noches de referencia salen igual; con una
  reunión simulada de 2 h a pulso 60–65 elige la noche (arnés /home/claude/check/ftest8/M.kt).

- **Noche hasta las 15:00 y siestas (21/10, Android + iOS)**. Export: noches de 22:36 a 00:02 de inicio y despertares hasta 14:26; 17 siestas
  (21–151 min, casi todas 14:20–18:30, una 11:09–13:41). Cambios: `SleepDetector.isNightHour` 20:00–15:00, `analyze` y `DailyMetricsUpdater`
  hasta las 15:00. `Formulas.detectNaps` (en `AutoActivityScanner`): tramo quieto (≥50 s, giro <2,5, 0 pasos, tolera 2 min) ≥20 min que empieza
  10:00–21:00 con pulso mediano ≤ FCR+12 → actividad "Siesta" (esfuerzo 0, kcal 0). `SleepPlanner.computeTonightPlan` resta las siestas de hoy
  de la necesidad (como `need_from_recent_nap` de WHOOP). Sin movimiento grabado no se detectan siestas. Por validar con una siesta real y
  con la reunión del 21/10 (9:30–11:29) si había movimiento.

## Actividades como WHOOP (20/10, Android + iOS)
Referencia: entrenamiento funcional 19/10 con la pulsera en PulseApp y WHOOP a la vez. WHOOP: 18:16–18:54 (38:59), detectado solo,
esfuerzo 11,5, 271 kcal, FC media 127 (la media aritmética de esos segundos es 133: WHOOP no usa la media simple), máx 170,
zonas 0–4 = 3:48/21:16/9:07/4:40/0:08 con rangos 112/141/155/168/182 (WHOOP los actualizó solo el 19/10).
PulseApp iPhone (manual 18:15–19:00): 12,2, 484 kcal, 1082 pasos, zonas por % FCmáx 192 (en el iPhone NO estaba puesta la FC máx 199).
- Con nuestro pulso y los límites de WHOOP las zonas salen 3:51/21:13/9:07/4:40/0:08 → el pulso es el mismo; lo que cambia es el cálculo.
- Esfuerzo: con FCmáx 199, FCR 58 y la ventana de WHOOP sale **11,5 exacto** con la fórmula de siempre (no se toca).
- **Zonas = % de la reserva de FC** (40/60/70/80/90): `Formulas.zoneBounds/zoneOf`, FCR = `avgRestingHr` de la línea base guardada en
  prefs (`rhr_zone`). Con FCR 58/FCmáx 199 → 115/143/157/171/185 (WHOOP 112/141/155/168/182 → WHOOP parece usar FCmáx ≈196):
  CONFIRMADO 20/10 con "Ajustes de FC" de WHOOP: "fórmula de FC de reserva", FCR de referencia 59, FCmáx 195 (WHOOP la bajó de 199),
  zonas 112/141/155/168/182 = ceil(FCR + p·reserva) con p = 0,385/0,60/0,70/0,80/0,90 (`ZONE_HRR`). Con 195/59 el funcional sale
  3:49/21:14/9:07/4:39/0:08 (WHOOP 3:48/21:16/9:07/4:40/0:08), esfuerzo 11,7 (WHOOP 11,5; con 199 daba 11,5: la curva se ajustó con 199),
  kcal 291 (WHOOP 271). El usuario debe poner FC máxima 195 en Sobre mí. `ZoneDayCache` cabecera v3 con los límites.
  IA de WHOOP: autodetección = subida mantenida de pulso y movimiento, mínimo 12 min y esfuerzo ≥ 0,1; la FC media de WHOOP filtra
  artefactos y recorta (no es la media simple: media 133, mediana 132, armónica 130,5, WHOOP 127). Detección ahora ≥12 min y ≥8 de núcleo.
- **Calorías de actividad = minutos por zona × factor × metabolismo basal/min** (`Formulas.ZONE_KCAL_BMR` = 1,09/5,13/10,14/10,14/14,56/16,53,
  ajustado con 173 entrenos del export, MAE 13 kcal). Funcional: 272 (WHOOP 271). Keytel daba 484.
- **Calorías del día**: sin el ×1,15. Export: fuera de entrenos 1644 kcal/24 h de mediana ≈ metabolismo basal. Las calorías del día NO
  dependen de llevar la pulsera: base por la hora del día + actividades guardadas (por eso salían 2300 con 1,5 h conectada).
- **Detección automática** (`Formulas.detectActivities` + `AutoActivityScanner`, cada 5 min desde el servicio y al abrir Inicio, sobre
  las últimas 36 h de hr_log): núcleo ≥50 % reserva con huecos ≤5 min, inicio hacia atrás mientras ≥40 %, ≥15 min y ≥10 min de núcleo,
  solo si acabó hace ≥10 min y no se solapa. Funcional 19/10 → 18:16–18:54 exacto; en 7 días solo encuentra además 15/10 18:11–18:37
  (por confirmar con WHOOP). Sustituye la regla en directo (60 %/55 % FCmáx, que daba 18:18–19:00).
- `recalcAllOnce` (prefs `act_recalc`=1): al instalar, rehace zonas/kcal/esfuerzo de todas las actividades guardadas.
- Pasos: WHOOP no muestra pasos en el funcional (sí en fútbol: 6217). Los de PulseApp solo cuentan con el movimiento activado y
  cuentan de menos (~50 %): falta la prueba de 100 pasos. Arnés: /home/claude/check/ftest7/C.kt.

## MCP de WHOOP (20/10, conectado por el usuario en Claude — SOLO para calibrar, la app sigue sin usar la API)
Herramientas mcp__Whoop__get_workouts / get_sleeps / get_recoveries / get_cycles / get_body_measurements: datos oficiales ya puntuados
(no hay pulso segundo a segundo; un entreno aparece ~15 min después de acabar). Ya no hace falta pedir capturas de WHOOP: solo los archivos
de PulseApp (hr_log, motion_minutes). Perfil: 1,69 m, 68 kg, FCmáx 195.
- Entrenos con ms ".000" en inicio/fin = puestos A MANO en WHOOP (p. ej. funcional 15/10 17:56–19:01); los automáticos tienen ms sueltos.
- Calorías por zona (`ZONE_KCAL_BMR`) con las duraciones por zona de la API: 8 entrenos 14–20/10 dentro de ±8 %
  (func 20/10 250 vs 261, fútbol 19/10 666 vs 643, func 19/10 291 vs 271, pickleball 469 vs 434, fútbol 15/10 435 vs 423, fútbol 14/10 540 vs 543).
- Funcional 20/10 (automático en WHOOP 18:20:00–19:04:59, 12,6, 121 de media, 261 kcal, zona 0 22:30): WHOOP alarga la actividad mientras
  sigues moviéndote con el pulso ~100–120 (no corta en la bajada como el 19/10). PulseApp (versión antigua) 18:22–18:48, 11,0. Falta el
  hr_log/motion de ese día para ajustar el FINAL de la detección con movimiento.
- **Detección v2 (20/10, con hr_log_17 + motion_minutes_5)**: tramo ≥26 % reserva (tolera 2 min), núcleo ≥50 % (≥8 min), inicio = 1.er núcleo
  adelantado mientras ≥ zona 1, fin = último núcleo o el último minuto en que el pulso VUELVE A SUBIR ≥5 lpm sobre el mínimo desde entonces.
  19/10 → 18:16:00–18:54:59 y 20/10 → 18:20:00–19:04:59, los dos EXACTOS a WHOOP; sin falsos positivos del 14 al 20/10.
  (El movimiento no hizo falta: el 19/10 tras el núcleo el pulso solo baja; el 20/10 hay subidas de 104→115 y 98→104 con pasos.)
- Esfuerzo con la ventana y zonas de WHOOP (FCmáx 195/FCR 59): func 19/10 11,7 (WHOOP 11,5), func 20/10 12,0 (12,6), func manual 15/10
  10,6 (12,1). En funcionales WHOOP da más peso a la duración moderada (y separa cardio/muscular). Probado: zonas ponderadas y curva
  reajustada con export+API → no mejora (MAE ~1,5–1,8). NO se toca hasta tener ~10 entrenos con pulso segundo a segundo + API.
- Siesta tomada como noche (20/10, 20:28–21:58 en el sofá): `MetricsCalculator.analyze` ahora mira de las 18:00 de ayer a las 14:00 de hoy.

## Pendiente (en orden)
1. Ajustar el contador de pasos con una prueba de 100 pasos contados.
2. ~~Orden de parar el IMU~~ HECHO: 106 `[0,0]` (ver Acelerómetro).
3. ~~Clasificador de sueño en 4 fases~~ HECHO v1 (16/10, ver arriba). Falta validar la colocación con más noches y usar fases en recuperación (VFC en profundo).
4. Integrar movimiento en Sueño, Recuperación, Strain, actividades automáticas y pasos en el inicio.
5. Historial de la pulsera con ACK (caso fútbol). 6. ~~Frecuencia respiratoria por análisis espectral~~ HECHO 17/10. 7. Coach (en espera).

## iOS (carpeta ios/)
- SwiftUI + CoreBluetooth, iOS 16, proyecto generado con XcodeGen (`ios/project.yml`); .ipa sin firmar vía `.github/workflows/build-ios.yml` (macos-15).
- `ios/PulseApp/Core` es el port 1:1 del núcleo Kotlin (verificado numéricamente contra Kotlin con datos reales). No tocar fórmulas sin cambiarlas también en Android.
- Mismas reglas: nunca enviar opcodes 25, 29, 32, 36, 37, 38, 45, 99; no perder datos.
- Los CSV usan hora LOCAL "yyyy-MM-ddTHH:mm:ss" (igual que Android).

## Aspecto WHOOP (17/10, Android; iOS pendiente)
Copiado de capturas reales de la app de WHOOP del usuario (Inicio entero, Monitor de salud, Monitor de estrés, menú "+", detalle de Pickleball).
- `MainActivity` (Inicio): cabecera (perfil, racha 🔥 = días seguidos con ≥1 h de pulso, píldora "< HOY >" que navega a días pasados,
  pulsera con punto verde/ámbar/gris → Mi WHOOP), marca PULSE, 3 anillos finos (`CircularRingView.strokeRatio/numberRatio/suffixRatio`),
  tarjetas Monitor de salud (DENTRO DEL RANGO x/y métricas) y Monitor de estrés, "Mi día" con "+" (menú: agregar/iniciar actividad, Mi WHOOP),
  Perspectiva diaria (texto propio, `Insight`), Actividades de hoy (píldoras), El sueño de esta noche (hora de dormir + hora de despertar EDITABLE,
  `SleepPlanner.wakeMinute`), Mi panel de control (16 filas con valor, tendencia y media de 30 días; PERSONALIZAR oculta filas) y "Más" (ajustes).
  Cabecera fija con anillos pequeños al bajar.
- Todos los números de Inicio salen de `HomeDataLoader.load(dayOffset)` (`HomeData.kt`): hoy en directo con las fórmulas de siempre; días pasados
  recalculados con lo guardado (recuperación con la línea base de los días ANTERIORES, `BaselineProvider.computeFrom`). Zonas semanales con
  `ZoneDayCache` (una pasada por hr_log.csv, caché `zone_days.csv` solo de días cerrados hace ≥3 días). Zonas = % FC máx de la app (no las de WHOOP).
- `HealthActivity` = Monitor de salud (pulso en directo + zona, respiración/FCR/VFC con etiqueta "dentro de / elevado > / baja <", temp sin datos).
- `StressDetailActivity` = Día total / Sin actividad / Sueño frente a un día habitual a la misma hora (`StressBreakdown`).
- `ActivityDetailActivity` (nuevo): esfuerzo y pasos vs media del deporte, gráfica de pulso, zonas con segundos y rango típico, estadísticas clave.
  Menú ··· = editar / eliminar (`ActivitySessionDao.delete`). Tipos: añadido "Pickleball".
- Vistas nuevas en `ui/WhoopViews.kt`; piezas por código en `WhoopUi.kt` (objeto `W`); colores `w_*` en colors.xml; estilos TitleW/HeadingW/ButtonW.
- Comprobado 17/10 con datos reales: compila, recursos enlazan con aapt2, y las gráficas se dibujaron a PNG con un "lienzo" Java2D
  (ver abajo). Estrés del sueño 16→17: 7:20/0:35/0:05 (WHOOP 7:39/0:19/0:00).
- Logo (17/10): anillo con degradado azul→verde (#02A9F7→#16EC06) atravesado por un latido blanco, sobre negro. `drawable/ic_logo.xml`,
  icono adaptativo `mipmap-anydpi-v26` + PNG en todas las densidades, arranque Android 12 en negro (`values-v31/themes.xml`).
  Pantalla de carga animada `ui/LoadingView.kt` (anillo que gira, latido que se dibuja con estela, onda al latir, letras de CARGANDO
  que saltan) en `loadingOverlay` de Inicio; se quita al tener los datos (mínimo 1,6 s, máximo 9 s).
- Sueño (`SleepDetailActivity`, 17/10) y Esfuerzo (`ActivitiesListActivity`) rehechos como WHOOP; reciben `EXTRA_DAY_OFFSET` desde Inicio.
  Gráficas semanales con `ui/WeekChartView.kt` (barras/apiladas, rangos de horas, líneas), `SleepTimelineBar`, `TriSegmentView`.
  `DayRecord` lleva fases, despertares, latencia, tiempo en cama, desglose de la necesidad, fuerza y zonas 1–5 (`ZoneDay` v2).
  Umbrales de los 3 tramos (deficiente/suficiente/óptimo): horas vs necesidad 70/85, regularidad 65/80, eficiencia 80/90, estrés alto 0/5 %.
  Esfuerzo recomendado (marca blanca): recuperación verde 16, amarilla 12, roja 8.
- Pendiente de aspecto: Recuperación y Sobre mí siguen con el diseño anterior.
- **iOS (17/10, rama `ios-whoop-ui`)**: portado el mismo diseño. `Core/HomeData.swift` = HomeDataLoader/DayRecord/ZoneDayCache/Insight/StressBreakdown
  (mismas cuentas que Android). `UI/HomeStore.swift` calcula en una cola y guarda 50 s; `Route` para navegar. Pantallas: `HomeView`, `SleepScreen`,
  `StrainScreen`, `DetailScreens` (Salud, Estrés, Actividad). Piezas en `WComponents.swift`, gráficas con `Canvas` en `WCharts.swift`, carga animada
  `LoadingView.swift`, barra de pestañas flotante en `Screens1.swift`. Icono nuevo (AppIcon 1024) y arranque negro con logo (LaunchLogo/LaunchBackground).
  `DailyMetrics` iOS guarda fases (light/deep/rem/awake/wakeEpisodes/latency, opcionales) y `BaselineProvider` usa `newMethodSince` como Android.
  Compila en GitHub Actions (macos-15). El workflow saca los errores de Swift como avisos (`::error`) legibles por la API sin login.
- **Pasar datos de Android a iOS (17/10)**: Android Más → "Exportar datos (para iPhone)" comparte hr_log.csv, motion_minutes.csv y
  pulse_daily_metrics.csv / pulse_activity_sessions.csv / pulse_profile.csv (primera línea "#pulseapp_… v1"). iOS Más → "Importar datos de Android"
  (`Core/AndroidImport.swift`): mezcla pulso (sin duplicar segundos, `HrLog.mergeImport/finishMerge`) y movimiento; días, actividades y perfil solo
  rellenan lo que falta. En la rama, `build.yml` también compila el APK en `ios-whoop-ui`.
- **Comunidad (17/10)**: equipos como WHOOP sobre **Supabase** (REST sin librerías). Script `supabase/comunidad.sql` (tablas profiles, teams,
  team_members, day_stats, messages + RLS: solo ves a gente de tus equipos; RPC create_team/join_team con código de 6). Probado en Postgres 16 +
  PostgREST 12 local. Cada móvil entra con cuenta ANÓNIMA (hay que activar "Allow anonymous sign-ins"). URL/clave: `CommunityConfig`
  (`BUILT_IN_URL/KEY` en Android `Community.kt`, `builtInUrl/Key` en iOS `Core/Community.swift`; proyecto del usuario neqnpiscmaslyymrmqws con clave publishable, puestas el 18/10; se acepta la URL con /rest/v1).
  Sube hoy+ayer (`CommunitySync`, máx. cada 10 min) al calcular Inicio. Pantallas: Android `CommunityActivity`/`TeamActivity` (pestaña "Equipos"),
  iOS `UI/CommunityScreens.swift`. Ganadores del lunes 17:00 = mensaje calculado en la app (`WeeklyWinners`, medias lun–dom), no hay cron.
- **Instalar en el iPhone sin Mac**: iloader (Windows, con iTunes de la web de Apple) → SideStore + LocalDevVPN; el .ipa se mete con "Import IPA".
  Certificado gratuito = 7 días (refresca SideStore o volver a "Import IPA"). Errores vistos: 502 anisette (cambiar servidor), SMS 2FA 403 (esperar),
  SideStore -80045 al iniciar sesión (cambiar servidor anisette en SideStore).

## Herramientas de comprobación (en el contenedor de Claude, no van en la app)
- Recursos: `/tmp/claude-0/rescheck/run.sh` (aapt2 de PyPI `aapt2==0.2.1` + stubs de Material3 → R.java real).
- Kotlin: `/tmp/claude-0/rescheck/kt.sh` (kotlinc + android.jar + stubs de /home/claude/check/stubs + coroutines).
- Dibujo de vistas a PNG: `/tmp/claude-0/shim` (clases android.graphics/View falsas sobre Java2D) + `h/Render.kt`.
