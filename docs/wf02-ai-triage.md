# WF2 · `02 - AI triage and notification`

Clasifica un ticket con un LLM, **valida** lo que devuelve, guarda el triage en Django y avisa al equipo por correo. Se dispara por un webhook interno (`POST /webhook/internal/ticket-triage`, token distinto del público) que llama WF1 o una persona para reprocesar.

## Flujo de nodos

```
Webhook interno (202) → Validate input → Get ticket → Already notified? ─sí→ Skip (fin)
                                                          └no→ Already triaged? ─sí────────────────────────┐
                                                                  └no→ Prepare AI input → Triage with AI ┐    │
                                                                        (OpenAI Chat Model)    ok │  error │    │
                                                                             Validate AI output ←─┘  AI call failed
                                                                                      └────→ Save triage ──────┴→ Compose email
Compose email → Send notification email → Mark notified → ¿fallo de configuración de la IA? ─sí→ Report failure (Stop and Error)
```

| Nodo | Qué hace / por qué |
|---|---|
| **Validate input** | `ticket_id` debe ser un entero positivo; si no, **falla la ejecución** (el webhook ya respondió 202: no hay a quién contestar y un llamante autenticado que envía basura es un bug) |
| **Get ticket** | `GET` a Django. Reintento: 2 intentos (lectura idempotente) |
| **Already notified?** | Guardia anti-duplicados: un ticket ya notificado termina aquí sin enviar nada |
| **Already triaged?** | Si ya tiene triage (p. ej. falló el correo), **reutiliza** el guardado: no vuelve a llamar a la IA (coste y no determinismo) |
| **Prepare AI input** | Construye el prompt con **solo asunto y mensaje**, con correos y teléfonos **redactados**; neutraliza etiquetas `</ticket>` del texto del cliente; calcula ya el triage por reglas por si la IA falla |
| **Triage with AI** | *Basic LLM Chain* + *OpenAI Chat Model* (Chat Completions, `temperature 0`, timeout 20 s, 1 reintento del cliente). Su salida de error se encamina a **AI call failed** |
| **Validate AI output** | Contrato estricto (ver abajo). Si no se cumple → triage por reglas + motivo |
| **Save triage** | `PATCH` a Django (idempotente, 2 intentos) |
| **Compose email** | Asunto, cuerpo y **destinatario FIJO** (`support-team@example.test`): nada del ticket ni del modelo puede cambiarlo |
| **Send notification email** | SMTP (Mailpit). **Sin reintento**: repetir podría duplicar el correo |
| **Mark notified** | `POST` atómico en Django (idempotente) |
| **Report failure** | Solo si el proveedor de IA rechazó la configuración: la ejecución queda en error **después** de procesar el ticket, para que WF3 lo registre |

## Contrato de la salida de la IA (la salida de un modelo es un dato **no confiable**)

El prompt pide un único objeto JSON con `category`, `priority` y `summary`. Se acepta **solo** si:

