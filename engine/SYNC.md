# engine — el motor y su sync con upstream

`engine/rustdesk/` es un **snapshot** de [rustdesk/rustdesk](https://github.com/rustdesk/rustdesk)
(tag en [`BASELINE`](BASELINE)) más **nuestros cambios** aplicados encima.
No hay merges de fork: el modelo es *snapshot puro → re-aplicar nuestro diff*.

## Comandos

```sh
bash engine/diff.sh --stat    # auditar QUÉ es nuestro (diff completo vs upstream)
bash engine/update.sh 1.5.0   # actualizar el motor a un tag nuevo
```

`update.sh`: (1) extrae nuestro diff total contra el baseline, (2) commitea el
snapshot puro del tag nuevo (`git read-tree` — modos/blobs exactos, clave en Windows),
(3) re-aplica nuestro diff con 3-way en el índice — conflictos quedan marcados si
upstream tocó lo mismo, (4) actualiza `BASELINE` y registra la corrida acá abajo.
El commit final lo hace uno tras revisar/compilar. Self-test del mecanismo: actualizar
al MISMO tag debe reconstruir `engine/rustdesk/` idéntico (diff 0).

## Qué es nuestro (resumen del delta)

~93 archivos sobre upstream 1.4.9:

| Área | Qué |
|---|---|
| `src/` | serverless (rendezvous→127.0.0.1), CM headless `--cm-no-ui`, discovery activo LAN+Tailscale (`lan.rs`), sin tray en builds no-flutter |
| `libs/scrap` | filtro de displays espejados en macOS (`CGDisplayMirrorsDisplay`) |
| `libs/hbb_common` | defaults serverless en config |
| `flutter/` | UI del cliente: sin IDs/cuentas/chat, botón SimpleDisplay, fix eco de cursor, bridge generado commiteado |
| `res/`, `fastlane/` | assets que upstream no trackea (se fuerzan al repo) |

## Historial de sincronizaciones

| Fecha | Cambio | Resultado |
|---|---|---|
| 2026-08-18 | snapshot inicial de upstream **1.4.9** + parches serverless | fork nace |
| 2026-08-19 | self-test: update 1.4.9 → 1.4.9 | ✓ identidad (diff 0, 93 archivos re-aplicados) |
| 2026-08-19 | self-test layout sync: 1.4.9 → 1.4.9 | ✓ mecanismo verificado |
