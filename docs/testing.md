# Pruebas: matriz, resultados reales y limitaciones

Todo lo que aquí figura como **Aprobado** se ejecutó en esta máquina el 2026-10-09 y tiene su salida guardada en `docs/evidence/`. Lo que no se pudo probar, o depende de ti, está marcado como **Pendiente** o **No aplicable**, nunca como aprobado.

## Leyenda de estados

| Estado | Significado |
|---|---|
| **Aprobado** | Ejecutado de verdad; hay salida en `docs/evidence/` |
| **Aprobado (IA simulada)** | Ejecutado, pero la IA era el modelo simulado local (`LLM_PROVIDER=mock`), no un proveedor real |
| **Aprobado (IA real)** | Ejecutado contra Gemini (capa gratuita) con datos **sintéticos** |
| **Aprobado (variante)** | Ejecutado en una versión acotada de la suite (p. ej. sin la prueba de 90 s) |
| **No aplicable** | No se puede reproducir en este diseño (se explica por qué) |
| **Pendiente** | Falta una acción tuya; no se da por hecho |

## Cómo reproducirlo todo (PowerShell, desde la raíz del repositorio)

```powershell
docker compose up -d --build --wait                      # 4 servicios healthy
.\scripts\import-n8n.ps1                                  # credenciales + 3 workflows (importa, publica, reinicia, espera)
.\scripts\smoke-api.ps1                                   # 14 comprobaciones de la API
docker compose exec -T api python manage.py test --noinput  # 84 tests de Django (T21)
.\scripts\test-workflows.ps1                              # 115 tests unitarios de los nodos Code + deriva de JSON
.\tests\integration\wf01-intake.ps1                       # WF1   (51 comprobaciones)
.\tests\integration\wf02-triage.ps1                       # WF2   (46)   IA simulada
.\tests\integration\wf03-errors.ps1                       # WF3   (22)
.\tests\integration\wf02-gemini.ps1                       # IA real (9)  necesita GEMINI_API_KEY; solo datos sintéticos
.\tests\integration\credentials-wrong.ps1                 # T12d  (8)
.\tests\integration\pii-logs.ps1                          # T19   (11)   ejecútalo DESPUÉS de las suites (necesita tráfico en los logs)
.\tests\integration\production-mode.ps1                  # modo producción (9) recrea solo la API y la restaura
.\tests\integration\restart-persistence.ps1               # T15/T16 (10) reinicia y baja los contenedores, SIN -v
.\scripts\scan-secrets.ps1                                # T20
.\scripts\clean-install-test.ps1                          # T17: instalación limpia en un proyecto desechable (~7 min)
```

Las suites de integración hacen **inyección real de fallos** (paran/pausan contenedores, usan una clave errónea, etc.) y dejan el entorno como estaba. Necesitan que Docker Desktop esté arrancado y que `.env` tenga `QA_TOOLS_ENABLED=true` (valor por defecto del `.env.example`).

## Resultados por suite

| Suite | Comprobaciones | Resultado | Evidencia |
|---|---|---|---|
| Tests Django (T21) | 84 | 84 OK | `fase6-django.txt` |
| Unitarias de nodos Code + `published.js` + deriva de JSON | 115 | 115 OK, JSON al día | `fase6-unit.txt` |
| Smoke de la API | 14 | 14 OK | `fase2-django.txt`, y dentro de `fase6-clean-install.txt` |
| WF1 – recepción | 51 | 51 OK | `fase6-regresion-wf01.txt` |
| WF2 – IA + correo (IA simulada) | 46 | 46 OK | `fase6-regresion-wf02.txt` |
| WF3 – monitorización de errores | 22 | 22 OK | `fase6-regresion-wf03.txt` |
| WF2 con Gemini real (T10) | 9 | 9 OK | `fase6-regresion-gemini.txt`, `fase4-wf02-gemini.txt` |
| Credenciales incorrectas (T12d) | 8 | 8 OK | `fase6-credenciales-incorrectas.txt` |
| PII y secretos en logs (T19) | 11 | 11 OK | `fase6-pii-logs.txt` |
| Reinicio y persistencia (T15/T16) | 10 | 10 OK | `fase6-reinicio-persistencia.txt` |
| Modo producción (QA apagado) | 9 | 9 OK | `fase6-modo-produccion.txt` |
| Escaneo de secretos (T20) | 129 archivos | 0 hallazgos (con control positivo: detecta 3 patrones falsos) | `fase6-escaneo-secretos.txt` |
| Instalación limpia (T17) | 17 | 17 OK | `fase6-clean-install.txt` |

