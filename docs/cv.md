# Cómo presentar este proyecto (CV, LinkedIn, entrevistas)

**Regla de oro: es un proyecto personal de aprendizaje.** No se ha usado en producción, con clientes ni con datos reales. Preséntalo así y todo lo que digas se podrá comprobar abriendo el repositorio. Cada afirmación de abajo remite a su evidencia.

## Descripción para el CV

**Español (3 líneas)**

> **ticket-triage-n8n** — Proyecto personal · n8n, Django REST Framework, PostgreSQL, Docker Compose
> Sistema de triage automático de tickets de soporte: recepción por webhook, validación, persistencia idempotente, clasificación con IA (simulada y Gemini) y notificación por correo, con registro de errores sin datos personales.
> Probado con fallos reales inyectados (84 tests de Django, 115 unitarios y más de 160 comprobaciones de integración). Código: github.com/&lt;tu-usuario&gt;/ticket-triage-n8n

**English (3 lines)**

> **ticket-triage-n8n** — Personal project · n8n, Django REST Framework, PostgreSQL, Docker Compose
> Automated support-ticket triage: webhook intake, validation, idempotent persistence, LLM classification (mock and Gemini) and email notification, with PII-free error tracking.
> Tested with real fault injection (84 Django tests, 115 unit tests, 160+ integration checks). Code: github.com/&lt;your-user&gt;/ticket-triage-n8n

## Viñetas (elige 3–4; todas son verificables)

- Diseñé y construí un flujo de automatización con **n8n** (3 workflows como código, con detección de deriva) conectado a una **API Django REST** y **PostgreSQL**, orquestado con **Docker Compose** y reproducible desde cero con scripts (instalación limpia verificada automáticamente). → `docs/evidence/fase6-clean-install.txt`
- Traté la **salida del LLM como dato no confiable**: contrato estricto con lista blanca, *fallback* por reglas que se declara en el correo y pruebas con respuestas vacías, JSON roto, categorías inventadas, 429, lentitud e inyección de instrucciones (modelo simulado y Gemini real con datos sintéticos). → `docs/testing.md` (T07–T10)
- Garanticé **idempotencia** con restricción `UNIQUE` en base de datos y la probé con 5 peticiones simultáneas (un ticket, un correo); razoné y documenté dónde **no** reintentar (efectos laterales). → T14b, `docs/architecture.md`
- Verifiqué la fiabilidad con **fallos reales** (contenedores parados y pausados, timeouts, credenciales erróneas) y con *pruebas de las pruebas* (mutaciones deliberadas y controles positivos). Encontré y corregí defectos, incluidos errores de mis propias herramientas de prueba, y los documenté con su causa raíz. → `docs/testing.md`
- Apliqué seguridad básica: secretos fuera de Git (escáner propio con 0 hallazgos), puertos solo en loopback, tokens por webhook, **protección SSRF** de n8n con lista mínima de excepciones (bloqueo comprobado), redacción de datos personales antes del LLM y en los registros (comprobado en los logs). → `docs/security.md`

## Competencias que SÍ demuestra el proyecto (con evidencia)

| Competencia | Dónde se ve |
|---|---|
| Orquestación y automatización con n8n 2.x (webhooks, error workflow, credenciales, publicación, workflows como código) | `n8n/src/`, `docs/wf02-ai-triage.md`, `docs/wf03-error-monitoring.md` |
| Diseño de API REST con DRF: validación estricta, autenticación por clave, idempotencia, errores consistentes | `backend/`, `docs/api.md`, 84 tests |
| Docker Compose: healthchecks, volúmenes, redes, imágenes fijadas, usuario sin privilegios | `docker-compose.yml`, `backend/Dockerfile` |
| Integración de LLM con control de riesgos (validación de salida, *fallback*, defensa ante inyección) | T07–T10, `docs/wf02-ai-triage.md` |
| Pruebas: unitarias, integración con inyección de fallos, mutación, controles positivos | `n8n/tests/`, `tests/integration/`, `docs/testing.md` |
| Seguridad y privacidad básicas | `docs/security.md`, T19, T20, SSRF |
| Depuración con causa raíz (p. ej. n8n borra filas de su tabla de publicaciones a la hora; PowerShell 5.1 elimina comillas dobles) | `docs/testing.md`, sección de defectos |
| Documentación técnica clara y honesta con sus límites | Todo `docs/` |
| Scripting en PowerShell para automatizar instalación y pruebas en Windows | `scripts/`, `tests/integration/` |

## Lo que NO demuestra (no lo afirmes)

- Experiencia en **producción**, con usuarios o clientes reales, ni mantenimiento a largo plazo.
- **CI/CD**: no hay pipeline (está en *Mejoras futuras*).
- **Escalabilidad y rendimiento**: no hay pruebas de carga; n8n va en SQLite y sin modo cola.
- **Nube**, Kubernetes u observabilidad real (métricas, trazas, alertas externas).
- **SMTP real**: solo Mailpit. **Otros proveedores de IA**: solo el modelo simulado y Gemini (capa gratuita, datos sintéticos).
- **Medición de calidad de la clasificación**: no hay conjunto de evaluación; se prueba que la salida respeta el contrato, no que sea la más acertada.
- No inventes métricas de negocio ("redujo el triage un X %"): no existen.

## Preguntas probables en entrevista (respuestas ancladas en el proyecto)

**¿Por qué no reintentas automáticamente la creación del ticket?** Porque un timeout es ambiguo: Django puede haber terminado. Un reintento recibiría `duplicate` y el triage nunca se lanzaría. La idempotencia protege los datos, no el flujo; por eso un ticket atascado (más de 120 s sin notificar) se reprocesa al reenviarlo. (T06/T06b)

**¿Qué haces si el modelo devuelve basura?** Nunca se usa sin validar: JSON estricto, categoría y prioridad de listas cerradas, claves permitidas, resumen aplanado a una línea. Si falla, *fallback* por reglas con motivo (`ai_invalid_json`…) y el correo lo declara. Si es un problema de configuración (clave inválida) además falla la ejecución para que WF3 lo registre. (T07–T10c)

**¿Cómo evitas duplicar correos?** Una guardia atómica en la base de datos (`POST /notified/` marca una sola vez) y sin reintento automático del envío. Limitación asumida: semántica *at-least-once* si el proceso muere justo entre enviar y marcar.

**¿Cómo sabes que tus pruebas valen?** Las rompo a propósito (mutaciones) y uso controles positivos. Ejemplo real: el control de mi prueba de PII no detectaba nada por un problema de comillas de PowerShell 5.1; sin ese control habría dado por buenos unos "0 hallazgos" falsos. (T19)

**¿Qué cambiarías para producción?** La lista de `docs/security.md`: TLS y *rate limiting* en un proxy, n8n sobre PostgreSQL con runners externos, SMTP real, rotación de secretos, menos retención del historial (guarda payloads) y patrón *outbox* para el correo.

## Texto para el "About" del repositorio en GitHub

> Triage automático de tickets con n8n + Django REST + PostgreSQL + IA (simulada o Gemini) + correo. Proyecto personal con pruebas de fallos reales, validación estricta de la salida del LLM y reproducible con Docker Compose.

Temas sugeridos: `n8n` `django-rest-framework` `docker-compose` `llm` `automation` `postgresql` `powershell` `idempotency` `portfolio`