- Es JSON puro **o** está dentro de un bloque ` ```json ` (Gemini 3.5 lo devuelve así; comprobado). **No** se extrae JSON de entre prosa.
- `category` ∈ `billing | technical | account | feature_request | other` y `priority` ∈ `low | medium | high | urgent` (se normalizan mayúsculas/espacios).
- `summary` es texto no vacío; se aplana a **una línea** (se eliminan saltos de línea y caracteres de control) y se recorta a **280**.
- **Lista blanca de claves**: cualquier otra clave del modelo (`send_email_to`, `action`…) se **ignora**. El modelo no elige destinatarios, URLs ni acciones.

Si falla, **no se oculta**: el ticket se triaja por reglas y queda `triage_source=fallback` + `triage_reason`, y el correo lo dice.

| `triage_reason` | Causa | ¿Se reporta como fallo de configuración? |
|---|---|---|
| `ai_empty`, `ai_invalid_json`, `ai_invalid_category`, `ai_invalid_priority`, `ai_invalid_summary` | La salida no cumple el contrato | No |
| `ai_rate_limited` (429), `ai_timeout`, `ai_provider_error` (5xx), `ai_error` | Fallo transitorio / desconocido del proveedor | No |
| `ai_auth_error` (401/403), `ai_config_error` (400/404) | Clave inválida, modelo retirado, URL base errónea | **Sí** (Report failure → WF3) |

## Privacidad

- Al LLM solo viajan asunto y mensaje con correos/teléfonos sustituidos por `[email]`/`[phone]`. **Probado** (T01b): con el LLM simulado en modo "eco" el resumen devuelto no contiene el correo ni el teléfono.
- El correo interno al equipo **sí** incluye el correo del cliente (es su cometido).
- La capa gratuita de Gemini usa el contenido para mejorar productos de Google: **solo datos sintéticos**.

## Proveedores de IA

Una sola credencial n8n (`LLM provider (OpenAI-compatible)`) cuyo contenido genera `scripts/import-n8n.ps1` según `LLM_PROVIDER` en `.env`:

| `LLM_PROVIDER` | Qué es | Requisitos |
|---|---|---|
| `mock` (por defecto) | LLM **simulado** de Django (`/qa/llm/v1`), determinista, sin cuentas ni coste. **Las pruebas con él son "IA simulada"**, no prueban un modelo real | `QA_TOOLS_ENABLED=true` |
| `gemini` | Google Gemini por su endpoint compatible con OpenAI. **IA real** | `GEMINI_API_KEY` y red |

Cambiar de proveedor: editar `LLM_PROVIDER` y ejecutar `.\scripts\import-n8n.ps1`. El workflow no cambia. El nombre del modelo (`gemini-3.5-flash-lite`) está en `n8n/src/workflows/02-ai-triage-notify.js`; **los modelos de la capa gratuita se retiran con frecuencia** (`gemini-2.5-flash-lite` devolvía 404 "no longer available to new users").

## Reintentos y duplicados

| Operación | Reintento | Motivo |
|---|---|---|
| Lecturas/escrituras idempotentes en Django | 2 intentos | Repetir no cambia el resultado |
| Llamada al LLM | 1 reintento del cliente | Sin efecto lateral externo (observado: 1 llamada por 429/500) |
| **Correo** | **Ninguno** | Repetir podría duplicarlo. Si falla: ejecución en error + reproceso manual |

Reprocesar (`POST /webhook/internal/ticket-triage {"ticket_id": N}`) es seguro: un ticket notificado se detiene en la guardia y uno ya triado reutiliza su triage. Limitación conocida: si el proceso muere **entre** enviar el correo y marcar `notified`, un reproceso enviaría un segundo correo (semántica *at-least-once*; la alternativa *at-most-once* podría perder avisos).

## Comportamientos reales observados (no supuestos)

- **SMTP caído**: con el contenedor **pausado** (acepta la conexión y no saluda) el envío falla de forma determinista a los ~31 s: `The connection timed out…` en el nodo *Send notification email*. Con el contenedor **parado** depende de la caché ARP de Docker: a veces falla a los ~15 s (`host is unreachable`) y a veces el `connect` se queda reintentando SYN hasta que el servicio vuelve y **entonces el correo se entrega** (sin duplicado, porque no hubo sesión SMTP). Siempre acotado por el `executionTimeout` de 90 s.
- **Tras importar versiones nuevas y reiniciar n8n**, `healthy` llega antes que la reconciliación de publicaciones (~15 s): durante ese lapso se ejecuta la versión **anterior** del workflow. `import-n8n.ps1` y los tests esperan a que la versión activa esté realmente en marcha (`n8n/src/tools/published.js`). Un reinicio de las **mismas** versiones no abre esa ventana (los triggers son persistentes). Ojo: n8n **borra** las filas completadas de su tabla de publicaciones a la hora, así que "ya reconcilió" no puede exigir que esa fila exista (error real encontrado y corregido en la Fase 6; ver `docs/testing.md`).
- n8n **reescribe** los mensajes de error de nodos HTTP/LLM con textos genéricos (p. ej. un 400 de Gemini por clave inválida llega como *"Bad request - please check your parameters"*), por eso se clasifica también por código HTTP.
- n8n **sustituye** cualquier mensaje de `Stop and Error` que contenga códigos como `ECONNREFUSED` o `ENOENT`; por eso el fallo viaja codificado en hexadecimal (ver `docs/api.md`).
