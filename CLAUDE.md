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
- **VERIFICAR DOS VECES SIEMPRE, sin que lo pida (26/10).** Antes de dar un resultado, una conclusión o un "ya está arreglado":
  1) comprobarlo con los datos reales; 2) volver a comprobarlo de OTRA forma (otro método, otra noche, el pipeline de la app,
  mirar el dato crudo, buscar el caso que lo contradiga). Si las dos no coinciden, no se afirma: se investiga. Comparar SIEMPRE
  con WHOOP y decir claramente si cuadra o no (no esperar a que el usuario lo note). Ya pasó varias veces que el usuario tuvo
  que señalar el fallo y al revisarlo salió mejor: posición de la pulsera (25/10), VFC de la noche 23→24, fases de la 25→26.
- **OBJETIVO DEL USUARIO (8/11)**: que TODO se parezca lo máximo a WHOOP, ±2–3 si es posible (recuperación, VFC, sueño, horas…). Las fases
  son secundarias pero también quiere mejorarlas. Ojo: a veces edita a mano la noche en WHOOP para probar (8/11: alargó el final de 09:53 a 10:08)
  → la referencia es la noche ORIGINAL (preguntar o usar sus capturas si la API tiene "updated_at" muy posterior a "created_at").
- **La IA de WHOOP (4/11)**: el usuario puede preguntar a la IA de la app de WHOOP. SIEMPRE que algo dependa de cómo calcula WHOOP
  (reglas internas, ventanas, qué datos usa) y no se pueda deducir de los datos, proponerle preguntas CONCRETAS para que se las haga
  (y luego comprobar su respuesta con los datos: no fiarse sin verificar, ver 23/10 y 26/10).
- **Nunca perder datos al actualizar**: cualquier cambio en Room = nueva versión + `Migration`.
- La app debe funcionar **siempre en segundo plano** (servicios en primer plano `connectedDevice`).
- Zona horaria: Europe/Madrid. Los CSV usan hora unix (UTC).

## Stack
Kotlin, minSdk 26, target/compile 34, Java 17. Room 2.6.1 con **KSP** (kapt no funciona).
`gradle.properties`: `android.useAndroidX=true`, `android.enableJetifier=false`, `org.gradle.jvmargs=-Xmx2048m`.
Archivos Gradle en **Groovy**. Usar `Locale.US` al escribir números en CSV. Trabajo pesado en `Dispatchers.IO`.
Base de datos: versión 10, migraciones 1→10 registradas en `AppDatabase.kt` (9 = fases de cada noche; 10 = whoopRecovery/whoopSleepScore/whoopConsistency/whoopSleepNeed de los días importados).

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
  al guardar una actividad con FC más alta (150–220 y ≤ +8 lpm sobre la actual) — DESDE EL 4/11 YA NO: solo se pone si no hay ninguna
  (WHOOP no la cambia con un entreno). `Formulas.init(ctx)` en Main y servicios.
  Zonas 0–5 por % FCmáx (<50, 50–60, 60–70, 70–80, 80–90, >90).
- Esfuerzo = TRIMP Banister con reserva de FC, sólo minutos con FC ≥ 45 % FCmáx → 4,14·ln(1+TRIMP/2,6), máx 21.
  Misma curva para día y actividades. Error vs WHOOP: fútbol 0,7, global 1,7 (173 entrenos).
- **Recuperación (30/10)** = 44,89 + 39,11·(ln VFC − EWMA14) − 0,4969·(FCR − EWMA14) + 37,54·Φ((ln VFC − media 30 noches)/sd 30), redondeo, 1–99;
  −12 por cada z>2 de respiración. El percentil (Φ) recoge que WHOOP satura en los extremos. 193 noches de WHOOP (export + API con decimales,
  scratchpad rec30/a–e.py; línea base como BaselineProvider): validación cruzada 4,67 → 3,92, ±5 puntos 66 % → 72 %; por tiempo (ajuste hasta 14/09,
  prueba 46 noches) 4,57 → 4,07; con la VFC/FCR de PulseApp 23→30/10 5,6 → 4,1 (30/10: 76 → 81, WHOOP 84). Kotlin = Python (check/n30/R.kt, 3,88).
  Probado y descartado: otras EWMA (7/10/21/30), ventanas 60/90, z-score, sigmoide (4,55), percentil de rango (4,0–4,2, más ruidoso), dV², VFC absoluta,
  y añadir calificación/eficiencia/regularidad/horas/respiración (≤ 0,07). `PersonalBaseline.lnHrvMean30` (≥ 7 noches; si no, media EWMA y sd 0,196).
  Antes (23/10): 64,28 + 89,74·(ln VFC − EWMA14 ln VFC) − 0,4625·(FCR − EWMA FCR), suelo.
  Ajustada con 199 noches (export + API): validación cruzada 4,8 (la sigmoide de antes 5,9; últimas 39 noches 4,3 vs 6,6).
  La EWMA de la línea base PARTE de 88 ms / 58,5 lpm (línea base de WHOOP el 14/10) y cada noche propia la mueve
  (antes empezaba en la 1.ª noche propia → base baja y recuperación +10–15). PulseApp 15→23/10: MAE 12,7 → 3,8. El sueño NO entra.
- Calificación sueño = 0,281·horas vs necesidad (máx 100) + 0,202·eficiencia + 0,288·regularidad + 19,6 (MAE 1,9).
  Es lo que muestra el anillo de Sueño del inicio. Regularidad = 100 − sd(hora de dormirse, 7 noches)/120·100.
- FC reposo = mediana de la ventana de sueño (cuadra con WHOOP: 58 vs 57, 59 vs 59).
- VFC (23/10, `NightMetrics`) = 0,07664 · m^1,6237, m = media del RMSSD de tramos de 2 min (≥60 RR, saltos >20 % fuera) de la ventana
  de sueño. NO depende de las fases (antes: tramos de profundo → 22→23 dio 87 vs WHOOP 97). 9 noches 15→23/10 con el código de la app:
  MAE 1,9 ms (máx 3,9), dejando una fuera 2,2; FCR (mediana) MAE 0,7. Arnés /home/claude/check/ftest9/V.kt.
  Al instalar: `DailyMetricsUpdater.recalcPastNightsOnce` (archivo `night_recalc_v1` / iOS `pulseapp_night_recalc`) rehace todos los días
  con pulso guardado; `NEW_METHOD_SINCE` = 2026-10-15.
  `BaselineProvider` solo usa VFC y respiración de días ≥ `NEW_METHOD_SINCE` para no mezclar escalas.
- Sueño (`SleepDetector`, ajustado 15/10 con la noche 14→15 vs WHOOP): 20:00–12:00, medias por minuto suavizadas 3 min,
  umbral 1,30 × media del 10 % más bajo, tolera 30 min por encima, hueco >10 min = desconexión, mínimo 90 min, la última
  ventana. Resultado: 23:20–07:24, 39 min despierto, 91 % (WHOOP 23:17–07:20, 42 min, 92 %). VFC de esa ventana ≈ 69 (WHOOP 69),
  FC reposo mediana 64 (WHOOP 64). Ciclo del día = desde que te duermes (o 00:00): esfuerzo y FC media solo de ese ciclo
  (antes usaba todo el archivo). `DailyMetricsUpdater` guarda la noche que TERMINA ese día (18:00 víspera → 14:00).
  `BaselineProvider` solo usa días con ≥ 3 h dormido. La media parte de 88 ms / 58,5 lpm (ver Recuperación).
- Necesidad de sueño = 470 min + 0,0386·strain^2,527 (30/10; antes max(0, strain−8)·6) + deuda. **Deuda (18/10, ajustada con 152 noches del export)** = max(0, (necesidad
  de esa noche − dormido) / 2) (`SleepPlanner.nextDebt`, MAE 1,5 min; la de antes ×0,7 sobre la base salía el doble). Sin dato esa noche: deuda/2.
  Hora de despertar editable (7:30 por defecto).
- **Regularidad (18/10, 145 noches del export)** = media de intersección/unión del tramo en cama de la última noche con cada una de las 3
  anteriores (eje desde las 12:00) × 100 − 7 (`Formulas.sleepConsistency(noches)`), MAE 4,9, 87 % a ±10. La de antes (sd de la hora de
  dormirse, 7 noches) tenía MAE 27. Ojo: esta semana WHOOP salió ~7 puntos por encima del export (92/89/64/76 vs J3 89/91/65/77 sin restar 7);
  revisar el −7 en la ronda grande.
- Calorías (30/10) = ritmo fuera de entrenos de WHOOP (1706/24 h, de tus días importados; si no, Mifflin) × (min transcurridos − min de actividades)/1440 + kcal de actividades (por zonas).
- VO2máx = 15,3 × FCmáx / FC reposo, se recalcula sólo los martes.
- **Estrés (5/11)**: un punto CADA MINUTO (IA de WHOOP), z = 4,029·(FC−FCRbase)/(FCmáx−FCRbase) + 0,307·ln(VFCbase/VFC) (base = la de
  BaselineProvider, EWMA ~14 días como dice WHOOP); estrés = 0,117 + 2,883·(1−e^(−max(z,0)^1,217)). Ajustado con el reparto diario de WHOOP
  (14 días, 21/10→4/11): error medio 6,5 → 4,2 puntos de % (sin actividad 11/15/4 → 7/6/3, sesgo del medio +15 → +2); dejando un día fuera 4,7;
  una semana → la otra 6,0 → 4,7 y 5,5 → 5,4. Código real (check/st05/SD2.kt, línea base de 14 días de WHOOP) = Python. Solo 1 min con 5 min
  y la curva de antes ya daba 5,4. StressBreakdown cuenta 1 min por punto; stress_days.csv v2.
- Estrés (23/10, SUSTITUIDO el 5/11): ventanas de 5 min, z = 3,4·(FC−FCRbase)/(FCmáx−FCRbase) + 0,2·ln(VFCbase/VFC); estrés = 0,3 + 2,7·(1−e^(−max(z,0))).
  Ajustado con la curva de WHOOP digitalizada de la captura (22/10 21:38 → 23/10 09:32, 135 ventanas): MAE 0,34 → 0,15. Estrés del sueño
  (alto/medio): 18/10 0/25 (WHOOP 0/25), 19/10 0/10 (0/10), 20/10 0/115 (25/104), 15/10 0/190 (~24/~200), 23/10 0/40 (alto 0 %).
  Gráfica: eje = últimas 24 h, se corta en huecos >15 min.
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
  de la necesidad (como `need_from_recent_nap` de WHOOP). Sin movimiento grabado no se detectan siestas. Por validar con una siesta real.
  Validado 21/10 con hr_log_19 + motion_minutes_7 (arnés /home/claude/check/ftest8/N.kt): sofá 20/10 20:20–22:05 (giro 3–10, solo ratos
  quietos sueltos) y reunión 21/10 9:30–11:29 (giro mediano 6,5, FC 65) → NINGÚN tramo quieto ≥20 min, no salen como siesta. Con todo el
  código nuevo: a las 23:00 del 20/10 la noche mostrada es 19→20 23:12–07:30 (no el sofá) y a las 13:30 del 21/10 es 23:11–07:37, 8:02 (WHOOP 8:02).

- **RONDA GRANDE de fases (22/10, 7 noches con movimiento 16→22/10)**: 21→22 WHOOP (API) 23:13–07:18, 39/273/112/63, VFC 85,2, FCR 56,
  resp 13,4, calificación 91, regularidad 88, recuperación 54; PulseApp iPhone 23:22–07:17, 31/360/61/23 (REM 23!), VFC 96, rec. 70.
  Ajuste conjunto con /home/claude/check/tune (copia de SleepStager con parámetros variables + búsqueda en rejilla, VFC con NightMetrics):
  LOCAL_WINDOW 91→61, DEEP_HRV 0→−0,05, DEEP_HRV_SLOPE 0,3→0, DEEP_HR −0,5, REM_HRV −0,2→−0,1, REM_HRV_SLOPE 0,4→0,3, REM_HR 0→−1.
  Error medio (7 noches): ligero 34→14 min, profundo 21→16, REM 28→13, VFC 4,3→4,3 ms. 21→22 ahora 31/284/91/69, VFC 91 (WHOOP 85).
  Por noche (P vs W): 16 34/245/93/78 vs 33/240/126/52 · 17 23/249/91/114 vs 15/206/126/131 · 18 35/250/109/89 vs 28/243/107/100 ·
  19 38/273/109/131 vs 37/271/111/132 · 20 52/271/90/85 vs 31/292/101/74 · 21 24/270/103/109 vs 23/259/98/126 · 22 31/284/91/69 vs 39/273/112/63.
- **RONDA de esfuerzo (22/10)**: con los 10 entrenos de la API (zonas exactas) WHOOP da mucho menos a los ratos largos en zona 0–1 (pickleball 8,7,
  fútbol 21/10 8,8) y SUMA carga muscular a funcional/fuerza ("cardio 50 % / muscular 50 %"). Nueva curva (Android + iOS): carga = Σ min·r·e^(8,41·r),
  r = reserva de FC, sin umbral; esfuerzo = 1,47·ln(1+carga/4,97) + 2,72 si `Formulas.isStrength(tipo)` (funcional/fuerza/crossfit/gimnasio/pesas).
  Error medio con zonas de la API 3,5 → 0,7 (1,4 dejando uno fuera). Segundo a segundo (ventanas de WHOOP): func 19/10 12,6 (11,5), func 20/10 13,3
  (12,6), func 21/10 10,6 (11,1), fútbol 21/10 9,7 (8,8; antes 13,4). Día (bono si hubo fuerza ese día, en HomeData y DailyMetricsUpdater):
  20/10 13,3 (12,7), 21/10 12,8 (13,3). Las actividades "Sin clasificar" NO llevan el bono hasta ponerles el deporte. `act_recalc` = 2 rehace todo.
  Los días ya guardados conservan el esfuerzo antiguo.
