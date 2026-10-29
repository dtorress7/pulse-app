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
  al guardar una actividad con FC más alta (150–220 y ≤ +8 lpm sobre la actual). `Formulas.init(ctx)` en Main y servicios.
  Zonas 0–5 por % FCmáx (<50, 50–60, 60–70, 70–80, 80–90, >90).
- Esfuerzo = TRIMP Banister con reserva de FC, sólo minutos con FC ≥ 45 % FCmáx → 4,14·ln(1+TRIMP/2,6), máx 21.
  Misma curva para día y actividades. Error vs WHOOP: fútbol 0,7, global 1,7 (173 entrenos).
- Recuperación (23/10) = 64,28 + 89,74·(ln VFC − EWMA14 ln VFC) − 0,4625·(FCR − EWMA FCR), suelo, 1–99; −12 por cada z>2 de respiración.
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
- Necesidad de sueño = 470 min + max(0, strain−8)·6 + deuda. **Deuda (18/10, ajustada con 152 noches del export)** = max(0, (necesidad
  de esa noche − dormido) / 2) (`SleepPlanner.nextDebt`, MAE 1,5 min; la de antes ×0,7 sobre la base salía el doble). Sin dato esa noche: deuda/2.
  Hora de despertar editable (7:30 por defecto).
- **Regularidad (18/10, 145 noches del export)** = media de intersección/unión del tramo en cama de la última noche con cada una de las 3
  anteriores (eje desde las 12:00) × 100 − 7 (`Formulas.sleepConsistency(noches)`), MAE 4,9, 87 % a ±10. La de antes (sd de la hora de
  dormirse, 7 noches) tenía MAE 27. Ojo: esta semana WHOOP salió ~7 puntos por encima del export (92/89/64/76 vs J3 89/91/65/77 sin restar 7);
  revisar el −7 en la ronda grande.
- Calorías = Mifflin-St Jeor × (min transcurridos/1440) × 1,15 + kcal de actividades (Keytel).
- VO2máx = 15,3 × FCmáx / FC reposo, se recalcula sólo los martes.
- Estrés (23/10): ventanas de 5 min, z = 3,4·(FC−FCRbase)/(FCmáx−FCRbase) + 0,2·ln(VFCbase/VFC); estrés = 0,3 + 2,7·(1−e^(−max(z,0))).
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
  **Finales**: probado ajustar la regla de final (umbral, tolerancia, subida, quietud): dentro de muestra 142 → 105 min de error, pero dejando
  un entreno fuera EMPEORA (1141 → 1168) → no se toca. Los finales de WHOOP no siguen un patrón (22/10 alarga 15 min sentado; 26/10 corta al andar).

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
