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
Base de datos: versión 8, migraciones 1→8 registradas en `AppDatabase.kt`.

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
  `SleepPlanner`, `StressCalculator`, `CalorieCalculator`, `ActivityRecorder`, `RespiratoryRateCalculator` (aparcado).
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
  respiración z>2. Sin línea base: referencia 95 ms. El SUEÑO NO entra (en sus datos no cambia la nota).
  Comprobado en Kotlin con 155 noches: MAE 6,4, ±10 puntos 84 %, color igual 85 %.
- Calificación sueño = 0,281·horas vs necesidad (máx 100) + 0,202·eficiencia + 0,288·regularidad + 19,6 (MAE 1,9).
  Es lo que muestra el anillo de Sueño del inicio. Regularidad = 100 − sd(hora de dormirse, 7 noches)/120·100.
- Estrés: el export de WHOOP no trae estrés → no se puede calibrar; se mantiene la fórmula propia.
- FC reposo = mediana de la ventana de sueño (cuadra con WHOOP: 58 vs 57, 59 vs 59).
- VFC = RMSSD de RR nocturnos, filtrando saltos >20 %.
- Sueño: sólo 20:00–09:00, medias por minuto, umbral 1,25 × media del 10 % más bajo, tolera 20 min por encima,
  hueco >3 min = desconexión, mínimo 90 min, se coge **la última** ventana válida.
- Necesidad de sueño = 470 min + max(0, strain−8)·6 + deuda (decae ×0,7/día). Despertar fijo 7:30.
- Calorías = Mifflin-St Jeor × (min transcurridos/1440) × 1,15 + kcal de actividades (Keytel).
- VO2máx = 15,3 × FCmáx / FC reposo, se recalcula sólo los martes.
- Estrés: ventanas de 5 min, (subida FC·0,5 + caída VFC·0,5)·3 → 0–3 (bajo/medio/alto).
- Actividad automática: media 4 min >60 % FCmáx durante 8 min empieza; <55 % 5 min termina.
- SpO₂ es imposible offline (los canales rojo/IR no se muestrean a la vez). Las puntuaciones oficiales de WHOOP
  se calculan en su nube y no se pueden leer.

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
  - Gasta 1,5–2,3× batería. **Falta encontrar la orden de PARAR** (probar 82 STOP_RAW_DATA).
- **Historial (14/10, basado en los proyectos abiertos goose y noop, que ya descargan la 5.0)** — en `WhoopBackgroundService`:
  conexión: HELLO → SET_CLOCK (10, **8 bytes** [unix u32][0×4]; si no, la pulsera cree que perdió la hora y no entrega
  historial) → GET_CLOCK (11, vacío) → EXIT_HIGH_FREQ_SYNC (97,[0]) → orden 3 [1] → a los 1,5 s SEND_HISTORICAL_DATA (22,[0]),
  y repetir cada 15 min. Tramas: tipo en [8], seq/versión en [9], clase en [10]. METADATA 49 (o 56, clase u16 en [10..11]):
  1 START, 2 END, 3 COMPLETE. Confirmar cada END con HISTORICAL_DATA_RESULT (23) payload `[01] + frame[21..29)`.
  Lo confirmado la pulsera lo da por entregado → la app de WHOOP ya no lo tiene: por eso `ackMode` (−1 sin decidir,
  0 WHOOP conserva, 1 PulseApp descarga todo), se pregunta con `AckModeDialog`. Sin confirmar solo llega el 1.er bloque.
  Reensamblado genérico por característica (AA 01 declLen; total = declLen+8). 43/51 = IMU. 36/38 respuestas (cmd [10], resultado [12]).
  Orden 63 SEND_R10_R11_REALTIME [0]/[1] = parar/activar el chorro crudo (IMU). `buildCommand` rechaza las órdenes prohibidas.
  Pendiente de confirmar con datos reales: que llegan los bloques y que el registro v18 cuadra con su hora.
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

## Pendiente (en orden)
1. Ajustar el contador de pasos con una prueba de 100 pasos contados.
2. Orden de parar el IMU antes de usarlo de noche.
3. Clasificador de sueño en **4 fases** (Despierto/Ligero/Profundo/REM) con movimiento + FC + VFC, y despertares por movimiento.
4. Integrar movimiento en Sueño, Recuperación, Strain, actividades automáticas y pasos en el inicio.
5. Historial de la pulsera con ACK (caso fútbol). 6. Frecuencia respiratoria por análisis espectral. 7. Coach (en espera).