- **Esfuerzo v2 (22/10, tras la queja del usuario: el bono fijo dejaba func 19 y 20/10 PEOR que antes)**: la carga muscular entra en la misma curva,
  proporcional a la duración: esfuerzo = 2,014·ln(1 + (carga + 50·min de fuerza)/10,418), carga = Σ min·r·e^(6,694·r). Comparado con la fórmula
  de antes, TODOS los entrenos quedan mejor o igual: func 19/10 11,6 (WHOOP 11,5; antes 11,7) · func 20/10 12,0 (12,6; 11,9) · func 21/10 11,4
  (11,1; 10,4) · fútbol 21/10 9,8 (8,8; 13,4) · fútbol 14/10 11,9 (12,6; 14,6) · fútbol 15/10 10,3 (9,6; 13,4) · fútbol 19/10 12,2 (12,8; 15,4) ·
  func 15/10 manual 11,9 (12,1; 11,3) · pickleball 9,3 (8,7; 13,9) · paseo 3,3 (4,1; 5,2). Error medio 2,2 → 0,56 (dejando uno fuera 0,94).
  Día: `Formulas.addStrength(esfuerzo, minutos de fuerza del día)`; 20/10 12,1 (12,65), 21/10 12,2 (13,3). `act_recalc` = 3.
  El "50" topa en el límite de la búsqueda: con solo 4 funcionales no se puede separar bien; revisar con más entrenos.
- Detección: inicio = primer minuto del tramo elevado (≥26 % reserva). Funcional 21/10 → 18:27:00–19:17:59 y zonas 23:25/26:39/0:53, EXACTO a WHOOP
  (18:27–19:17, 23:24/26:42/0:53); 19/10 y 20/10 siguen exactos. Fútbol 21/10: WHOOP 20:19–22:07 (incluye 20 min de espera con pulso 70–80 y sin
  movimiento grabado), PulseApp 20:42–22:03; kcal 432 vs 421.
- Archivos que hacen falta cada día: SOLO hr_log.csv y motion_minutes.csv (WHOOP sale de la API). service_log solo si hay problemas de conexión.

- **22→23 (8.ª referencia, fútbol 22:02–23:30 la víspera)**: WHOOP 00:29–08:05, 24/245/102/84, VFC 97,4, FCR 57, resp 13,2, recuperación 70,
  calificación 83 (77/78/96/0). PulseApp (versión del 22/10): 00:30–08:05, 31/276/78/70, VFC 87, FCR 57, resp 12,3, recuperación 58, calificación 80.
  Arreglado (23/10): VFC 95,5, recuperación ≈71–72, estrés (ver Fórmulas). Fases: profundo −24 (pendiente). Reajustar fases con 8 noches no
  mejora todo a la vez (lo mejor: L 11,5/D 17,9/R 16,8 vs actual 16,4/16,6/12,9) → no se toca; hace falta un cambio de estructura.
- **Esfuerzo 22/10 (pendiente de ronda)**: funcional 18:07–18:42 WHOOP 8,6 (zonas 0–1) → PulseApp 10,5 como funcional; fútbol 22:02–23:30 WHOOP 15,1
  → 13,8; día WHOOP 16,25 → 14,2; mañana 23/10 00:29–08:06 WHOOP 2,6 → 1,9. Candidata: carga = Σ min·(r·e^(4,886 r) + 0,1134),
  esfuerzo = 4,932·ln(1 + (carga + 12,12·min fuerza)/95,6): 13 de 14 casos mejor (MAE 0,83 → 0,40), pero el paseo 17/10 (solo por zonas) baja
  3,3 → 1,2 (WHOOP 4,1). No se aplica hasta tener paseos/actividad suave con pulso segundo a segundo. Script scratchpad v/str5.py.

- **Método de VFC que describe la IA de WHOOP (23/10)**: media ponderada de varios tramos de SWS con más peso al último. Probado con
  NUESTRAS fases (arnés ftest9/W.kt, 9 noches): profundo ponderado MAE 4,5 calibrado (6,2 dejando una fuera), último SWS 6,4, ×2/×3 al último
  5,4/6,4, tramos más estables 2,9–3,3 → todos peores que el método actual (media de tramos de 2 min, 1,9 / 2,4). Nuestras fases no
  coinciden minuto a minuto con las de WHOOP; revisar cuando las fases estén afinadas.
- **Importar historial de WHOOP (23/10, Android `WhoopImport.kt` + iOS `Core/WhoopImport.swift`, Más → "Importar historial de WHOOP")**:
  zip del export (lector de zip propio en iOS con Compression) o CSV sueltos. Ciclo con noche → fila del día de la vigilia (hasta AYER), con
  VFC/FCR/sueño/fases/resp/esfuerzo/kcal + notas oficiales (recuperación, calificación, regularidad, necesidad) que HomeData muestra tal cual
  en esos días. Entrenos (zonas por %) y siestas → actividades; WHOOP manda en solapes. Copia de lo sustituido en whoop_import_backup_*.csv/json.
  `whoop_import_until` (prefs) → `BaselineProvider.sameScale` cuenta esos días; recalcAllOnce de actividades y el recálculo de noches no los
  tocan. Export del 23/10: 199 días (07/04 → 22/10), 246 entrenos, 21 siestas. Con ese historial la línea base es VFC 88 / FCR 57,6 y la
  noche 22→23 daría 71 (WHOOP 70).

- **Hipnograma de WHOOP minuto a minuto (23/10)**: en la app de WHOOP, Sueño → "El sueño de anoche" muestra 4 barras (despierto/ligero/
  profundo/REM) sobre el tiempo en cama. Se leen de las capturas (pista x = 64…764 en 828 px de ancho, o ×ancho/828; tramo sólido = máx canal >100;
  inicio/fin en cama de get_sleeps). Validado con las horas que leyó el usuario a mano (±1 min). Datos de 8 noches 16→23/10 en
  /home/claude/check/hyp (lab.pkl = etiqueta WHOOP por minuto; scripts dig*.py, feat*.py, model*.py).
  - Método actual de fases: solo 49 % de minutos en la misma fase que WHOOP; del profundo de WHOOP acierta ~20–40 %. WHOOP pone el profundo en
    las primeras 3–4 h y el REM al final; PulseApp ponía profundo a las 5–7 h. Rasgos que separan (medias): profundo = pulso muy estable
    (sd 2,1 vs 3,6 ligero), 118 min sin moverse, progreso 0,23; REM = pulso +3,3 sobre la mediana local, ln RMSSD −0,25, poco después de moverse.
  - **APLICADO (23/10, a petición del usuario: el REM solo es visual)**: `SleepModel.kt` / `Core/SleepModel.swift` + `sleep_model.json`
    (Android `app/src/main/resources`, iOS `Resources`). `SleepStager.stage` usa el modelo para ligero/profundo/REM y las REGLAS de antes
    para despierto (las capturas pierden los despertares de 1 px: el modelo solo daba 3–4 despertares). Kotlin = Python en 3903/3903 minutos
    (ftest11/P.kt); Swift se comprueba en CI (`ios/Tests/main.swift`, paso "Comprobar el modelo de fases"). Dentro de muestra con el pipeline
    de la app: 16 34/234/129/53 (W 33/240/126/52) · 17 23/197/116/141 (15/206/126/131) · 18 35/258/89/101 · 19 38/278/104/131 · 20 52/278/95/73
    · 21 24/262/99/121 · 22 31/260/120/64 · 23 31/248/97/79 (W 24/245/102/84). Si no carga el modelo, vuelven las reglas.
    Reentrenar con más noches: check/hyp (dig2.py para leer capturas, lab.py, feat*.py, final.py exporta el modelo y ref_out.json).
  - Candidato (aplicado arriba): árboles (HistGradientBoosting 150×prof. 3, 17 rasgos de pulso/VFC/movimiento/tiempo) + Viterbi (permanencia 0,9)
    + sesgo por fase; validación dejando cada noche fuera: acuerdo 81 % (actual 49 %), MAE totales D/L/P/R 8,8/18,2/16,6/22,6 frente a
    12,4/14,9/18,0/12,2 del actual (ajustado SOBRE esas noches). REM total peor (noches 16 y 18: +42/+34) → no se aplica hasta mejorar el REM
    con más noches etiquetadas.
  - VFC con las fases EXACTAS de WHOOP: último profundo sin calibrar MAE 9,8; profundo ponderado calibrado (dejando una fuera) 1,9 = igual que el
    método actual. Conclusión: la VFC actual ya está al nivel posible con nuestros RR; la diferencia restante viene del reprocesado de WHOOP en la nube.

- **23→24 (9.ª referencia, noche larga 23:47–11:03, en cama 11:15)**: WHOOP dormido 10:57, 18/418/107/132, 9 despert., 97 %, VFC 91,9, FCR 57,
  resp 13,2, calificación 83 (100/58/97/0), recuperación 60. PulseApp (versión 23/10): 00:02–11:13, 10:37, 34/417/63/157, VFC 101 (+13,9 % sobre
  88,7), FCR 57, resp 12,9, calificación 83 (100/57/94/0), recuperación 76.
  **Cambios 24/10 (Android + iOS):**
  - VFC = media ponderada del RMSSD de los tramos de PROFUNDO (≥5 min) de las fases del modelo → 7,9966·p^0,55945 (NightMetrics.deepHrv);
    sin fases o <10 min de profundo → método de toda la noche. 9 noches con fases del modelo entrenado SIN esa noche: MAE 1,5 (toda la noche:
    3,3; con 9 noches la noche larga 24 daba +9). Con el pipeline de la app (10 noches): MAE 1,52, 24 → 94 (WHOOP 92). Con las fases EXACTAS de
    WHOOP: 1,7. Recálculo de noches v2 (`night_recalc_v2` / iOS 2) que ya NO toca los días importados de WHOOP (antes el import lo bloqueaba).
  - Modelo de fases reentrenado con 9 noches (sesgo 1,5/0/−0,3/0,3). Validación dejando fuera: 24 72 % (profundo 74/110), resto 77–90 %.
  - Inicio: ONSET_RUN y tramo quieto previo 15 → 10 min. 24 empieza 23:48 (WHOOP 23:47); las otras 8 noches salen igual.
  - Recuperación con los valores EXACTOS de WHOOP del 24: la fórmula da 67 (WHOOP 60); 22/10 61 (54), 23/10 73 (70). Probado añadir
    respiración, calificación, horas, temperatura, SpO2, esfuerzo de ayer: nada mejora (CV 4,84–4,91). Error propio de la fórmula ±5–7.

- **Esfuerzo v3 APLICADO (24/10, a petición del usuario antes del partido)**: carga/min = r·e^(5,0047 r) + 0,0951, esfuerzo =
  4,2522·ln(1 + (carga + 13,206·min fuerza)/68,867), máx 21 (`Formulas.trimp/strainFromTrimp`, Android + iOS). 15 casos: MAE 0,35, dejando
  uno fuera 0,50; fútbol 23/10 7,6 (WHOOP 7,6; antes 8,9). Paseo 17/10 (por zonas) 1,4 vs 4,1 → revisar con un paseo grabado.
  `act_recalc` = 4 rehace las actividades (no las importadas); `night_recalc_v3` / iOS 3 rehace los días medidos por PulseApp.

