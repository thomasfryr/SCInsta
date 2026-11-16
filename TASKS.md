# SCInsta — Estado de Implementación por Módulos

## Fase 0: Módulo 0 — Empaquetado IPA con URL Scheme propio, Bundle ID Spoofer y Keychain Sanitizer
- [x] Hook nativo `%hook NSBundle` (`-bundleIdentifier` -> `@"com.burbn.instagram"` para `mainBundle`) en `src/Features/General/BundleSpoof.xm`.
- [x] Interceptores `MSHookFunction` en `%ctor` (`SecItemCopyMatching`, `SecItemAdd`, `SecItemUpdate`, `SecItemDelete`) en `src/Features/General/BundleSpoof.xm`:
  - Eliminación dinámica de `kSecAttrAccessGroup` mediante `CFDictionaryCreateMutableCopy` para redirigir al Keychain privado local de `com.scinsta.app`.
  - Sanitización en `SecItemCopyMatching` cuando `status == errSecSuccess` pero `*result` es `NULL` o `kCFNull` (retornando `errSecItemNotFound` para evitar crash en `igd.mdcore.orchestrator` / `String._unconditionallyBridgeFromObjectiveC`).
- [x] Normalización en memoria `scinsta://` -> `instagram://` en `IGInstagramAppDelegate` (`src/Tweak.x`).
- [x] Creación de `url_scheme.plist` en la raíz del repositorio (`CFBundleURLName = com.scinsta.urlscheme`, `CFBundleURLSchemes = ["scinsta"]`).
- [x] Actualización de `build.sh` y `Makefile` (`Security` en `SCInsta_FRAMEWORKS`, exclusión de `FLEXing` en producción, limpieza de `PlugIns` con `-due`, Bundle ID `-b com.scinsta.app` e inyección de `url_scheme.plist`).
- **Estado:** Listo para compilar y probar en dispositivo.

## Fase 1: Preparación del Entorno Base en Debian Server
- [ ] Instalación de dependencias de sistema (`nodejs`, `npm`, `docker.io`, `usbmuxd`, `libimobiledevice6`, `libimobiledevice-utils`, `avahi-daemon`, `cloudflared`, etc.).
- [ ] Creación de estructura `/home/<usuario>/scinsta-infra/{push-server,dm-listener,ios-signer}`.

## Fase 2: Módulo 1 — Servidor Receptor Web Push y PWA para iOS (`/push-server`)
- [ ] Gestión de llaves VAPID, `.env` y persistencia en `subscriptions.json`.
- [ ] Endpoint `POST /api/notify` con Deep Linking dinámico (`scinsta://direct-thread?id=<threadId>` y fallback `scinsta://direct-inbox`).
- [ ] Frontend PWA (`manifest.json`, `sw.js`, `index.html`) y servicios `systemd` (`scinsta-push.service`, `scinsta-tunnel.service`).

## Fase 3: Módulo 2 — Listener Pasivo Ultra-Ligero de DMs (`/dm-listener`)
- [ ] Aislamiento de red en Playwright Chromium headless y bloqueo de recursos innecesarios/telemetría.
- [ ] Traducción 100% pasiva de `senderId` (`users_cache.json` + fallback DOM sin llamadas HTTP a Meta).
- [ ] Interceptor WebSocket/MQTT (`/ig_message_sync`), deduplicación circular y servicio `scinsta-listener.service`.

## Fase 4: Módulo 3 — Auto-Signer Inalámbrico iOS (`/ios-signer`)
- [ ] Contenedor Docker `anisette-v3-server` en `127.0.0.1:6969`.
- [ ] Servicio `netmuxd.service` e integración con `AltServer-Linux`.
- [ ] Script `resign.sh` con reintentos, alerta Push en caso de fallo y tarea `cron` cada 5 días.
