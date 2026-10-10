// WF2 - "Compose email"
// Entrada: el ticket YA triado (respuesta de Django: tanto tras guardar el triage como si ya estaba triado).
// El destinatario es FIJO: ningun dato del ticket ni del modelo puede cambiarlo.
// @include shared.js

const t = $input.first().json;

const TO = 'support-team@example.test';
const FROM = 'Ticket Triage <triage@tickets.local>';
const oneLine = (value) => String(value === undefined || value === null ? '' : value).replace(/\s+/g, ' ').trim();

const viaAi = t.triage_source === 'ai';
const method = viaAi
  ? 'AI (output validated against the expected format)'
  : `RULES FALLBACK (reason: ${t.triage_reason || 'n/a'}). The AI was unavailable or returned an unusable answer, so keyword rules were used.`;

const subject = `[${String(t.priority).toUpperCase()}] Ticket #${t.id} (${t.external_id}): ${oneLine(t.subject)}`.slice(0, 200);
const text = [
  'A new support ticket has been triaged.',
  '',
  `Ticket:    #${t.id} (${t.external_id})`,
  `Priority:  ${String(t.priority).toUpperCase()}`,
  `Category:  ${t.category}`,
  `Source:    ${t.source}`,
  `Customer:  ${t.customer_email}`,
  `Subject:   ${oneLine(t.subject)}`,
  '',
  'Summary:',
  oneLine(t.summary),
  '',
  `Triage by: ${method}`,
].join('\n');

// Que el proveedor de IA rechace las credenciales (ai_auth_error) o la peticion (ai_config_error: clave invalida,
// modelo retirado, URL base erronea) es un problema de CONFIGURACION: el ticket se procesa igualmente (con reglas),
// pero la ejecucion se hace fallar al final para que WF3 lo registre y alguien lo corrija.
const CONFIG_REASONS = ['ai_auth_error', 'ai_config_error'];
const reportNeeded = !viaAi && CONFIG_REASONS.includes(t.triage_reason);
const failure = reportNeeded
  ? {
    node: 'Triage with AI',
    type: 'http_4xx',
    retryable: 'no',
    ticket_id: t.id,
    ticket_external_id: safeExternalId(t.external_id),
    detail: `AI provider rejected the request (${t.triage_reason}): check the API key, model name and base URL. Ticket processed with rules.`,
  }
  : null;

return [{
  json: {
    ticket_id: t.id,
    email: { from: FROM, to: TO, subject, text },
    report_needed: reportNeeded,
    failure_message: failure ? encodeFailure(failure) : '',
  },
}];