- **24→25 (10.ª referencia, fútbol 19:02–21:08 esfuerzo 18,4 + 2 paseos la víspera, CAMBIO DE HORA)**: WHOOP (API) 23:54:27Z–08:47:39Z
  (01:54 CEST–09:47 CET), cama 8:53, 23/303/133/75, 11 despertares, 96 %, VFC 70,6, FCR 61, resp 13,4, calificación 81 (96/57/96/0),
  recuperación 37. PulseApp iPhone (versión 24/10): 01:54–09:48, 15/297/135/87, 97 %, VFC 86, FCR 61, resp 12,9, calificación 82, rec. 59.
  **Cambio de hora**: la hora 02:00–03:00 se escribió dos veces seguidas (líneas 553719–557319 verano, 557320–560919 invierno) y al leer
  se quedaba solo la 1.ª pasada → se perdía 1 h de la noche. **Arreglo (25/10, Android `HrTime.kt` + iOS `TimeUtil.logTimestamp/lineMillis`)**:
  a menos de 2 h de un cambio de hora se escribe el desfase ("2026-10-25T02:30:00+01:00"); todos los lectores lo respetan (sin él, hora
  local como siempre). Una vez al arrancar (`DataStore.repairDstOnce` / `HrLog.repairDstOnce`, marca `dst_repair_v1`): en la hora repetida
  sin desfase, cuando la hora vuelve atrás ≥30 min empieza la 2.ª pasada → se reescriben esas líneas con su desfase (copia en
  hr_log_antes_cambio_hora.csv). Probado con el archivo real: 7200 líneas marcadas, las 590 806 horas iguales a la corrección a mano.
  CI de iOS: paso "Comprobar el cambio de hora" (`ios/Tests/dst/main.swift`). Arnés: check/dst/T.kt; archivo arreglado check/dst/hr_log.csv.
  **VFC (25/10)** = media de los dos métodos (profundo y toda la noche). 25: profundo 86→(arreglado) 82, toda la noche 66, WHOOP 71 → 74.
  11 noches con el pipeline de la app: MAE 2,4 → 1,6 (máx 5,3, la noche larga 24: 97 vs 92). `night_recalc_v4` / iOS 4.
  **Esfuerzo v4 (25/10)**: con los 2 paseos del 24/10 segundo a segundo (WHOOP 4,85 y 4,61 casi todo zona 0; v3 daba 2,8/2,4) →
  carga por minuto propia para paseos: `Formulas.muscleMinutes(tipo, min)` = fuerza min, paseo min·4,38/14,61. Constantes 4,530 / 90,43 /
  5,162 / base 0,1209 / fuerza 14,61 / paseo 4,383. 18 casos: MAE 0,57 → 0,21 (LOO 0,46); fútbol 24/10 18,4 (WHOOP 18,4). Solo si la
  actividad es "Caminar"/"Paseo". `act_recalc` = 5. Script scratchpad v7/str7.py.
  **Fases como WHOOP en Sueño (25/10)**: tocar una fase la marca (círculo relleno), su barra muestra dónde cae en la noche y la gráfica de
  pulso se pinta de su color en esos tramos; "Rango típico" cambia a las barras de totales. Las fases de cada noche se guardan en
  sleep_stages.csv (`SleepStagesStore`, al calcular cada día; el recálculo v4 rellena las noches pasadas). Capturas de WHOOP de la noche
  25 en check/hyp/n25 (para reentrenar fases).

- **Detección de actividades 25/10 (fútbol 24/10 cortado)**: PulseApp guardó "Sin clasificar" 19:02–19:25 (WHOOP fútbol 19:02–21:07), una
  "siesta" 10:47–11:12 (era el final de la noche) y no vio los 2 paseos. Causas y arreglos (Android `Formulas`/`AutoActivityScanner`, iOS igual):
  1. El pulso del partido llegó tarde (historial) → el escáner vio un hueco, lo dio por terminado y luego no se solapa → nunca se alargaba.
     Ahora: hacen falta ≥ 5 min de pulso en los 10 min siguientes al fin (o ≥ 1 h); y una automática NO editada que la detección encuentra
     más larga se alarga (unión). Editar las horas quita la marca automática.
  2. Con todo el pulso, el fin salía 21:48 (la regla de "vuelve a subir" seguía en los paseos). Con movimiento: ≥ 10 min quieto (< 10 pasos,
     giro < 40) tras el último minuto intenso = fin → 21:07. Los otros 7 entrenos con datos salen igual.
  3. Paseos (`detectWalks`): minuto ≥ 30 pasos, pausas ≤ 10 min, ≥ 12 min, ≥ 8 min andando, ≥ 40 pasos/min, FC media ≥ 26 % reserva → tipo
     "Caminar". 14–25/10: solo los dos de WHOOP (21:26–21:48, 22:20–22:50); el paseo de 92 min a FC 86 y la vuelta a casa (FC 97) no.
  4. Siesta: si en las 3 h de antes hay < 5 min andando (con ≥ 60 % de movimiento grabado) es el final de la noche, no siesta.
  Una vez al instalar (`act_rescan` 1 / iOS `pulseapp_act_rescan`): se repasan 7 días (alarga el fútbol, añade paseos, borra la siesta falsa).
  Sin detectar aún: funcional 22/10 (WHOOP 18:07–18:41, solo 3 min intensos). Arnés check/act25 (D2.kt, proto.py).

- **25→26 (11.ª referencia, domingo tranquilo, primera noche en horario de invierno)**: WHOOP (API) 22:42:53–07:17:06, cama 8:34,
  28/325/106/56, 7 despertares, 95 %, VFC 109,4, FCR 56, resp 13,4, calificación 85 (100/66/95/0), recuperación 90 (medias WHOOP 30 d:
  VFC 92, FCR 58). PulseApp iPhone: 22:43–07:24, 38/332/73/78, 92 %, VFC 111 (+26 % sobre 88), FCR 56, resp 13,5, calificación 81
  (100/54/92/0), recuperación 86.
  **Regularidad 54 vs 66 → WHOOP la mide SIN el cambio de hora** (check/reg/r.py, con las horas de WHOOP de 12 noches: en hora local
  26 da 54 = PulseApp; en hora "de invierno" fija 67; error medio 4,7 → 3,5 con el −7). `Formulas.standardNight(fecha, ini, fin)` (Android
  + iOS) pasa cada noche a hora de invierno (en verano −1 h) antes de `sleepConsistency`. Con las horas de PulseApp la 26 sale 67.
  **Fases**: modelo reentrenado con 11 noches (25 y 26 leídas de las capturas, check/hyp/dig26.py; tiempo continuo UTC+2 en raw.pkl,
  feat_new.py). Validación dejando fuera: acuerdo 79,8 %, MAE D/L/P/R 10/23/15/18. App: 26 → 38/321/93/69 (antes 38/332/73/78; W 28/325/106/56).
  Kotlin = Python 5627/5627 minutos (ftest11/P.kt con check/n26/hr_fixed2.csv). VFC 12 noches MAE 1,6, FCR 0,5. `night_recalc_v5` / iOS 5.
  **Fin de la noche** 07:24 vs 07:17 (tumbado quieto despierto con giros sueltos): probado exigir ratos quietos más largos para alargar
  (check/endt/E.kt) → empeora el resto (MAE 2,1 → 2,6–3,7); se deja. Fallan solo las mañanas remoloneando (24: +10, 26: +7).
  **Recuperación** 86 vs 90: con los valores exactos de WHOOP la fórmula da 85 → error propio de la fórmula (±5). La calificación del sueño
  NO entra (probado 23–24/10 con 199 noches: no mejora). iOS: fila "Calificación del sueño" en Recuperación (solo informativa).
- **Respuesta de la IA de WHOOP sobre la recuperación (26/10), comprobada con 189 noches (export 23/10 + API hasta 26/10)**:
  dice que entran VFC y FCR (pilares) frente a una línea base de ~30 días, más horas vs necesidad, calidad del sueño, respiración,
  temperatura, SpO2; no da pesos. Prueba (scratchpad rec26/t.py y t2.py, validación cruzada 10 partes): línea base EWMA14 4,79 ·
  media 30 d 5,53 · EWMA30 5,76 · mediana 30 d 5,80 → la de 30 días es PEOR. Añadir cada dato a la fórmula: horas/necesidad 4,75,
  calificación 4,87, eficiencia 4,81, regularidad 4,84, %profundo 4,90, respiración 4,85, temperatura 4,91, SpO2 4,94 (nada mejora
  más de 0,04). Segunda comprobación con árboles: solo VFC+FCR 5,23, con todo 5,10; correlación del error con cada dato |r| ≤ 0,13.
  Conclusión: con los datos que WHOOP da, lo demás no explica el error de ±5; la fórmula NO se cambia.
- **26→27 (12.ª referencia, fútbol suave 21:06–22:02 la víspera, WHOOP 5,7)**: WHOOP (API) 22:37:42Z–06:57:57Z (23:37–07:57), cama 8:20,
  dormido 7:41, 38/226/99/137, 9 despertares, 93 %, VFC 106,6, FCR 54, resp 13,4, calificación 87 (97/74/93/0), recuperación 87.
  PulseApp iPhone (versión 26/10): 23:38–07:57, cama 8:19, 7:49, 30/295/102/72, 93 %, VFC 109, FCR 55, resp 13,5, calificación 85
  (98/68/93/0), recuperación 82. **REM −65 / ligero +70**: los tramos de REM caen en el MISMO sitio que los de WHOOP pero mucho más
  cortos (capturas en check/hyp/n27, para la ronda de fases). Profundo bien colocado y 102 vs 99.
  Comprobado 2 veces: con las horas de WHOOP nuestra regularidad da 68 (= app) y con su VFC/FCR la recuperación 81 → son las fórmulas.
  Fútbol 26/10 NO detectado: casi todo a 95–120 lpm, solo 5–8 min ≥ 50 % de reserva (127) → mismo caso que el funcional del 22/10.
  **Esfuerzo del día (27/10, Android + iOS)**: la base por minuto de la v4 (0,1209, ajustada solo con entrenos) se sumaba a TODO el día:
  la noche 26→27 daba 2,8 (WHOOP 0,2) y la app marcaba 3,9 a las 9:35 (WHOOP 0,1). Ahora `strainOf` (día) va sin base y
  `addStrength(esfuerzo, fuerza, minActividades)` suma la base solo por los minutos de actividades (`activityLoadMinutes`, sin siestas).
  Las actividades sueltas NO cambian. 7 días con pulso completo (código real de la app, check/strain27/Z.kt): error medio 1,78 → 0,73;
  21/10 13,8 (13,3) · 22 16,8 (16,3) · 23 9,2 (7,8) · 24 19,1 (18,8) · 25 4,3 (4,1) · 26 7,5 (5,9; sin el fútbol detectado) · noche 27 0,7 (0,2).
  Ningún día empeora. `night_recalc_v6` / iOS 6 rehace los días guardados.
- **27→28 (13.ª referencia, funcional 18:18–18:53 + pádel 20:35–22:10 la víspera)**: WHOOP (API) 21:38:47Z–05:59:48Z (22:38–06:59), cama 8:21,
  dormido 7:50, 30/290/108/73, 10 despertares, 96 %, VFC 89,2, FCR 59, resp 13,4, calificación 85 (93/74/96/1), recuperación 63.
  PulseApp iPhone: 22:39–07:00, 7:54, 27/298/75/101, 94 %, VFC 90, FCR 59, resp 13,5, calificación 84 (92/69/94/0), recuperación 60.
  **Profundo −33**: faltan los tramos cortos de profundo entre 00:00 y 02:40 (y uno de 4:17–4:19). Capturas en check/hyp/n28.
  Con los datos exactos de WHOOP: recuperación 60 (= app) y regularidad 70 → fórmulas.
  **Regularidad −7 revisado (28/10)**: 197 noches del export → −7 sigue siendo lo mejor (MAE 5,33; −3: 6,25); últimas 30 → −4 (4,29 vs 4,99);
  11 noches API → −3 (2,2 vs 3,8). Contradictorio → NO se cambia; revisar con más noches (¿WHOOP cambió algo en octubre?).
  **Día 27/10**: pasos WHOOP 13 653 / PulseApp 16 372 (+20 %; pádel 4299 pasos = 45/min, funcional 1167 → falta saber cuántos cuenta WHOOP en
  cada actividad); kcal 2303 / 2450 (el ciclo de WHOOP dura 23 h y el día de PulseApp 24 h, y el funcional 14 min más largo); esfuerzo 14,0 /
  15,1 = versión antigua con la actividad marcada como Funcional 50 min (reproducido exacto con el código); con la nueva 14,8 (con la ventana de
  WHOOP 14,4).
  **Actividades suaves (28/10, Android + iOS)**: `Formulas.detectSoftActivities` (media móvil 5 min ≥ 28 % de reserva, huecos ≤ 5, ≥ 15 min,
  media ≥ 30 %, ≥ 80 % con pulso), DESPUÉS de detectActivities y detectWalks (solo lo que no se solapa). 14 entrenos de WHOOP con pulso
  (15→27/10): ahora los 14 detectados (antes faltaban funcional 22/10 y fútbol 26/10), 0 falsos positivos en 14 días; funcional 22/10
  18:07–18:42 (W 18:07–18:41), fútbol 26/10 21:06–22:14 (W 21:06–22:01). Margen: lo más parecido que no es entreno tiene media 95 lpm (umbral 100).
  Código real = Python (check/act25/D3.kt; scratchpad d28/soft.py). `act_rescan` 2 / iOS 2: repasa 10 días al instalar.
  **Pasos 27/10 corregido (28/10)**: WHOOP en el pádel 5031 (PulseApp 4299, MENOS); en la noche+mañana hasta 08:01 WHOOP 819 (P 198) y en la
  noche 27→28 hasta 07:14 WHOOP 995 (P 508) → donde hay dato de WHOOP, PulseApp cuenta de menos. El exceso está en el día 08:01–20:35 sin
  deporte: P ≈ 11 800 vs W ≈ 7800 (+52 %): 4033 en rachas ≥ 3 min andando, 1639 en ratos de 1–2 min, 1665 en minutos < 30 pasos (78 % con
  giro < 60). Sin minutos repetidos en motion_minutes. 26/10: P 6092 vs W 7704 (fútbol 56 min sin movimiento grabado). 25/10 1,02.
  Contradictorio con 1 día → NO se toca el contador; falta saber qué hizo el 27/10 de día y más días con los pasos de WHOOP.
  Horario del 27/10 (usuario): oficina+andar 08–11 (2185 pasos), coche 11:00–11:30 (383), reunión 12–13 (279), de pie en una escalera
  con las manos (atornillar, conectar) 13–15 (2444), coche 15:00–15:30 (496), tumbado 16:00–16:20 (33), escritorio 16:20–17:30 (65),
  coche 17:40–18:00 (266). En los trayectos los minutos fuertes son al principio/fin (andar al coche) pero EN MITAD del trayecto salen
  ráfagas de 8–47 pasos/min (≈ 100–200 por trayecto) = falsos (volante/baches). Escalera: 33 min ≥ 30 pasos con trabajo de manos → probable
  parte falsa. Pero WHOOP cuenta MÁS en las mañanas (ratos cortos reales) → subir la racha mínima quitaría también pasos buenos.
  Siguiente paso: grabación de prueba (imu_prueba) conduciendo y haciendo trabajo de manos, con los pasos de WHOOP antes/después.
