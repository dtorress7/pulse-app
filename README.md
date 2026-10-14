# PulseApp Android — Fase 1

App nativa Android que se conecta por Bluetooth al reloj y registra el
pulso en segundo plano (pantalla bloqueada incluida) usando un
**foreground service**, guardándolo en un CSV local.

## Qué hace esta fase 1
- Escanea y conecta con tu reloj (servicio BLE estándar Heart Rate 0x180D)
- Corre como servicio en primer plano (notificación persistente) para
  que Android no lo mate en segundo plano
- Reconecta sola si se pierde la conexión
- Guarda cada lectura (con RR intervals si el reloj los manda) en
  `hr_log.csv` dentro de almacenamiento propio de la app

## Cómo compilarlo e instalarlo

### 1. Sube este proyecto a GitHub
1. Crea un repositorio nuevo en github.com (puede ser privado)
2. Sube TODO el contenido de esta carpeta

### 2. Compílalo con GitHub Actions
1. Pestaña **Actions** → workflow "Build APK" → **Run workflow**
2. Espera ~3-5 minutos
3. Entra en la ejecución terminada → **Artifacts** → descarga
   **PulseAndroid-apk**

### 3. Instálalo en el Android
1. Pasa el `.apk` descomprimido al móvil Android (por cable, Drive,
   Telegram... lo que te sea más cómodo)
2. Ábrelo desde el explorador de archivos del móvil
3. Si Android avisa de "orígenes desconocidos", ve a Ajustes y permite
   instalar esta app — es normal para apps fuera de Google Play
4. Instálala y ábrela

### 4. Primer uso
1. Dale a **"Buscar dispositivos"** — te pedirá permisos de Bluetooth,
   acéptalos
2. Toca tu reloj en la lista
3. Debería aparecer una notificación persistente ("PulseApp: Conectado")
   y el número de pulsaciones actualizándose en pantalla
4. Bloquea la pantalla y espera unos minutos — al desbloquear, el
   contador de "lecturas guardadas" debería haber seguido subiendo

### Ver los datos guardados
El CSV está en:
`Android/data/com.pulseapp.android/files/hr_log.csv`
Puedes verlo con cualquier explorador de archivos del móvil (como
"Archivos" de Google), o conectando el móvil por USB al PC.

## Siguiente paso
Si confirmas que sigue registrando datos con la pantalla bloqueada
durante un buen rato (prueba a dejarlo toda una noche si puedes),
pasamos a la Fase 2: HRV, frecuencia cardíaca en reposo y detección
de sueño a partir de estos datos. Y en paralelo podemos retomar la
versión iOS con lo aprendido aquí.
