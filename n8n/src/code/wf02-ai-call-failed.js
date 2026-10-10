// WF2 - "AI call failed"
// Salida de error del nodo de IA (proveedor caido, 429, timeout, clave invalida...). Se degrada a reglas y se
// guarda el motivo. Un error de AUTENTICACION (ai_auth_error) es un problema de configuracion: se degrada igual
// para no dejar el ticket sin triage, pero WF2 lo reporta al final (ver "Compose email").
// @include shared.js
// @include redact.js
// @include triage.js

const prepared = $('Prepare AI input').first().json;
const err = $input.first().json.error;

return [{ json: { triage: { ...prepared.fallback, source: 'fallback', reason: classifyAiError(err) } } }];