- **28→29 (14.ª referencia, fútbol 20:41–22:05 la víspera)**: WHOOP (API) 22:11:49Z–07:24:22Z (23:11–08:24), cama 9:12, dormido 8:45,
  27/308/110/109, 13 despertares, 97 %, VFC 91,1, FCR 58, resp 13,7, calificación 90 (100/78/97/0), recuperación 66.
  PulseApp iPhone: 23:16–08:24, cama 9:08, 8:41, 27/329/98/94, 95 %, VFC 92, FCR 58, resp 13,5, calificación 89 (100/78/95/0),
  recuperación 63 (con los datos exactos de WHOOP la fórmula da 63 → fórmula). Fases ±12–21. Capturas en check/hyp/n29.
  **Día 28/10**: WHOOP 13 046 pasos / 2177 kcal / 12,1; PulseApp 11 584 / 2226 / 12,4. Fútbol WHOOP 20:41–22:05, 11,7, 4740 pasos, 507 kcal,
  zonas 31:03/30:05/11:15/8:30/4:04; PulseApp 20:41–22:19, 11,8, 658 pasos, 584 kcal, 35:11/39:54/10:57/8:48/4:05.
  - Pasos: 0 minutos de movimiento grabado durante el partido (el móvil no estaba cerca: el pulso llega luego del historial de la
    pulsera, el movimiento NO). Los 658 son de después. Pendiente: buscar si el historial de la pulsera trae pasos/IMU (v26 sin descifrar).
  - Final 22:19 vs 22:05: la regla de "el pulso vuelve a subir" lo alarga al andar (104→112). Reprobado con 15 entrenos: sin esa regla
    o con 8 lpm mejora este y el funcional 27/10 pero empeora 20/10, 21/10 y 24/10; dejando uno fuera 1182 vs 1155 → no se toca.
  - Zonas con la ventana de WHOOP y FCR 59: 31:03/30:06/11:15/8:30/4:05 = WHOOP al segundo. Con FCR 58 (la automática de PulseApp)
    111/141/154 → 29:31/31:38/10:57/8:48. WHOOP fija la FCR de referencia cada cierto tiempo (19/10: 59 = media de 7 o 14 días, no 30).
  **Nuevo (29/10, Android + iOS)**: (1) "FC en reposo para zonas" opcional en Sobre mí (`Formulas.setManualZoneRestingHr`, prefs
  `rhr_zone_manual` / iOS `pulseapp_rhr_zone_manual`; vacía = automática; cambiarla rehace las actividades). zoneBounds y la detección
  usan `zoneRestingHr()` (manual si existe). (2) Zonas seleccionables en el detalle de actividad, como las fases del sueño: tocar una zona
  la marca, su barra muestra cuándo estuviste en ella (StageTimelineBar con la zona de cada tramo de 10 s) y la gráfica de pulso se pinta
  de su color en esos tramos (segundos seguidos, huecos ≤ 5 s). Comprobado con el fútbol 28/10: los tramos suman exactamente el tiempo de
  cada zona.
- **Deporte automático (29/10, Android + iOS)**: `Formulas.guessSport(sesión, historial)`: las 5 actividades con deporte más parecidas
  (hora del día, día de la semana, log duración, FC máx, % por zona; pesos 0,5·h² + 1·otro día + 1·Δln dur² + 0,5·(ΔFCmáx/10)² +
  0,5·Σ(Δ%zona/20)²); decide si ≥ 4 de 5 coinciden. Historial = tus actividades con deporte (importadas de WHOOP + puestas por ti; no
  "Sin clasificar"/Siesta/Otro). Se aplica al guardar una automática "Sin clasificar" (se rehace el esfuerzo con el deporte) y una vez
  (`act_classify` 1 / iOS `pulseapp_act_classify`) a las automáticas sin clasificar de 30 días. Validación con los 213 entrenos del export
  usando solo los anteriores (scratchpad cls/c.py; código real check/sport/S.kt): fútbol 66/69 bien, funcional 48/64 (fallos sobre todo
  fuerza), pádel 2/3; últimos 60: 38 bien / 4 mal / 18 sin decidir. Pádel/pickleball casi nunca (se parecen al fútbol): quedan sin clasificar.
- **Diseño WHOOP de Recuperación y Sobre mí (29/10, Android + iOS)**: Recuperación (Android `RecoveryDetailActivity` reescrita sobre
  activity_sleep_detail; iOS `UI/RecoveryScreen.swift` `RecoveryDetailView`, ruta `.recovery(dayOffset)`): anillo grande PULSE, tarjeta
  VFC / FCR / respiración / calificación con valor, flecha y media de 30 días, leyenda "Hoy vs. los últimos 30 días", "Cómo se calcula"
  (VFC y FCR frente a tu media, hoy) y barras de recuperación de la semana; abre el día elegido en Inicio. Sobre mí: fondo/tarjetas WHOOP,
  títulos en mayúsculas, "Tus datos" y "Ajustes de FC" (FC máxima, FC en reposo para zonas y rangos de zona por RESERVA, antes salían
  por % de FC máx).
  **Finales**: probado ajustar la regla de final (umbral, tolerancia, subida, quietud): dentro de muestra 142 → 105 min de error, pero dejando
  un entreno fuera EMPEORA (1141 → 1168) → no se toca. Los finales de WHOOP no siguen un patrón (22/10 alarga 15 min sentado; 26/10 corta al andar).

- **29→30 (15.ª referencia, funcional 18:00–19:00 manual + pádel 20:36–21:56 la víspera)**: WHOOP (API) 21:59:57Z–06:52:28Z (22:59–07:52), cama 8:52,
  dormido 8:20, 32/324/85/92, 15 despertares, 95 %, VFC 102,5, FCR 56, resp 13,2, calificación 96 (100/86/95/0), recuperación 84, esfuerzo 0,2 a las 07:07.
  PulseApp iPhone: 23:00–07:52, 8:05, 47/272/111/102, 17 desp., 91 %, VFC 105, FCR 56, resp 12,9, calificación 88 (96/83/91/0), recuperación 76,
  esfuerzo 2,0 a las 9:12 (= arnés check/n30/N.kt con el código real: 47/272/111/102, 91 %, VFC 105,3, FCR 56).
  - Recuperación 76 vs 84: con la VFC/FCR EXACTAS de WHOOP la fórmula da 75,6 → es la fórmula. Ajustes por mes (abr–oct) dan pendientes de 73 a 112:
    ruido, no deriva; añadir dV² no mejora fuera de muestra (CV 4,82 → 4,68–4,73, octubre 5,30 → 5,27). No se toca.
  - Calificación con los 3 valores de WHOOP: 91,7 (WHOOP 96); las noches 27–29 la fórmula sí cuadra (87/86/90 vs 87/85/90) → noche rara de WHOOP.
  - **Esfuerzo dormido (30/10, Android + iOS)**: `Formulas.strainOf(..., sleepWindow)` resta 0,05 a la reserva dentro de la ventana de sueño
    (`SLEEP_STRAIN_FLOOR`; MetricsCalculator y DailyMetricsUpdater pasan la ventana de las fases). 11 ciclos de WHOOP 20→30/10 (check/n30/Z3.kt con
    las ventanas de WHOOP y V.kt con las de la app): error medio 0,59 → 0,45, NINGÚN día peor; noches 26→27 0,7 → 0,2 (W 0,2), 29→30 0,8 → 0,3 (W 0,2).
    Quitarlo también de día (zona muerta global) daba 0,40 pero el día de descanso 25/10 bajaba de 4,3 a 2,5 (W 4,1) → solo dormido.
    `night_recalc_v7` / iOS 7. Ojo: el esfuerzo de WHOOP en la API no se actualizó de 07:07 a 09:18 (sigue 0,24) → por la mañana compara con eso.
  - **Necesidad por esfuerzo (30/10, Android + iOS)**: `sleepNeedFromStrain` = 0,0386 · esfuerzo^2,527 (redondeado). 32 noches de la API
    (need_from_recent_strain frente al esfuerzo del ciclo anterior, 27/09→30/10): error 3,9 → 0,73 min (dejando una fuera 0,79, máx 1,3).
    La de antes (6 min por punto desde 8) daba 0 por debajo de 8 (WHOOP 2–7 min). Otras formas: a·(e^(bs)−1) 1,47; a·e^(bs) 2,36.
  - Despierto 47 vs 32 (17 vs 15 despertares): búsqueda de las reglas de despierto con 15 noches (check/wake, ST.kt copia de SleepStager con WAKE_* variables,
    1200 combinaciones; API: despierto y disturbance_count). Mejor dentro de muestra: WAKE_MIN_SPIKE 12 → 15 (MAE 7,56 → 6,12), pero dejando una noche
    fuera 7,12 y despertares 2,60 → 2,80; 27 y 29 empeoran → NO se aplica. Sesgo actual +4 min (eficiencia −2).
    La eficiencia de WHOOP no es (cama − despierto)/cama: 30 → 94,0 calculada vs 94,7; 29 → 95,2 vs 96,9.
  - **Fases**: capturas leídas (check/hyp/dig30.py, n27–n30, L/P/R a ±5 de la API), etiquetas lab30.py, rasgos feat30.py con hr_log_28/motion_16.
    Modelo actual (11 noches) en 27–30 fuera de muestra: acuerdo 78,1 %, MAE D/L/P/R 8/34/17/26. Reentrenado dejando cada noche fuera (15 noches):
    27–30 78,3 % (9/35/16/28) = igual; 16–26 82,1 %; total 81,0 % (10/23/10/18). No mejora las noches nuevas → se deja el modelo de 11 noches
    (copias *_11 en check/hyp; lab.pkl/raw.pkl/F.pkl ya tienen 15 noches para el próximo reentreno). 30: profundo 111 vs 85 (los dos modelos ~116–121).

- **Pasos y calorías del 29/10 (30/10)**: WHOOP 10 113 pasos / 2078 kcal; PulseApp 7032 / 2181.
  - Pasos: 0 minutos de movimiento grabado de 20:18 a 22:13 = el pádel (20:36–21:56, móvil lejos). **Contador de pasos de la PULSERA**: registro v18,
    bytes [57..58] u16 = pasos del ciclo de WHOOP (sube ~2/s andando, vuelve a 0 al empezar ciclo; [61..62] es otro contador que también sube
    dormido, no sirve). Comprobado con whoop_history_raw_6 (scratchpad v26/r.py): ciclo 20/10 = 6029 (WHOOP 6015) aunque faltaban 10 h de historial;
    minuto a minuto r 0,71 con el contador de PulseApp (4122 vs 3672). v26 (88 B) = 1 min de señal cruda cada ~20 min, sin pasos. v18 [41] f32 =
    nivel de actividad por segundo (andando 0,15–0,2, quieto 0,006).
    **Aplicado (Android `BandSteps.kt` + iOS `Core/BandSteps.swift`)**: cada registro v18 → band_steps.csv ("unix,contador", al cambiar contador o minuto).
    Pasos = diferencias entre muestras seguidas (si baja = reinicio, cuenta el valor nuevo) donde hay historial seguido (huecos ≤ 30 min);
    PulseApp (motion_minutes) fuera de eso; en un hueco sin historial, el mayor de los dos. Inicio (día y hoy), detalle de actividad. Código real
    (check/steps30/T.kt) = 6029; CI de iOS "Comprobar los pasos de la pulsera" con ios/Tests/bandsteps. Solo cuenta desde que se instala (el archivo
    empieza vacío). Pendiente: comprobar el 29/10 (10 113) con un whoop_history_raw.txt reciente.
  - Calorías: **WHOOP gasta un ritmo FIJO fuera de los entrenos**: (energía del ciclo − entrenos)/(duración − entrenos)·24 = 1706 ±17 kcal (20 ciclos API),
    mediana 1704 en 197 ciclos del export, 1695–1728 por mes; no depende de los pasos (r 0,31). Y en los entrenos cuenta SOLO sus kcal.
    PulseApp sumaba el basal 24 h + actividades (doble en el tiempo de deporte; 29/10 ~ +160). Ahora (Android + iOS) `CalorieCalculator.estimateDailyTotal`
    = ritmo × (min transcurridos − min de actividades sin siestas)/1440 + kcal de actividades; ritmo = `Formulas.whoopRestKcalPerDay` (mediana con tus
    días importados de WHOOP, código real 1707; se guarda en prefs `rest_kcal_day` / iOS `pulseapp_rest_kcal_day`), si no hay import el basal Mifflin.
    29/10 con las actividades de WHOOP: 2102 (día de 24 h; con el ciclo de 23,8 h 2088; WHOOP 2078; antes 2181).

