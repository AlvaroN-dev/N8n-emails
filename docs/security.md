# Seguridad: controles, riesgos aceptados y qué falta para exponerlo

Este proyecto es un **entorno de desarrollo local**. Aquí se documenta qué controles existen y **cómo se comprobó cada uno**, qué riesgos se aceptan a propósito y qué habría que cambiar antes de exponerlo fuera de tu equipo. Cada afirmación remite a la prueba que la respalda (ver `docs/testing.md`).

## Controles implementados

### Exposición de red
- Todos los puertos publicados se enlazan a `127.0.0.1` (n8n 5678, API 8000, Mailpit 8025). **Comprobado**: por la IP de LAN los puertos no son accesibles (`docs/evidence/fase1-entorno.txt`).
- PostgreSQL (5432) y el SMTP de Mailpit (1025) **no se publican**: solo existen dentro de la red de Compose.

### Autenticación y autorización
| Punto de entrada | Mecanismo | Verificado |
|---|---|---|
| Webhook público de n8n (`/webhook/tickets`) | Cabecera `X-Webhook-Token` (credencial *Header Auth*). Sin token o con uno incorrecto → 403 **sin crear ejecución** | T12 |
| Webhook interno de WF2 (reproceso) | **Otro** token: ninguno de los dos sirve en el webhook del otro | T12 |
| API Django | Cabecera `X-API-Key` comparada en tiempo constante (`hmac.compare_digest`). Si el servidor no tiene clave configurada **no arranca** y nunca autentica (falla cerrado) | tests de Django, `smoke-api.ps1` |
| n8n → Django con una credencial incorrecta | La API la rechaza (401); WF1 responde 502 `upstream_rejected`, no reintenta y se avisa | T12d |

### Secretos
- `.env` está en `.gitignore`; sus secretos se generan aleatorios (64 caracteres hex) con `scripts/setup.ps1`, que **nunca sobrescribe** un `.env` existente.
- Los workflows **no leen variables de entorno** (n8n 2.x lo bloquea: `N8N_BLOCK_ENV_ACCESS_IN_NODE=true`); todo secreto vive en **credenciales cifradas** de n8n (`N8N_ENCRYPTION_KEY`).
- `scripts/import-n8n.ps1` genera las credenciales desde plantillas sin secretos y **borra** el archivo temporal siempre (`finally`).
- Escaneo de los 7 secretos del `.env` y del prefijo de la clave de Gemini sobre todo el árbol: 0 coincidencias fuera de `.env` (repetido en cada fase).

### Validación de entrada y límites
- Doble capa: validación de presencia y tipo en el borde (n8n) y reglas de negocio en Django (la fuente de verdad). Tipos **estrictos** (un número no se acepta como texto) y caracteres de control rechazados (evita inyección de cabeceras de correo y errores de PostgreSQL).
- Cuerpo máximo de webhook: 1 MiB (`N8N_PAYLOAD_SIZE_MAX`). n8n rechaza el exceso (T18) con un 500 genérico en lugar de 413: limitación de n8n, no ejecuta nada.

### IA: la salida de un modelo es un dato no confiable
- Contrato estricto con **lista blanca de claves**; categoría y prioridad solo de listas cerradas; el resumen se aplana a una línea y se recorta. El modelo **no elige** destinatarios, URLs ni acciones; el destinatario del correo es fijo.
- **Probado con inyección real** contra Gemini (T10b) y con un modelo simulado que devuelve instrucciones maliciosas y claves extra (T08b): ningún correo salió hacia `attacker@evil.test`.
- El texto del cliente se delimita y se declara dato no confiable; se neutraliza cualquier intento de cerrar el delimitador.
- **Minimización**: al LLM solo viajan asunto y mensaje con correos y teléfonos redactados (`[email]`, `[phone]`). Probado (T01b).

### Protección SSRF de n8n (activada, probada)
n8n 2.42 trae la protección **apagada**; aquí se activa (`N8N_SSRF_PROTECTION_ENABLED=true`), con excepciones mínimas: el host `api` y `127.0.0.1/32` (WF1 → WF2). En n8n v3 será el comportamiento por defecto.

**Cómo se probó** (`scripts/clean-install-test.ps1`, en un proyecto Compose desechable; evidencia `docs/evidence/fase6-clean-install.txt`):

| Sonda (workflow de prueba que hace una petición HTTP) | Resultado real |
|---|---|
| Hacia `api` (host permitido) | Conecta: *"Execution was successful"* |
| Hacia `mailpit` (red interna, no permitido) | **Bloqueada**: *"The request was blocked because it resolves to a restricted IP address"* |
| Hacia `postgres` (red interna, no permitido) | **Bloqueada** (mismo mensaje) |
| Hacia `169.254.169.254` (metadatos de nube) | **Bloqueada** (mismo mensaje) |
| Control: las mismas peticiones con la protección **desactivada** | La sonda a `mailpit` conecta: el bloqueo lo causa la protección, no otra cosa |