Todas las suites de integración de esta tabla (WF1, WF2, WF3, Gemini, T12d, T19, modo producción, T15/T16) se ejecutaron **con la protección SSRF de n8n activada**, que es la configuración final.

## Matriz de pruebas

Los IDs de la primera columna son los que imprimen las suites (`PASS  T05 …`).

| ID | Objetivo | Cómo se prueba | Resultado esperado | Estado real |
|---|---|---|---|---|
| **T01** | Solicitud válida de extremo a extremo | `POST /webhook/tickets` válido; se espera a que el ticket llegue a `notified` | 201; ticket en Django; WF1 y WF2 una sola vez; triage de IA válido; **un** correo en Mailpit con destinatario fijo | **Aprobado** (WF1: 4 comprobaciones; WF2: 6 + T01b) · **IA simulada** |
| T01b | Minimización de datos | El LLM simulado devuelve "eco" de lo que recibe | El LLM recibe correo y teléfono **redactados**; el correo interno al equipo sí lleva al cliente | **Aprobado (IA simulada)** |
| **T02** | Campos obligatorios ausentes | Cuerpo `{}` | 400 `validation_error` con un detalle por campo; no llega a Django ni a WF2; sin ticket | **Aprobado** |
| **T03** | Tipos incorrectos | Número/array/objeto en `subject`, `message`, `external_id`, `customer_email`, `source` | 400 con detalle del campo; sin ticket | **Aprobado** (6) |
| T03b | 400 que viene de Django | Valor que pasa el borde pero rompe una regla de negocio | Se devuelve al cliente con su detalle; la ejecución **no** cuenta como fallo | **Aprobado** |
| **T04** | Django responde 500 | Prefijo `QA-500-*` (inyección de fallos de QA) | 502 `upstream_error`; ejecución en error `http_5xx` reintentable; no se lanza WF2; sin ticket | **Aprobado** |
| **T05** | API inaccesible | `docker compose stop api` | 503 `upstream_unavailable`; error `connection`; al volver la API, el reenvío da 201 | **Aprobado** |
| **T06** | Timeout | Prefijo `QA-SLOW-*` (Django tarda 15 s; n8n espera 8 s) | 504 `upstream_timeout` a los ~8 s; error `timeout`; **el ticket sí existe** (timeout ambiguo) y WF2 no se lanzó | **Aprobado** |
| T06b | Recuperar un ticket atascado | Reenviar el mismo `external_id` tras el timeout | 200 `duplicate` con `reprocessing=true`; se lanza WF2; sigue habiendo un único ticket | **Aprobado** |
| **T07** | IA devuelve vacío | Marcador `[[MOCK:EMPTY]]` | Fallback por reglas con motivo `ai_empty`; triage completo y válido; un correo que declara el modo degradado | **Aprobado (IA simulada)** |
| **T08** | IA devuelve JSON inválido o fuera de contrato | Marcadores `NOT_JSON`, `WRAPPED_TEXT`, `BAD_CATEGORY`, `BAD_PRIORITY`, `MISSING_FIELD` | Siempre fallback con el motivo exacto; **nunca** se usa un valor inválido; un correo. Aceptados: `FENCED` (```json), `LONG_SUMMARY` (recortado a 280), `NEWLINES` (aplanado) | **Aprobado (IA simulada)** (13) |
| T08b | Salida de la IA con instrucciones maliciosas y claves extra | El modelo simulado intenta pedir enviar un correo a `attacker@evil.test` y borrar | El resumen se guarda como texto; **ningún** correo sale hacia el atacante; la clave `action` se ignora | **Aprobado (IA simulada)** |
| **T09** | Error del proveedor de IA | HTTP 429, HTTP 500 y respuesta lenta (>20 s) | Fallback con `ai_rate_limited` / `ai_provider_error` / `ai_timeout`; ticket notificado; **sin tormenta de reintentos** (1 llamada); un correo | **Aprobado (IA simulada)** (8) |
| **T10** | IA real | `LLM_PROVIDER=gemini`, datos sintéticos | T10a: triage válido con `source=ai`, un correo. T10b: con una **inyección real** sigue siendo un solo correo al equipo. T10c: con clave inválida el ticket se procesa por fallback con `ai_config_error` y WF3 lo registra | **Aprobado (IA real)** (9) |
| **T11** | Fallo de SMTP | `docker compose pause mailpit` (acepta la conexión y no responde) | WF2 acaba en error gestionado `smtp`, `retryable=manual`, con el ticket; el triage sí se guardó; **sin reintento automático** | **Aprobado** |
| **T12** | Token del webhook ausente/incorrecto | Sin cabecera, token erróneo, token interno en el webhook público y viceversa | 403 sin crear ejecución ni ticket | **Aprobado** (6: 4 en el webhook público y 2 en el interno de WF2) |
| T12 (WF2) | Entrada inválida al webhook interno | `ticket_id` inválido / inexistente | Fallo gestionado en `Validate input` / `Get ticket` (`http_4xx`, no reintentable) | **Aprobado** (3) |
| T12d | Credencial de n8n hacia Django incorrecta | Se sustituye la credencial por una clave errónea y se restaura con `import-n8n.ps1` | 502 `upstream_rejected`; `http_4xx` no reintentable; sin ticket; WF3 no puede registrar y llega una **alerta** sin la clave; tras restaurar, el flujo vuelve a funcionar | **Aprobado** (8) |
| T12 (SMTP) | Credencial SMTP ausente/incorrecta | — | — | **No aplicable**: Mailpit no tiene autenticación, así que no existe una "clave SMTP incorrecta" que reproducir. La plantilla de credencial SMTP queda lista para un SMTP real, **sin probar contra uno** |
| **T13** | Reintento tras un fallo | Reprocesar por el webhook interno tras restaurar el servicio | 202; ticket notificado con **un** correo; reutiliza el triage guardado (no llama otra vez a la IA); reprocesar uno ya notificado no manda un segundo correo | **Aprobado** (4) |
| **T14** | Duplicados | Mismo `external_id` dos veces | 201 y luego 200 `duplicate`; un ticket; WF2 una vez; **un** correo | **Aprobado** |
| T14b | Duplicados simultáneos | 5 peticiones en paralelo con el mismo `external_id` | Exactamente un 201 y cuatro 200; un ticket; **un** correo | **Aprobado** |
| **T15** | Reinicio de contenedores | `docker compose restart` | Los 4 servicios vuelven healthy; mismos datos, workflows publicados, credenciales y owner; el flujo completo funciona | **Aprobado** (5) |
| **T16** | Persistencia | `docker compose down` (**sin `-v`**) + `up --wait` | Quedan los 2 volúmenes; mismos datos; n8n no pide registro; las credenciales siguen descifrándose; el buzón de Mailpit **no** sobrevive (efímero por diseño) | **Aprobado** (5) |
| **T17** | Instalación limpia | `scripts\clean-install-test.ps1` en un proyecto Compose **desechable** (otros puertos, volúmenes y secretos) | Arranca vacío; `import-n8n.ps1` funciona sin crear antes el owner; smoke 14/14; WF1 48/48, WF2 44/44, WF3 21/21 (variantes sin las pruebas de >60 s); se elimina todo y **tu instalación no se toca** (148 tickets antes y después) | **Aprobado (variante)** · ver nota |
| **T18** | Entradas anómalas | JSON malformado, cuerpo de 1,5 MiB, `text/plain`, mensaje de 5001 caracteres, `GET`, array | 422 / 500 genérico de n8n / 400 / 400 / 404 / 400, sin trazas internas ni ejecuciones | **Aprobado** (7). Los códigos 422 y 500 son de n8n, no configurables |
| **T19** | PII y secretos en logs | Se buscan los datos sintéticos y los valores reales de `.env` en los logs de la API, n8n y PostgreSQL, **con control positivo** | 0 coincidencias | **Aprobado** |
| **T20** | Secretos en el repositorio | `scripts\scan-secrets.ps1` sobre lo que `git add -A` añadiría | 0 hallazgos; `.env` ignorado | **Aprobado** (129 archivos; con control positivo) |
| **T21** | Tests de Django | `manage.py test` | 84 OK | **Aprobado** |
| E1–E9 | Monitorización de errores (WF3) | Ver `docs/wf03-error-monitoring.md` | Cada fallo queda registrado con workflow, etapa, tipo y reintento; sin PII; alerta por correo si Django no está disponible; sin bucles | **Aprobado** (22). E9 (doble fallo) solo en la instalación real |
| Producción | Herramientas de QA apagadas | `tests\integration\production-mode.ps1`: recrea solo la API con `QA_TOOLS_ENABLED=false` y **siempre** restaura el modo desarrollo | El LLM simulado responde 404; `QA-500-` y `QA-SLOW-` ya no se interpretan (201 normal, sin demora); el log no declara la inyección activa; los 84 tests pasan; tras restaurar, el flujo completo funciona | **Aprobado** (9) |
| SSRF | Protección de n8n | Sondas dentro del proyecto desechable | `api` permitido; `mailpit`, `postgres` y `169.254.169.254` bloqueados; con la protección apagada conectan | **Aprobado** (5) |

**Nota sobre T17.** El plan inicial preveía `docker compose down -v` sobre tu instalación real. No lo ejecuté: habría borrado tus volúmenes y exigía tu permiso expreso. En su lugar, la instalación limpia se prueba en un proyecto Compose aislado (`tt-clean`) y el propio test comprueba que tu instalación sigue intacta. La diferencia que queda es que no se probó el borrado de *tus* volúmenes en concreto, pero sí que una instalación de cero funciona con los scripts del repositorio.

## Pruebas de las propias pruebas

Una prueba que nunca falla no demuestra nada. Por eso:

- **Mutaciones deliberadas**: se rompió a propósito el código en copias y se comprobó que las pruebas fallaban. Ejemplos reales: aceptar enteros como texto, `create()` en lugar de `get_or_create()` o autenticación que acepta cualquier clave (`fase2-django.txt`); no sanear el `external_id` o clasificar un timeout como conexión (`fase3-n8n-unit.txt`); no validar la categoría de la IA, dejar que el resumen elija el destinatario del correo o no redactar correos (`fase4-unit.txt`); dejar pasar PII en el evento de error (`fase5-unit.txt`). La corrección de `published.js` (abajo) tiene su propia mutación.
- **Controles positivos**: el detector de PII (T19) y el escáner de secretos (T20) se prueban primero contra un caso que **debe** encontrar; la sonda SSRF se prueba con la protección apagada; el contador de ejecuciones se calibra (T00).
- **Fallos reales, no simulados en el código**: se paran y pausan contenedores, se corta Django, se usa una clave errónea.

## Defectos encontrados durante el QA (y su causa raíz)

| Defecto | Causa raíz | Corrección | Verificación |
|---|---|---|---|
| Un teléfono seguido de punto se colaba sin redactar al LLM | La expresión regular exigía un límite que el punto no cumplía (`…678.`) | Lookahead `(?!\w\|\.\d)` en JavaScript y en Python | Tests de regresión en ambos lenguajes |
| n8n reescribía mensajes de error (p. ej. `ECONNREFUSED`) y se perdía la clasificación | `NodeError` sustituye 16 códigos por textos genéricos | El fallo viaja codificado en hexadecimal | Test con un `NodeOperationError` real |
| Tras importar versiones nuevas y reiniciar, n8n servía la versión anterior de los workflows unos segundos | n8n pasa a `healthy` ~15 s antes de reconciliar la publicación | `import-n8n.ps1` y los tests esperan con `published.js` | Instalación limpia |
| "Error workflow is not active" | En n8n 2.x el workflow de errores también debe estar **publicado** | `import-n8n.ps1` publica los tres | WF3 22/22 |
| Gemini 404 | `gemini-2.5-flash-lite` está retirado | Modelo `gemini-3.5-flash-lite` | T10 |
| Suites contaminadas con datos de ejecuciones anteriores (E4/E6/E7) | Contaban eventos globales | Se filtra por marca de ejecución y nombres únicos | Repetidas varias veces |
| **`published.js` daba "no listo" en una instancia con >1 h arriba** (Fase 6) | Exigía una fila `completed` en la tabla de publicaciones de n8n, y **n8n las borra a la hora** | La señal es ahora: sin publicaciones pendientes + triggers de la versión activa activados (la fila solo se exige si el workflow no tiene triggers). Se comprobó empíricamente que reiniciar las mismas versiones no abre ninguna ventana | 9 tests con una BD SQLite temporal, incluida la **mutación** (la regla antigua falla justo el test del caso real); `fase6-readiness-bug.txt` conserva el primer intento fallido |
| El control positivo de T19 no detectaba nada (Fase 6) | PowerShell 5.1 elimina las comillas dobles internas al invocar un `.exe`: el contenedor de control imprimía solo "cliente" | Argumento sin comillas internas | El control detecta ahora correo y teléfono; sin él, los "0 hallazgos" no valían |

Ninguno de los dos últimos era un fallo de los workflows ni de la API: eran defectos de mi propia herramienta de pruebas, detectados por la verificación y no por el usuario.

## Limitaciones conocidas y lo que NO se probó

- **Las capturas de pantalla (AC14) muestran la IA simulada**: el resumen dice *Simulated AI summary*. No hay capturas de Gemini real.
- **Reproducción por un tercero (AC13): pendiente.** La instalación limpia automática es un buen sustituto, pero no equivale a que otra persona siga el README en otra máquina.
- **Gemini real solo con datos sintéticos** y en la capa gratuita, que usa el contenido para mejorar los productos de Google. Los nombres de modelo se retiran con el tiempo.
- **Ningún SMTP real** (Mailpit nunca entrega correo). La plantilla de credencial SMTP no se ha probado contra un servidor real.
- **Sin pruebas de carga.** Solo concurrencia de 5 peticiones iguales (T14b). El rendimiento con miles de tickets no se midió.
- **Sin pruebas de la interfaz de n8n** (solo su API/webhooks y su base de datos en modo lectura).
- **Semántica *at-least-once* del correo**: si el proceso muere entre enviar el correo y marcar `notified`, un reproceso enviaría un segundo correo.
- **El registro de errores depende de Django**: si Django sigue caído tras los reintentos de WF3, solo queda la alerta por correo y el historial de n8n (E5/E9).
- **La clave de Gemini** se pegó en una conversación: hay que **rotarla** (revocarla y crear otra) antes de publicar nada (ver README).
- **El historial de ejecuciones de n8n** guarda los payloads durante 168 h.
- **Prueba de SMTP caído**: con el contenedor *parado* el comportamiento no es determinista (depende de la caché ARP de Docker); las pruebas usan `pause`.
- **Alertas sin deduplicación**: un fallo repetido genera una alerta por cada ejecución.

## Criterios de aceptación (plan inicial)

| ID | Criterio | Estado |
|---|---|---|
| AC1 | `docker compose up -d` deja los 4 servicios healthy | **Aprobado** (`fase1-entorno.txt`, `fase6-reinicio-persistencia.txt`) |
| AC2 | Django responde (health, CRUD) | **Aprobado** (smoke 14/14; 84 tests) |
| AC3 | n8n alcanza la API (WF1 crea el ticket) | **Aprobado** (T01) |
| AC4 | Los 3 workflows se importan y publican en instalación limpia | **Aprobado** (T17, proyecto aislado) |
| AC5 | Solicitud válida → 201 + triage + email | **Aprobado** (T01) |
| AC6 | Datos inválidos → 400 controlado | **Aprobado** (T02, T03, T18) |
| AC7 | IA: simulada verificable; Gemini probado | **Aprobado** (T07–T09 simulada; T10 real) |
| AC8 | Email confirmado en Mailpit; fallo SMTP gestionado | **Aprobado** (T01, T11, E2) |
| AC9 | Errores coherentes y registrados por WF3 | **Aprobado** (E1–E9) |
| AC10 | Tests de Django pasan | **Aprobado** (84) |
| AC11 | Persistencia tras `restart` y tras `down`/`up` | **Aprobado** (T15, T16) |
| AC12 | Sin secretos en Git | **Aprobado** (T20). Aún no hay commits: el escaneo cubre lo que `git add -A` añadiría |
| AC13 | El README reproduce el proyecto | **Pendiente** (validación humana) |
| AC14 | Capturas de ejecuciones reales | **Aprobado**: 13 capturas reales hechas por el autor en `docs/screenshots/` (galería en el README), revisadas una a una antes de publicarlas: sin tokens, claves ni datos personales reales |
| AC15 | Limitaciones y fallos conocidos documentados | **Aprobado** (este documento y `docs/security.md`) |