- **Noche 30→31 NO grabada (31/10, iPhone)**: ni pulso ni movimiento de 22:44 a 09:27; por la mañana "Conectada, preparando…" (amarillo) hasta
  desconectar/conectar a mano. La app de WHOOP ya había descargado la noche → PulseApp no puede recuperarla (sin confirmar solo llega el 1.er bloque).
  Causa probable (falta el whoop_service_log para confirmarlo): si iOS cierra la app de noche y la reabre por la pulsera, `willRestoreState` llamaba a
  `beginSetup` ANTES de `.poweredOn` → iOS ignora discoverServices, `setupStarted` quedaba en true y ningún camino lo reintentaba (`beginSetup` salía
  por `setupStarted`). También se quedaba colgado si no aparecían los servicios. **Arreglo (`BLE/WhoopManager.swift`)**: no preparar hasta
  `.poweredOn`; vigilancia de 15 s (con tarea en segundo plano) tras empezar a preparar y tras quedar lista: si no mide / no llega ningún dato →
  `restartLink` (cancela la conexión de PulseApp y la vuelve a pedir, como hacerlo a mano); preparación colgada de antes → se rehace;
  `ensureAlive()` al abrir la app (no midiendo, o > 2 min sin datos → reconecta). Android no tiene restauración de estado (servicio en primer plano).

- **31/10 (2.ª parte)**: el whoop_service_log CONFIRMA la causa de la noche 30→31: 23:27:43 "♻️ iOS ha reabierto PulseApp" → "Conectada. Preparando
  canal…" y nada más hasta las 09:27 (desconectar a mano). Corregido en d291602 (ver arriba).
  - **Mañana tomada como noche**: sin datos de la noche, `SleepDetector` cogía la ventana más larga (9:38–12:40, "1:11 dormido", sueño 31 %,
    recuperación 24 %). Ahora (Android + iOS) sin ≥ 30 min de madrugada (00:00–06:00) en la ventana → NO hay noche ("–"). Las 15 noches de
    referencia salen igual (N.kt, mismos MAE); 30→31 → ninguna.
  - **whoop_history_raw**: el iPhone dejaba de escribirlo al llegar a 40 MB (el subido hoy = el del 22/10, idéntico). Ahora (iOS BufferedAppender,
    también el registro de servicio, y Android) al llenarse pasa a `<nombre>_anterior.<ext>` y se empieza otro. band_steps.csv en Exportar (iOS).
    Sin raw reciente NO se pudo comprobar el 29/10 con el contador de la pulsera; se comprobará con los pasos de la API (cycles.step_count).
  - **Batería de la pulsera (Android `BandBattery.kt` + iOS `Core/BandBattery.swift`)**: EVENTO 3 (tipo 48, [10]=3, llega solo ~cada 14 min por
    fd4b0004/0005, retraso 5 s): [12..15] unix, [21..22] u16 = décimas de % (997 → 506 del 18 al 22/10, solo baja), [25..26] u16 = mV (4380 → 3869,
    r 0,999 con el nivel). Segunda comprobación: WHOOP mostró 34 % el 30/10 9:12 y "< 20 %" el 31/10 8:01 → ~0,6 %/h; el evento 3 baja 0,52 %/h.
    Numeración de eventos de WHOOP que cuadra con los datos: 3 batería, 11/12 conexión BLE sí/no (38 y 38), 16 puesta en hora. Carga: 7/8, 5/6,
    21/22 (aún sin ver) o nivel/tensión que sube → "cargando". Inicio muestra "NN %" (rojo < 20) y rayo si carga; Mi WHOOP (iOS) fila de batería.
    Aviso "Recordatorio de carga de batería" una vez al bajar del 20 % (se rearma al cargar o > 25 %). Orden 26 (GET_BATTERY) se envía una vez al
    conectar y su respuesta se guarda entera en el registro ("🔋 Respuesta a la orden 26") para descifrarla.
  - **Notificaciones como WHOOP (iOS)**: permiso al arrancar; "Abre PulseApp — Mantén la aplicación PulseApp abierta…" al cerrarla deslizando
    (UIApplication.willTerminateNotification; iOS no la vuelve a abrir tras cerrarla a mano); "Actividad completada" al guardar una actividad
    automática. Android: canal "Avisos" (solo batería; el servicio sigue aunque cierres la app).

- **31/10→1/11 (16.ª referencia, fútbol 18:15–19:35 + paseo la víspera, acostarse 03:24)**: WHOOP (API) 02:24:55Z–09:12:51Z (03:24–10:12), cama 6:48,
  dormido 6:27, 21/221/110/57, 4 despertares, 96 %, VFC 78,2, FCR 58, resp 13,4, calificación 75 (horas 75 / regularidad 43 / 96), recuperación 43.
  PulseApp iPhone: 03:25–10:38, 6:54, 19/228/103/83, VFC 83, FCR 59, calificación 70 (79/34/95), recuperación 53.
  - **Fin de la noche (1/11, Android + iOS `trimBounds`)**: tras un despertar de ≥ 5 min (10:12–10:16) seguía tumbado quieto 21 min y contaba como sueño.
    Ahora un despertar ≥ 5 min seguido de < 30 min dormido al final = fin de la noche. 16 noches (código real, check/n30/N.kt + check/end01/T.kt):
    solo cambia la 1/11 → 10:11 (WHOOP 10:12), 14/211/103/79, dormido 6:33 (6:27); error del fin 3,1 → 1,5 min. Mismo resultado con 25–40 min.
    Con 4 min cambiaba también 16 (−6) y 24 (+10 → 0): no se usa. `night_recalc_v8` / iOS 8.
  - Recuperación: con la VFC/FCR EXACTAS de WHOOP la fórmula da 46 (WHOOP 43) → la diferencia (53) es la VFC: profundo 90,5 / toda la noche 76,6 → 83,5
    (WHOOP 78,2). Probado otro reparto de los dos métodos (peso, escala, "más cerca del menor"): dentro de muestra 1,6–1,7 pero dejando una noche
    fuera 1,7–2,2 frente a 1,97 actual → no se toca (+5 = el máximo de las 16 noches; 25/10 igual: profundo mucho mayor que toda la noche).
  - Regularidad 34 vs 43: PulseApp no tiene la noche 30→31 (no se grabó) y compara con 28–30/10; con las horas de WHOOP sale 40. No se arregla
    con fórmulas (ya está corregida la causa de la noche perdida).
  - **Esfuerzo de la mañana**: WHOOP 0,3 a las 11:38 = ciclo que solo llegaba a ~10:40 (FC media 60 del ciclo: la nuestra es 60,1 hasta 10:30, 60,4 a
    10:45 y 62,1 a las 11:30; en la API la cifra no cambió de 10:14 a 11:57). PulseApp hasta 10:40 da 0,2. El +1 es la hora levantado a 75–90 lpm que
    WHOOP aún no había sumado. Días completos (12 ciclos) error medio 0,46; un suelo de día (0,02–0,15, también solo sin pasos) hunde el día de descanso
    25/10 (4,1 → 1,4–3,5) → no se toca. Arnés check/n30/Z4.kt / Z5.kt / Zm.kt.
  - **VFC nueva (1/11, Android + iOS `NightMetrics.stageHrv`)**: VFC = e^0,0819 · P^0,3808 · L^0,6030, P/L = media del RMSSD de los tramos de 2 min
    (≥ 60 RR) dentro del PROFUNDO / LIGERO del modelo, filtro de artefactos 30 % (el 20 % tiraba latidos buenos). Sin fases o < 10 tramos → `hrvOld`.
    16 noches dejando cada una fuera: 1,9 → 1,42 ms (máx 5,3 → 3,4); ajustando con 16–25/10 y probando 26/10–1/11: 2,28 → 1,62; con las fases EXACTAS
    de WHOOP 1,40. Código real (N.kt): MAE 1,13, 1/11 79,6 (W 78,2). Probado y descartado: más peso al profundo del final, solo profundo de WHOOP,
    mediana/recortada, filtro con mediana local, otros umbrales (0,25–0,40 igual; 0,10/0,5+ peor). Arnés check/vfc01 (Dump.kt, a–e.py).
    Recuperación de PulseApp 23/10→1/11 (historial WHOOP hasta 22/10): error medio 4,7 → 3,4 (1/11 52 → 48, W 43; 24/10 73 → 69, W 60).
    `night_recalc_v9` / iOS 9.
  - **Fórmula de recuperación (1/11)**: búsqueda con 209 noches (scratchpad rec30/g.py, k.py). Validación EN LÍNEA (reajustando cada semana con lo
    anterior, como se usaría de verdad): actual 3,78 (desde 1/9 4,27). Nada la mejora de forma fiable: + sd de la VFC 30 d mejora la validación cruzada
    (3,36) pero EMPEORA hacia delante (5,23: hace de reloj); + Φ FCR, z-score, EWMA 7, media 30 d, calificación, regularidad, horas, respiración,
    árboles: 3,8–5,2. El error que queda (±4) es de la línea base interna de WHOOP, que no se ve. No se cambia.
  - **Monitor de salud (1/11, Android + iOS)**: rango = media ± 1 sd de 30 días (antes 14). Con 14 días el rango de VFC era 83–105 y hasta el 78 de
    WHOOP salía fuera (WHOOP: 5/5 dentro). Con 30: VFC 75–107, FCR 54–61 → 3/3. Falta una captura del detalle del Monitor de salud de WHOOP para afinar.
- **1/11→2/11 (17.ª referencia, siesta 15:57–17:36 la víspera)**: WHOOP (API) 22:11:53Z–06:49:25Z (23:11–07:49), cama 8:37, dormido 8:25,
  12/310/112/84, 11 despertares, 98 %, VFC 115,7, FCR 54, resp 13,8, calificación 80 (100/45/98/0), recuperación 93; necesidad 443 = 470 + 2 + 64
  deuda − 92 siesta. PulseApp iPhone (versión 1/11): 23:07–07:49, 8:15, 27/321/96/78, 94 %, VFC 116, FCR 54, resp 14,1, calificación 82
  (92/62/94/0), recuperación 91. Código real (N.kt) = app. VFC 17 noches MAE 1,08.
  - **Siesta en la necesidad (2/11, Android + iOS)**: la siesta SÍ se detectó (código real: 15:51–17:35), pero `planForLastNight` solo restaba
    las siestas de HOY desde las 00:00 → la de ayer por la tarde no contaba (horas vs necesidad 92 %, WHOOP 100 %). Ahora la noche resta las
    siestas de su día (`Formulas.napsForNight`: de las 12:00 de la víspera a las 12:00 del día en que acaba) × 0,95 (`napNeedMinutes`: WHOOP
    resta el tiempo dormido: −65,5/69, −58,7/59,8, −91,6/98,9). También en los días guardados (HomeData.recordFromStored).
  - **Regularidad con siestas y −4 (2/11, Android + iOS)**: 44 noches de la API (20/09→2/11, check/reg2/r.py): sin siestas −7 4,49; con siestas
    −7 4,11; con siestas −4 3,26. Cada mitad por separado: −4 (3,78 / 2,67 frente a 4,17 / 4,00 con −7). Kotlin = Python (check/reg2k/R.kt:
    2/11 58, 2/10 77). La 2/11 sigue alta (58 con las horas de WHOOP, 61 con las de PulseApp, WHOOP 45): no se explica con una noche.
  - **Esfuerzo del día con la FCR de referencia (2/11, Android + iOS)**: `strainOf` del día usaba la FCR de anoche (54 hoy → la mañana sumaba
    más). Ahora `Formulas.zoneRestingHr()` (la de las zonas: manual o media de tus noches, WHOOP "FCR de referencia 59"). 14 ciclos de WHOOP
    (check/n30/Z6.kt): FCR de cada noche 0,54; fija 58 0,46; 59 0,37; media 14/30 d 0,48. `night_recalc_v10` / iOS 10.
    Ojo: el error baja siempre al subir la FCR (60 0,29, 62 0,19) → hay un sesgo de +0,3–0,5 en los días; no se ajusta a mano.
    Mañana 2/11: WHOOP 1,0 a las 9:14 (la API dice 4,0 a las 10:33); PulseApp 2,0 (con FCR 54), 1,4 con 58.
  - Sueño: inicio 23:07 vs 23:11, despierto +15, profundo −16. Respiración 14,1 vs 13,8 (por eso el Monitor de salud dice 2/3: respiración
    "elevada", rango 12,7–14,1).
  - **Siestas como WHOOP (2/11, Android + iOS)**: `SleepStager.stageNap` (mismo clasificador sobre la ventana de la siesta, mínimo 20 min, sin
    REM en los primeros 60 min: de las 4 siestas de WHOOP en la API solo una tuvo REM) + `NapStages` (nap_stages.csv, se calcula una vez;
    `asleepMinutes` = dormido de las fases o 95 % del tiempo). La necesidad resta ese tiempo dormido. Inicio: píldora azul de sueño con el
    tiempo dormido (antes "0,0" de esfuerzo). Detalle: horas de sueño, sueño reparador (profundo + REM), "Esta siesta redujo tu sueño requerido
    por N minutos", pulso, fases tocables (pintan la gráfica) y despertares/eficiencia/FC. Siesta 1/11 (código real, check/nap02/Ns.kt):
    15:58–17:36, 2/74/22/0, dormido 1:36, reparador 0:22 (WHOOP 15:57–17:36, 7/51/40/0, 1:31, 0:40, resta 91). Profundo corto: solo 1 siesta
    para comparar (el modelo se entrenó con noches) → recalibrar con más siestas.