Además, las cuatro suites de integración (WF1, WF2, WF3 y Gemini real) pasan **con la protección activa** (`docs/evidence/fase6-regresion-*.txt`): la lista de excepciones es suficiente y no rompe el flujo.

### Contenedores
- La API corre como usuario sin privilegios (`uid 10001`), con gunicorn (no `runserver`) y `DEBUG=False`. Todos los servicios usan `no-new-privileges`.
- Versiones **fijadas** de todas las imágenes (n8n 2.42.6, PostgreSQL 17, Mailpit 1.31.4, Python 3.13) y de las dependencias Python.

### Herramientas de QA apagadas por defecto en el código
`QA_TOOLS_ENABLED` (inyección de fallos y LLM simulado) vale `false` si no se define. Verificado en modo "producción": el LLM simulado devuelve 404, los prefijos `QA-500-`/`QA-SLOW-` ya no se interpretan y los 84 tests pasan igualmente. El `.env.example` lo pone a `true` porque es el entorno de desarrollo y pruebas.

## `manage.py check --deploy` (3 avisos aceptados)
| Aviso | Por qué se acepta |
|---|---|
| `security.W003` (CSRF) | La API es JSON con autenticación por cabecera; **no usa cookies ni sesiones**, así que CSRF no aplica |
| `security.W004` (HSTS) y `security.W008` (redirección SSL) | Corresponden a un proxy TLS que no existe en local. **Obligatorios** si se expone |

## Privacidad y datos personales
- **Logs sin datos personales ni secretos** (T19, `docs/evidence/fase6-pii-logs.txt`): tras ejecutar todas las suites (que mueven correos, teléfonos y mensajes sintéticos), se buscaron esos datos y los **valores reales** de los secretos de `.env` en los logs de la API (788 líneas), n8n (246) y PostgreSQL (489): **0 coincidencias**. La prueba incluye un **control positivo** (un contenedor desechable que imprime un correo y un teléfono: el detector debe encontrarlos) y, de hecho, su primera versión falló por un error mío de comillas de PowerShell 5.1: el control lo detectó antes de dar por buenos los "0 hallazgos".
- **Alerta de WF3**: identifica workflow, etapa y tipo de fallo, pero no contiene el correo ni el teléfono del cliente (prueba E5) ni la clave errónea (prueba T12d).
- **Lo que SÍ guarda n8n** es el **historial de ejecuciones**, que contiene los payloads de los tickets (nombres, correos, mensajes). Está en el volumen `n8n_data` (no en Git) y se purga automáticamente a las 168 h (`EXECUTIONS_DATA_MAX_AGE`; comprobado en T19). Si el proyecto manejara datos reales habría que reducirlo más, o no guardar ejecuciones correctas.
- **Gemini (capa gratuita)**: solo recibe asunto y mensaje con correos y teléfonos redactados, y solo se probó con datos sintéticos.

## Riesgos aceptados (conscientemente)
| Riesgo | Contexto |
|---|---|
| Sin TLS | Todo es HTTP en loopback |
| Sin *rate limiting* ni bloqueo por intentos fallidos | Un token de 64 caracteres hace inviable la fuerza bruta local, pero habría que limitar en un entorno expuesto |
| Tokens sin rotación automática | Se rotan regenerando el `.env` y reimportando |
| Mailpit sin autenticación | Solo escucha en loopback y nunca entrega correo real |
| n8n con SQLite y *task runner* interno | Válido en desarrollo; n8n recomienda PostgreSQL y runners externos en producción |
| Gemini (capa gratuita) usa los datos para mejorar los productos de Google | Solo se envían datos **sintéticos**; la prueba real está marcada como tal |
| El correo interno al equipo incluye el correo del cliente | Es su cometido; la alerta de WF3 y los logs no lo incluyen |
| El registro de errores depende de Django | Si cae más que los reintentos de WF3, queda la alerta por correo y el historial de n8n |

## Antes de exponerlo fuera de tu equipo (lista de comprobación)
1. **No publicar el editor de n8n.** Solo `/webhook/*` detrás de un proxy inverso con TLS.
2. Poner el proxy delante con *rate limiting* y revisar `N8N_SECURE_COOKIE` (el valor seguro por defecto ya está).
3. `QA_TOOLS_ENABLED=false` y `DJANGO_DEBUG=false`; proveedor de IA real (no `mock`).
4. Rotar **todos** los secretos del `.env` (incluida la clave de Gemini) y no reutilizar los de desarrollo.
5. Activar HSTS y la redirección SSL en Django (`SECURE_HSTS_SECONDS`, `SECURE_SSL_REDIRECT`) tras el proxy.
6. n8n sobre PostgreSQL, runners de tareas externos y revisar la retención del historial (contiene los payloads).
7. Sustituir Mailpit por un SMTP real con credenciales propias (la plantilla de credencial SMTP está lista para ello).
