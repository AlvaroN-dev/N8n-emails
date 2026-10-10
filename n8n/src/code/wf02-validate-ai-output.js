// WF2 - "Validate AI output"
// La salida del modelo NUNCA se usa sin validar. Si no cumple el contrato exacto (ver parseAiOutput) se aplica el
// triage por reglas y se registra el motivo: no se oculta, queda en el ticket (triage_source=fallback + reason).
// @include shared.js
// @include redact.js
// @include triage.js

const prepared = $('Prepare AI input').first().json;
const out = $input.first().json;

// El nodo "Basic LLM Chain" entrega el texto en `text` (se comprueba en las pruebas contra la ejecucion real).
const raw = [out.text, out.output, out.response].find((value) => typeof value === 'string');
const parsed = parseAiOutput(raw);

const triage = parsed.ok
  ? { ...parsed.triage, source: 'ai', reason: '' }
  : { ...prepared.fallback, source: 'fallback', reason: parsed.reason };

return [{ json: { triage } }];