- **2/11→3/11 (18.ª referencia, pesas 19:04–19:31 la víspera)**: WHOOP (API) 21:59:11Z–05:55:20Z (22:59–06:55), dormido 7:47, 9/296/108/63,
  98,5 %, VFC 85,7, FCR 56, resp 13,2, calificación 82 (99/63/99), recuperación 53. PulseApp iPhone: 22:59–06:45, 7:25, 21/261/94/90, VFC 87,
  FCR 57, resp 12,9, calificación 79 (87/58/95), recuperación 59 (con VFC/FCR exactas de WHOOP la fórmula da 58 → fórmula).
  - **Fin de la noche (3/11, Android + iOS `motionBounds`)**: se levantó 2 min (06:45–06:46, 16 + 9 pasos) y volvió a dormirse hasta 06:54; el
    alargue del final cortaba con > 15 pasos. Ahora 40 (`END_EXT_STEPS`). 18 noches: solo cambia la 3/11 → 06:54 (W 06:55), error del fin
    1,9 → 1,3 min; igual con 25–60 pasos. Arnés check/end01/E2.kt. 3/11 ahora 25/246/116/89, VFC 87,6.
  - **Recuperación 52 un instante y luego 59 (iOS)**: Inicio enseñaba los números de la última vez hasta recalcular. Con la noche hasta las 03:00
    la app da 52 (check/n30/Pt.kt: 02:00 55, 03:00 52, 04:00+ 59–60) → era un cálculo viejo. Ahora al volver a la app con datos de > 5 min
    se tapa con la pantalla de carga hasta tener los nuevos (`scenePhase`).
  - **Pesas (3/11, Android + iOS `Formulas.isWeights`)**: "Entrenamiento de fuerza"/pesas/gimnasio/potencia llevan 4,2 de carga muscular por
    minuto (funcional/crossfit siguen con 14,61). Export: Entrenador de fuerza (8 sesiones) mediana ≈ 4/min, funcional (62) 14/min; 9 sesiones
    de fuerza MAE 3,87 → 2,16. Pesas 2/11: solo pulso 2,5, antes 8,3 (app 8,6), ahora 5,0 (WHOOP 4,46). `act_recalc` 6, `night_recalc_v11` / iOS 11.
  - **Pasos 43 564 el 2/11 (WHOOP 8999, PulseApp por movimiento 9294)**: `BandSteps` contaba cualquier BAJADA del contador como reinicio
    (+ el valor nuevo, ~2000). Llegan registros de dos fuentes con el contador desfasado unos pasos (en el archivo del 20/10 hay segundos con
    2254 y 2260 a la vez). Simulado con ese archivo (10 bajadas pequeñas entre segundos): código anterior 33 372, nuevo 6029 (= sin desfase).
    Ahora solo es reinicio si baja a menos de la mitad; si baja poco se ignora y se sigue desde el valor más alto (Android + iOS; CI de iOS con
    band_steps_jitter.csv). CONFIRMADO con el band_steps.csv real (31/10→3/11, check/steps30/K.kt, código antiguo y nuevo): ciclo 2/11 antiguo 43 564 (= lo que mostró la app) → nuevo 9013 (WHOOP 8999); 1/11 1842 (1839); 3/11 hasta 16:44 2324 (2315 a las 9:00). Solo 2 bajadas pequeñas (17251→17245, 17300→17297) y 2 reinicios de verdad (al empezar ciclo).
  - **Recuperación 3/11 (59 en la app, 52 un instante, WHOOP 53)**: el 52 era el cálculo con la noche hasta ~03:00 (Pt.kt), no más correcto. Desglose del +6 (Kotlin R4/R5.kt + Python rec30/m.py): fórmula con los valores de WHOOP 56 (+3, ruido propio: últimas 12 noches sesgo −1,2, MAE 3,7); falta la noche 30→31 (no grabada, VFC 103) en la línea base → +2; VFC 87,6/FCR 57 vs 85,7/56 → +1–2. Probado reajustar la fórmula cada día con más peso a lo reciente (vida media 30–180 d) o corregir el sesgo reciente (7–60 d): en línea 3,56–3,71 vs 3,52 fija, octubre 4,09–4,35 vs 4,06 → no se cambia. Reimportar un export de WHOOP reciente rellenaría la noche que falta.

- **3/11→4/11 (19.ª referencia, fútbol 21:11–22:06 la víspera y cena, acostarse 22:45)**: WHOOP (API) 21:45:04Z–06:54:06Z (22:45–07:54),
  29/361/91/69, 5 despertares, 95 %, VFC 80,05, FCR 62, resp 13,5, calificación 81 (100/66/95), recuperación 50. PulseApp iPhone (versión 3/11):
  22:45–07:54, 37/340/81/91, VFC 74,6, FCR 61, resp 13,2, calificación 84 (97/64/93), recuperación 40 a las 8:20 y 39 a las 8:58.
  Código real (check/n04/N.kt con hr_log_33 + motion_minutes_21, que traen todo desde el 14/10) = app. Importación de WHOOP comprobada (medias 92/58).
  - **VFC (4/11, Android + iOS `NightMetrics.stageHrv`)**: el primer profundo (23:13–00:10) iba a 72–77 lpm (FCR 61) con RMSSD 40–55 → P 50,8
    (P/L 0,55, la más baja de las 19 noches). Nuestro profundo cae donde el de WHOOP (capturas en check/hyp/n04, hyp_all_04.json) y con sus
    fases exactas también sale 76,4 → no son las fases. Ahora fuera los tramos de 2 min con pulso medio > FCR de la noche (mediana) + 12 y
    coeficientes reajustados (e^0,03828 · P^0,38089 · L^0,61171). 19 noches dejando cada una fuera 1,76 → 1,45 (máx 5,7 → 3,8); ajuste con
    16–25/10 y prueba 26/10–4/11 2,08 → 1,67 (umbral 10–20 todos mejor). Código real 19 noches MAE 1,35 → 1,23; 4/11 74,6 → 77,7 (W 80,1);
    empeora 20/10 77,5 → 81,3 (W 78). Probado y peor: quitar los primeros 15–60 min, más peso al profundo del final, mediana, solo ligero,
    toda la noche. Con la FC sacada de los RR (sin el lpm) sale peor (1,54) → NightMetrics.hrv recibe el pulso (`bpm`). Kotlin = Python 19/19.
    CI de iOS: paso "Comprobar la VFC de la noche" (ios/Tests/vfc, 2 noches reales: Swift = Kotlin 81,3074 y 77,7421). `night_recalc_v12` / iOS 12.
    Recuperación de hoy: 39 → 43 (WHOOP 50); con la VFC/FCR exactas de WHOOP la fórmula da 45 → −5 de la fórmula.
  - **40 → 39 por la mañana**: la VFC estaba justo en el borde (75,0 da 40, 74,9 da 39). Con los datos hasta las 08:20 la noche no cambia
    (07:56–08:20 iguales, check/n04/T8.kt); el cambio de las 8:58 viene de datos que llegaron después (no está en el archivo) → no comprobado.
  - **Actividades 3/11**: fútbol PulseApp 20:59–22:21 14,7 (WHOOP 21:11–22:06 14,4); "suaves" falsas 20:25–20:50 (llegar/calentar, sin
    movimiento grabado, 95–115 lpm) y 22:30–22:44 (cenando tras el fútbol, 96–110). También 31/10 20:00–20:58 (29 min tras el partido).
    **Arreglo (Android + iOS `Formulas.softNextToActivity`)**: una suave que empieza ≤ 45 min tras otra actividad o acaba ≤ 30 min antes no cuenta;
    el escáner borra las automáticas sin editar que quedan pegadas (la de antes del partido se guarda a las 21:00, antes de que exista el fútbol).
    15/10→3/11 (check/act25/D4.kt): quedan solo las suaves de verdad (funcional 22/10, fútbol 26/10). Una vez al instalar (`act_soft_clean` 1 /
    iOS `pulseapp_act_soft_clean`) se miran 10 días SOLO para borrar. El esfuerzo del día casi no cambia (15,2 → 15,19; WHOOP 14,8: la base
    por minuto es pequeña) y la recuperación NO usa el esfuerzo.
  - **Todas las versiones de la VFC comparadas (4/11, check/n04/V5.kt + R8.kt, scratchpad ver.py)** con las 19 noches y el código real:
    (VFC: con sus números de la app / reajustada dejando cada noche fuera / ajuste 16–25/10 y prueba 26/10–4/11 — recuperación de las 12 noches
    medidas por PulseApp 23/10–4/11, historial WHOOP hasta 22/10)
    23/10 toda la noche 4,21 / 2,54 / 3,28 — 3,67 · 24/10 profundo 4,41 / 4,97 / 7,11 — 9,83 · 25/10 media 2,15 / 2,84 / 2,72 — 5,33 ·
    1/11 profundo+ligero 1,35 / 1,76 / 2,09 — 4,17 · **4/11 sin pulso alto 1,23 / 1,46 / 1,67 — 3,50** · con la VFC/FCR EXACTAS de WHOOP — 3,58.
    La actual es la mejor en todo y la recuperación ya falla lo mismo que con los valores de WHOOP: lo que queda es la fórmula de recuperación.
  - **Inicio/fin de entrenos vs WHOOP (4/11)**: inicios casi siempre exactos; fallan 21/10 (−23), 31/10 (−14), 3/11 (−12: calentamiento 21:00–21:10
    a 98–114 lpm; WHOOP empieza 21:11, primer minuto que se queda ≥ zona 1 = 111). Finales: muchas veces +13–15 (andar después: 26, 27 func,
    28, 30/10, 3/11) y otras −17/−21 (27 pádel, 22/10). Reglas probadas antes empeoran dejando uno fuera → pregunta para la IA de WHOOP.
  - **Respuesta de la IA de WHOOP (4/11)**: actividades = pulso elevado + movimiento + carga; sin regla publicada de inicio/fin ni "bloqueo"
    alrededor de un entreno (nuestra regla de 45/30 min es un sustituto que da el mismo resultado que WHOOP en 15/10→3/11). VFC = media
    ponderada durante el sueño con más peso al PROFUNDO y a los periodos MÁS TARDÍOS; no quita la primera hora por pulso alto.
    Probado (scratchpad tw.py, 19 noches, nuestras fases): media ponderada de todo el sueño con más peso a profundo (a) y al final (b·progreso^pw):
    mejor LOO 1,48 pero prueba por tiempo 2,16–2,86; añadir peso al final a la estructura actual empeora (b 0,5 → LOO 1,52, prueba 1,93).
    La actual (profundo+ligero sin pulso alto) sigue mejor: LOO 1,45 / prueba 1,67 → no se cambia.
  - **Ajustes de FC de WHOOP (captura 4/11)**: muestra FCR 57 y FCmáx 195, zonas manuales DESACTIVADAS, pero los rangos siguen
    112/141/155/168/182 = calculados con FCR 59 (con 57 serían 111/140/154/168/182). Fútbol 3/11 con la ventana de WHOOP (check/n04): con FCR 59
    las zonas salen a 4 s en total de la API; con 57 102 s, con 58 139 s → WHOOP no rehace las zonas cada día. Recomendado poner 59 en
    "FC en reposo para zonas" (Sobre mí); también era lo mejor para el esfuerzo del día (2/11, Z6.kt).
  - **IA de WHOOP sobre las zonas (4/11 tarde)**: se actualizan UNA VEZ AL MES (última 19/10), FCmáx 195. Dice que podrían ser de FCR 57, pero
    los datos no: con 57 Z1 empezaría en 111 (ceil 110,1) y los segundos por zona del fútbol 3/11 fallan 102 s; con 59 → 112 y 4 s. El 59 lo
    mostraba su pantalla de Ajustes de FC el 20/10. Próxima actualización ≈ 19/11: entonces habrá que poner su nueva FCR de referencia.
  - **FC máxima fija (4/11, Android + iOS `updateObservedHrMax`)**: PulseApp la subía sola al guardar una actividad con FC más alta (3/11 máx 197 →
    FCmáx 197). WHOOP NO la sube (sigue en 195 con ese mismo partido). Ahora solo se pone si no hay ninguna. 20 entrenos de WHOOP 19/10→3/11 con
    sus ventanas (check/act25/F4.kt, código real): FCmáx 195 error medio 0,27 (sesgo +0,06), 197 0,30, 199 0,43 → 195 es lo mejor.
  - **Inicio por los pasos de la pulsera (4/11, Android + iOS `Formulas.trimStartByBandSteps`)**: band_steps_1.csv (31/10→4/11): WHOOP empieza cuando
    empiezas a moverte. 3/11 0 pasos/min 20:59–21:10 y 30 a las 21:11 (= WHOOP 21:11); 31/10 0–4 pasos/min 18:01–18:15, 11 a las 18:16 (WHOOP 18:15).
    Regla: si el principio de un entreno/suave tiene ≥ 5 min seguidos con historial de la pulsera y ≤ 5 pasos/min, empieza en el primer minuto con
    ≥ 10 pasos. Código real 15/10→3/11 (check/act25/D5.kt): solo cambian esas dos (las demás no tienen pasos de la pulsera). Una automática ya
    guardada se recorta (no si la editaste); `act_soft_clean` 2 / iOS 2 repasa 10 días solo para recortar/borrar.
    Las suaves falsas también se ven en los pasos: 20:25–20:50 0,1/min, 22:30–22:44 3,1/min, 31/10 20:00–20:58 4,6/min (fútbol 77/min, pesas 2/11 ~37/min).
    Fútbol 3/11 (F3.kt): FCmáx 195 + 21:11–22:21 → 14,9 (WHOOP 14,4; con su ventana 14,8). El final sigue +15 min (andando 22:15–22:21).
