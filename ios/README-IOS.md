# PulseApp para iOS

Réplica de la app Android (mismo núcleo: protocolo WHOOP 5.0, HRV, esfuerzo, recuperación, sueño con 4 fases, estrés, actividades, pasos, exportación y registro).

## Cómo obtener el .ipa (sin Mac)
1. Sube a tu repo la carpeta `ios/` y el archivo `.github/workflows/build-ios.yml` (Commit).
2. En GitHub: pestaña Actions → "Build iOS" → Run workflow (también se lanza solo al subir cambios en `ios/`).
3. Al acabar, descarga el artefacto `PulseApp-ipa` (contiene `PulseApp.ipa`). Si falla, descarga `build-log` y envíamelo.
4. Instala el .ipa con Sideloadly o AltStore (Apple ID gratuito: caduca a los 7 días, hay que reinstalar/renovar).

## Notas
- Permiso Bluetooth: acepta el aviso al abrir. Modo en segundo plano: `bluetooth-central` + restauración de estado.
- Los CSV/logs están en la app Archivos → En mi iPhone → PulseApp.
- Pestaña Coach: marcador de posición, igual que en Android.
- iOS empareja con el sistema: si la WHOOP ya está conectada a la app oficial, PulseApp se engancha a esa conexión.