- **4/11→5/11 (20.ª referencia, pesas 18:17–19:08 la víspera, acostarse 21:50)**: WHOOP (API) 20:50:02Z–06:36:21Z (21:50–07:36), dormido 9:15,
  31/408/73/75, 10 despertares, 96 %, VFC 96,4, FCR 56, resp 13,3, calificación 85 (100/68/96), recuperación 73. PulseApp iPhone (versión 4/11 mañana):
  21:50–07:35, 9:00, 45/350/82/108, 92 %, VFC 93, FCR 57, resp 12,6, calificación 88 (100/76/92), recuperación 70 al despertar y 68 a las 9:00.
  - **70 → 68 por la mañana (5/11, Android + iOS `SleepStager.stage`)**: el modelo de fases usa el "progreso" de la noche = minuto / largo de la ventana,
    y la ventana del pulso crece mientras sigues en la cama o en casa (detector 21:34–07:59 a las 8:00, –08:14 a las 8:15) → cambiaban 12 minutos de
    fases en TODA la noche (23:08, 00:43, 02:50, 07:06) → VFC 94,0 → 93,1 y recuperación 69 → 67 (check/n05/T8.kt, Cmp.kt). El modelo se entrenó con el
    progreso sobre el tiempo en cama de WHOOP (feat2.py: prog = i/n de la ventana de WHOOP) → ahora segunda pasada del modelo SOLO sobre la noche ya
    recortada. 20 noches (código real, N.kt): MAE D/L/P/R 8,7/21,4/10,8/15,8 → 8,7/22,0/10,9/15,8, VFC 1,34 → 1,32 (igual). Estable a cualquier hora:
    5/11 07:40–09:00 VFC 94,0 → 94,0 (69 siempre); 2/11, 3/11 y 4/11 iguales de 07:00 a 10:00 (T9.kt). `night_recalc_v13` / iOS 13.
    Recuperación 5/11 con la versión nueva 69 (WHOOP 73); con la VFC de WHOOP 72.

- **5/11 (2.ª parte)**:
  - **FCR ±1**: 20 noches, mediana de toda la noche MAE 0,55 (10 exactas); probadas 12 alternativas (solo dormido, por minuto, media,
    percentil 40–48, profundo, último profundo, mitades, mínimo 10 min): ninguna mejora. Es redondeo (pulso entero vs decimales de WHOOP).
    Ya pasaba antes (17, 18, 19, 21, 27/10 +1). Arnés check/fcr (FD.kt + scratchpad fcr.py). No se toca.
  - **Entrenador de fuerza (Android + iOS)**: `Strength.kt` / `Core/Strength.swift` (biblioteca de 134 ejercicios genéricos con fracción de
    peso corporal, series, plantillas, ejercicios personalizados, entrenamiento en curso, récords, hitos, texto → entrenamiento con
    `parse`/`bestMatch`). Archivos TSV en la carpeta de la app (strength_logs/templates/custom/live.tsv), NO Room. Pantallas Android:
    StrengthActivity (Progreso/Mis entrenamientos/Entrenamientos), StrengthSessionActivity (live/template/log: comenzar/finalizar serie
    guarda la hora → FC de cada serie), ExercisePickerActivity (buscar, filtro, personalizado, superserie), StrengthSummaryActivity
    ("Resumen del ejercicio"); iOS UI/StrengthScreens.swift (rutas strengthHome/strengthSession/strengthSummary). Detalle de actividad
    con series: CARDIO/MUSCULAR, pestañas EJERCICIOS/ZONAS DE FC, tarjetas deslizables (las series del ejercicio se pintan en verde en la
    gráfica), "Ver todo", hito. Gráfica de pulso con el dedo: lpm y hora (Android `ActivityHrChartView.onScrub`, iOS `ActivityHrChart.onScrub`).
    **Esfuerzo**: `Formulas.sessionMuscleMinutes` = carga muscular de las series si las hay (`Strength.muscleLoad` = 0,04225 ×
    Σ reps·(kg + fracción·peso corporal)), si no lo de antes por tipo. Calibrado con UNA sesión (4/11 18:17–19:08, 3900 kg, 199 reps,
    24 series, WHOOP 8,1): código real (check/str/R.kt) sin series 7,48 (= app 7,5), con series 8,18 (FCR 58) / 8,14 (FCR 59).
    CI de iOS "Comprobar el entrenador de fuerza" (ios/Tests/strength: input.txt → expected.txt de Kotlin, 150 líneas).
    Pendiente: más sesiones registradas para ajustar; WHOOP muestra cardio 26 / muscular 74 y nosotros 36/64 con esa carga; kcal WHOOP 123 vs 163.
  - **Monitor de estrés como WHOOP**: "< HOY >", medidor 0–3 (`StressGaugeView` / `StressGauge`), gráfica de 24 h hasta ahora con sueño
    (noche + siestas) y actividades marcadas (`whoopStyle`, horas 18:00/02:00), tarjetas con "Ver tendencias" (StressTrendsActivity /
    StressTrendsView: 7 días apilados). Inicio abre el día elegido.
  - **Batería**: `band_battery.csv` (unix, décimas de %, mV, movimiento 1/0) en Android e iOS, en Exportar. Ahorro de batería opcional
    (Mi WHOOP): movimiento solo de 20:00 a 12:00 (`imuSaver`/`imuWanted`, se mira cada 5 min en Android y con cada dato en iOS). Por
    defecto apagado: sin movimiento de día no hay siestas ni paseos detectados. Falta el historial real para ver cuánto baja.

  - **IA de WHOOP (5/11 tarde)**: VFC/FCR de la recuperación solo con el sueño (lo de después de despertar no cuenta) = lo que hace PulseApp
    desde la 2.ª pasada de fases. Entrenador de fuerza: carga muscular = volumen (series, reps, carga + parte del peso corporal según el
    ejercicio) + intensidad (velocidad de las repeticiones con acelerómetro/giroscopio e historial); Cardio/Muscular = proporciones del esfuerzo
    de la actividad (no de tiempo ni kcal); medallas = récord de PESO (con peso), de REPETICIONES (sin peso) o de TIEMPO (isométricos), el
    volumen no da medalla → `Strength.records` cambiado así (Android + iOS); calorías = metabolismo basal + pulso, la carga muscular NO suma kcal.
  - **Estrés vs WHOOP con sus "Vista de tendencias" (5/11)**: barras del mes leídas de 3 capturas (check/n05/tr, dig_st.py → whoop_stress_pct.json,
    7/10→5/11) y nuestro reparto con el código real y las ventanas de sueño/entreno de la API (check/st05: SD.kt, WD.kt, windows.csv,
    scratchpad cmpst.py/fitst.py; línea base 92/58). 14 días con ≥ 16 h de pulso (21/10→4/11), error en puntos de % bajo/medio/alto:
    total 6,6/6,5/2,8 · sin actividad 11,4/15,2/4,3 (sesgo: medio +15, bajo −11, alto −4) · sueño 5,9/4,8/1,0. Ajustar la curva (pendiente,
    exponente, suelo): dejando un día fuera 6,5 → 4,5, PERO ajustando con 21–28/10 y probando 29/10–4/11 empeora (6,1 → 6,7–8,2): la 1.ª semana
    sobra medio y la 2.ª falta alto → contradictorio, NO se cambia. Pedir más capturas mensuales (cada una trae 30 días) para la ronda.
  - **Vista de tendencias como WHOOP (Android `StressTrendsActivity` + `ui/StressTrendChartView`, iOS `UI/StressTrends.swift`)**: apartado
    desplegable, ESTRÉS ALTO PROM. con ▲/▼ % frente al periodo anterior, S/M/6M (6M = barras por semana), fechas con < >, frase, barras al 100 %,
    "El promedio no incluye el día de hoy", "¿Qué es…?". `StressDays` guarda el reparto de cada día cerrado en stress_days.csv (mismo formato en
    Android e iOS; de 7 en 7 días). Código real: 22 días iguales al arnés, 2.ª vez desde la caché 0,4 s (check/st05/SC.kt).

- **5/11→6/11 (21.ª referencia, funcional 17:52–18:58 + pádel 20:35–22:03 la víspera, levantarse al baño 04:59–05:02)**: WHOOP (API)
  22:11:04Z–06:29:02Z (23:11–07:29), dormido 7:50, 28/273/90/108, 13 despertares, 96 %, VFC 78,0, FCR 60, resp 13,3, calificación 90 (93/84/96),
  recuperación 44. PulseApp iPhone (versión 5/11): 23:11–07:27, 7:39, 37/303/66/90, 92 %, VFC 76, FCR 62, resp 12,6, calificación 88 (94/82/92),
  recuperación 42. Código real (check/n06/N.kt) = app; 21 noches MAE D/L/P/R 8,7/22,4/11,5/15,9, VFC 1,37, FCR 0,62.
  - FCR +2: la 1.ª hora tras el pádel a 67 lpm. Repasadas las alternativas con 21 noches (check/fcr, scratchpad fcr.py): mediana solo dormido
    0,57 vs 0,62 (esta noche +1, la 20/10 −3) → diferencia mínima, no se cambia.
  - Profundo −24: capturas en check/hyp/n06 para la próxima ronda de fases. Huawei Watch Fit 3 esa noche: 23:14–07:30, 8:11, P 1:43 / L 4:55 / R 1:33
    (sin despierto) → solo de curiosidad, se calibra con WHOOP.
  - **Siesta mínima 20 → 45 min (6/11, Android + iOS `NAP_MIN_MINUTES` / `napMinMinutes`)**: "siesta" 5/11 19:58–20:19 (tumbado en la cama ~20 min,
    giro 1,6–2, FC 59–65) que WHOOP NO registró; tampoco 31/10 14:56–15:29 (33 min). La del 1/11 (105 min) sí. Export: las 15 siestas automáticas
    de WHOOP duran 59–190 min en cama (las de 25/45/120 min con hora en punto son a mano). Código real 14/10→5/11 (check/nap06/Np.kt): antes
    3 siestas, ahora solo la del 1/11. La falsa restaba ~20 min a la necesidad de la noche 5→6 (horas vs necesidad 94 % vs WHOOP 93 %; sin ella
    ≈ 90 %, con 11 min menos dormido que WHOOP). Una vez al instalar (`nap_clean` 1 / iOS `pulseapp_nap_clean`) se borran las siestas automáticas
    sin editar de < 45 min. Pregunta pendiente para la IA de WHOOP: duración mínima de una siesta automática.

- **6/11→7/11 (22.ª referencia, fútbol 20:56–22:08 la víspera; tumbado despierto con el móvil antes de dormirse y al despertar)**: WHOOP (API)
  22:39:20Z–08:19:01Z (23:39–09:19), dormido 9:21, 19/379/69/114, 6 despertares, 97 %, VFC 86,8, FCR 60, resp 13,5, calificación 85 (100/69/97),
  recuperación 63. PulseApp iPhone (versión 6/11): 23:02–09:48 (a las 9:20 marcaba 09:19 y siguió alargándose mientras estaba en la cama con el
  móvil), 10:10, 36/367/54/189, VFC 82, FCR 62, calificación 87 (100/72/94), recuperación 52. Código real (check/n07/N.kt) = app.
  - Causa: 23:02–23:34 y 09:20–09:48 la muñeca está TAN quieta como dormido (giro 1,4–1,5, 60 s quieto): el inicio por quietud y el modelo lo
    daban por sueño (09:20–09:48 como REM, pulso 63–73 frente a 55–58 justo antes).
  - **Inicio y fin despierto en la cama (7/11, Android + iOS `SleepStager.trimBounds(st, hr, gyro, steps, off)`)**:
    inicio → si en los primeros 40 min hay un despertar ≥ 5 min y antes de él ≥ 15 % de los minutos tienen giro ≥ 3 °/s (muñeca inquieta),
    la noche empieza tras ese despertar (7/11 21 % de minutos; el resto de noches 0–10 %: 26/10 y 5/11, con despertar de 6 y 11 min, 0 y 3 %).
    fin → desde un giro ≥ 6 / paso / despertar (en las últimas 2 h) el pulso se queda ≥ 7 lpm sobre la media hora anterior hasta el final
    (≥ 10 min) → la noche acaba ahí. Arnés check/edge07 (dump.csv + scratchpad edge.py, búsqueda de parámetros; la regla del inicio SIN el giro
    rompía 26/10 y 5/11, y el pulso no separa: muchas noches empiezan con +7–31 lpm). Código real 22 noches: inicio solo cambia 7/11
    (23:02 → 23:50, WHOOP 23:39: tras el recorte la 2.ª pasada marca 23:47–49 despierto); fin 2,6 → 1,5 min de error medio: 7/11 09:48 → 09:17
    (WHOOP 09:19), PERO 26/10 07:24 → 07:03 (WHOOP 07:17: siguió contando 14 min con el pulso alto) → solo respaldado por una noche; revisar
    con más mañanas en la cama. MAE D/L/P/R 9,0/21,9/11,6/18,7 → 8,7/24,5/10,9/17,5, VFC 1,53 → 1,47. 7/11: 28/308/70/162, VFC 90,4, FCR 61 →
    recuperación 64 (WHOOP 63; con su VFC/FCR la fórmula da 60; antes 52). Con datos hasta las 09:20 el fin es 09:20; desde 10 min después, 09:17
    fijo. Sigue: REM +48 / ligero −71 en esta noche larga (capturas en check/hyp/n07). `night_recalc_v14` / iOS 14.
    **Ajuste (7/11, tras el aviso del usuario: se durmió 23:39 y despertó 09:19)**: la 2.ª pasada del modelo ya no vuelve a exigir 10 min seguidos
    dormido al principio (`keepStart`: el despertar corto 23:47–49 retrasaba el inicio a 23:50) y el fin acaba en el ÚLTIMO giro ≥ 3 °/s o paso de
    los 3 min siguientes al giro que lo dispara (09:17 y 09:19 → 09:19). 7/11: 23:40–09:19 (WHOOP 23:39–09:19), 31/317/70/162, VFC 89,8, FCR 61 →
    recuperación 63 (WHOOP 63). Las otras 21 noches salen idénticas. Con datos hasta 09:21/09:25/09:28 el fin va por 09:20/09:24/09:26 y desde las
    09:30 (10 min de pulso alto) queda en 09:19 fijo.
    CI de iOS nuevo "Comprobar el recorte y las fases de la noche" (ios/Tests/stager: 7/11, 26/10 y 5/11 con SleepStager.stage completo, Swift = Kotlin).

- **7/11→8/11 (23.ª referencia, fútbol 16:59–19:55 esfuerzo 19,0 + 2 paseos la víspera, acostarse 01:46)**: WHOOP ORIGINAL (capturas; el usuario
  editó después el final a 10:08) 01:46–09:53, cama 8:07, dormido 7:49, 18/304/93/72, VFC 67,7, FCR 61, resp 13,3, calificación 79 (88/53/96),
  recuperación 36. PulseApp iPhone (versión 7/11): 01:42–10:08, 8:18, 8/304/90/104, 2 despertares (WHOOP 8), VFC 73, FCR 62, calificación 80
  (92/54/98), recuperación 40. Código real (check/n08/N.kt) = app; la versión del 5/11 (3550d1e, worktree /tmp/claude-0/old) da EXACTAMENTE lo
  mismo en esta noche → no es un empeoramiento por cambios recientes. 23 noches con el código actual: 16/10–30/10 MAE D/L/P/R 7,5/18,1/10,9/13,7,
  VFC 1,25; 1/11–8/11 13/32,9/10/26,9, VFC 2,31 → las noches viejas salen mejor porque se usaron para entrenar el modelo de fases y ajustar la VFC.
  - Despierto 8 vs 18: tras 3 h de fútbol casi sin moverse (28 giros de 6–31 °/s con ≥ 42 s quieto, 1 minuto con pasos) → las reglas de despierto no saltan.
  - Fin 10:08 vs 09:53: pulso 67–70 desde 09:44 con la muñeca quieta; la regla del fin (≥ +7 lpm) no salta (+2).
  - **VFC +5,4 (73,1 vs 67,7)**: con las fases EXACTAS de WHOOP (captura digitalizada, check/hyp/dig08.py → n08/hyp08.json) sale 71,9 → NO son las
    fases. Toda la noche sin fases 66,2. Probado con 23 noches (scratchpad v08b.py, v08c.py, v08d.py; dump check/n08/dump.csv): P+L actual LOO 1,98
    (≤2: 12, ≤3: 16) · solo toda la noche 3,27 · + REM / + toda la noche / + % REM / peso al final 2,0–4,6 · recortar diferencias 1–5 %, filtro 15–25 %,
    quitar tramos con latidos rechazados: 1,98–3,50; ninguna baja el 8/11 de 71 y ninguna mejora el conjunto. Ningún rasgo de la noche explica el
    error (|r| ≤ 0,32: duración, cobertura de RR, FCR, pulso 1.ª hora, P/L, variabilidad, % REM). Código real: 23 noches MAE 1,62, ≤2 en 14, ≤3 en 20.
    Con su VFC/FCR la fórmula de recuperación da 35 (WHOOP 36) → la recuperación +4 es solo la VFC. NO se cambia nada (no hay regla general).
  - **IA de WHOOP (8/11 tarde)**: VFC = varios tramos del sueño combinados, más peso al profundo y SOBRE TODO a su último tramo; no sabe las horas
    exactas ni si se reprocesa la señal en la nube. Probado otra vez con 23 noches (scratchpad v08e.py: peso creciente hacia el final y extra al último
    bloque de profundo de NUESTRAS fases): el 8/11 baja 73 → 70, pero el conjunto empeora (LOO 1,99 → 2,0–2,8) → no se aplica. Con las fases EXACTAS de
    WHOOP del 8/11 (v08f.py) su último bloque de profundo (05:05–05:22) da RMSSD 64,7 (WHOOP 67,7) y los primeros 60–89: cuadra con la IA en esta noche,
    pero el 23/10 con 8 noches y las fases de WHOOP "último profundo" daba MAE 9,8 → no es regla general. Revisar en la ronda de fases (si el profundo
    nuestro cae donde el de WHOOP, volver a probar el peso al último bloque).

- **8/11→9/11 (24.ª referencia, domingo tranquilo, ahorro de batería activo desde el sábado 13:00)**: WHOOP (API) 22:40:46Z–06:44:48Z (23:40–07:44),
  dormido 7:28, 36/235/140/74, 4 despertares, 93,6 %, VFC 86,96, FCR 58, resp 13,4, calificación 82 (89/66/94), recuperación 64; necesidad 504 min
  (470 + 2 + 32 deuda). PulseApp iPhone: a las 8:14 23:42–07:44, VFC 86, recuperación 63; a las 9:08 –07:49, VFC 87, recuperación 64; calificación 85
  (96/69/94). Código real con todos los datos (check/n09/N.kt): 23:42–07:48, 26/300/104/57, VFC 86,8, FCR 58.
  - **Fin de la noche 8/11 alargado hasta las 13:16 con los datos del domingo (9/11, Android + iOS `trimBounds`)**: tumbado despierto en el sofá/cama
    10:15–13:16 con la muñeca inquieta (giro ≥ 3 °/s en el 48 % de los minutos). Dormido, en 24 noches, ningún tramo de 45 min pasa del 24 %.
    Regla: desde un minuto inquieto hasta el final (≥ 45 min) Y sus primeros 45 min con ≥ 40 % de minutos inquietos → la noche acaba antes
    (`END_RESTLESS_MIN/FRAC` / `endRestlessMin/Frac`). Sin la 2.ª condición cortaba a las 09:03 (el tramo largo arrastraba minutos dormidos).
    24 noches: solo cambia la 8/11 → 01:42–09:52 (WHOOP original 09:53), 8/307/90/86. Test de Swift con la noche 8/11. `night_recalc_v15` / iOS 15.
    Esto también arregla la necesidad de la 9/11: con la 8/11 de 11 h dormida la deuda salía 0 (horas vs necesidad 96 %, WHOOP 89 %).
  - Fases 9/11: hipnograma de WHOOP leído (check/hyp/dig09.py → n09/hyp09.json, totales = API al minuto). De nuestros 104 min de profundo, 100 caen
    en el profundo de WHOOP (precisión 96 %), pero faltan 46 min: 04:21–04:42 (tenemos 04:27–04:35), 06:10–06:18 (nada), 01:48–01:51, 02:01–02:08,
    02:27–02:32. REM 38 de 81 coinciden. Para la ronda de fases.
  - **Batería (band_battery.csv 5/11→9/11)**: con movimiento 0,53–0,63 %/h (noche 0,53–0,56, día 0,62–0,69); sin movimiento (ahorro) sábado 13:06–16:40
    0,62 %/h, domingo 12:27–19:57 0,48 %/h. Diferencia ≤ 0,15 %/h (~1–3 % al día), del orden del ruido (escalones de 0,25–0,3 %). ~7 días por carga.

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
0. ~~Deslizar para actualizar~~ HECHO 24/10: Android `ui/PullScrollView` (umbral 80 dp, flecha ↓ que gira al pasar el umbral, logo girando,
   pide historial a la pulsera y recalcula; aviso negro "DATOS ACTUALIZADOS · SINCRONIZADO ✓ HH:MM" 2,2 s). iOS: el `PullOffsetKey` NO
   funcionaba en el iPhone → `.refreshable` nativo (ruedecita de iOS) + logo girando + mismo aviso (24/10).
0b. ~~Cambio de hora~~ HECHO 25/10 (desfase en las líneas cercanas al cambio + arreglo único del 25/10, ver 24→25).
1. ~~Prueba de 100 pasos~~ HECHA 24/10 16:34 (iPhone): 5166 → 5266 = 100 contados de 100 reales (motion_minutes: 16:34 90 pasos, 16:35 59).
   Andando normal (84–115 pasos/min) cuenta bien; no se toca. Falta: andar rápido/escaleras.
   25/10: fregar/gesticular de pie 1 min (12:59–13:00, ENMO 1825 mg) → 0 pasos. Sentado simulando andar (pierna + brazo) cuenta los pasos
   (inevitable: la muñeca no ve las piernas) y solo con el brazo suma a ratos 4–20/min (13:01–13:07). Racha mínima con ritmo 4 → 8
   (`ImuStepCounter.MIN_RUN` / iOS `minRun`; se suman los 8 al llegar). 12–25 % de los pasos de cada día están en minutos con < 20 pasos:
   validar con los pasos diarios de WHOOP.
   25/10 13:21: WHOOP NO contó esos pasos sentado. Gravedad media por minuto (motion_minutes): andando de verdad gx ≥ 0,8 en el 97 % de
   127 minutos (mediana 0,95: brazo colgando); sentado simulando gx −0,13…0,50. Posible filtro por orientación (contar solo con el brazo
   abajo) pero falta saber qué pasa andando con el móvil en la mano / manos en los bolsillos (12:42–12:43 y 12:55–12:57: 72/59/26/42 pasos con
   gx −0,77…−0,14, sin explicar). iOS: botón "Grabar prueba de pasos (20 min)" en Mi WHOOP → imu_prueba.csv (crudo 100 Hz,
   `ImuTestRecorder`) para afinarlo con una prueba guiada antes de tocar el contador.
   25/10 20:41 (imu_prueba.csv, check/imu/p1.csv, arnés check/imu/S.kt): el grabador BORRABA lo anterior al pulsar otra vez → solo llegó la
   última prueba (las de andar/escaleras se perdieron; arreglado: ahora añade con "#inicio,ms"). Contador actual: sentado pierna+brazo 15
   de 30, sentado solo brazo 29 de 30, de pie balanceando 20 de 30. **La orientación NO sirve**: brazo colgando ahora da gx −0,97 (por la
   mañana +0,95: la pulsera se puso al revés u otra muñeca) y sentado con el brazo colgando |gx| 0,8–1,0 = igual que andando. Giro medio
   en esas simulaciones 110–280 °/s (filtro actual > 250); falta el giro andando de verdad para decidir un umbral → repetir andar normal /
   móvil / bolsillos / rápido / escaleras en una grabación.
   25/10 20:58 (check/imu/p2.csv, 26 pasos cada una): contador actual andar normal 27, mirando el móvil 27, mano en el bolsillo 25 → bien.
   El usuario NO cambió la pulsera (brazo colgando gx −0,9 en las dos pruebas de hoy; el +0,95 de motion_minutes era otro dato, no fiarse).
   Rasgos (check/imu/feat.py): giro medio andar normal 118 °/s (por segundo hasta 164), móvil 31, bolsillo 57; sentado pierna+brazo 242,
   sentado brazo 209, de pie balanceo 116 (= andar, indistinguible). Candidato: bajar el tope de giro 250 → ~180 °/s (quita lo de sentado)
   PERO falta andar rápido y escaleras (más balanceo) antes de aplicarlo. sd|a|/giro no separa (andar 0,25 vs sentado 0,23).
   26/10 08:14 andar rápido 40 pasos (check/imu/rap.csv) → el contador daba **12**: giro 200–300 °/s (= sentado simulando), picos de 3 g y
   intervalos irregulares (0,32/0,63…) que rompían la racha. Escaleras 22 escalones + 3 pasos (esc.csv) → 26 bien. NINGÚN rasgo separa andar
   rápido de simular sentado (giro, sd|a|, alta frecuencia, frecuencia dominante: check/imu/feat2.py). Se prioriza andar de verdad:
   MAX_STEP_G 3 → 4, MAX_STEP_GYRO 250 → 350, ritmo 1,6 → 2,2 (Android + iOS; port Python check/imu/sc.py = Kotlin). Resultado: normal/móvil/
   bolsillo/rápido/escaleras 27/27/27/42/26 (reales 26/26/26/40/25); simulaciones sentado/de pie 64 → 84 falsos (inevitable).
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
