'use strict';
// WF1 - Ticket intake: webhook publico -> validacion -> Django -> respuesta HTTP exacta -> lanza WF2.
const { Workflow, CREDENTIALS } = require('../builder');

const wf = new Workflow({
  id: 'wfTicketIntake01',
  name: '01 - Ticket intake',
  // Cota global: 8 s (Django) + 5 s (lanzar WF2) + margen. Evita ejecuciones colgadas.
  settings: { executionTimeout: 45, errorWorkflow: 'wfErrorMonitor03' },
});

wf.webhook('Webhook - ticket intake', [0, 300], {
  path: 'tickets',
  credential: CREDENTIALS.intakeWebhookToken,
  responseMode: 'responseNode',
});
wf.code('Validate payload', [240, 300], 'wf01-validate-payload.js');
wf.ifTrue('Payload valid?', [480, 300], '$json.ok === true');

// Sin reintento automatico a proposito: si el POST expira pero Django SI termino, un reintento devolveria
// "duplicate" y se perderia el lanzamiento de WF2. La idempotencia protege los datos, no el flujo; el
// cliente puede reenviar y el ticket atascado se reprocesa (ver "Interpret Django response").
wf.http('Create ticket in Django', [720, 200], {
  method: 'POST',
  url: 'http://api:8000/api/tickets/',
  credential: CREDENTIALS.djangoApiKey,
  bodyExpression: 'JSON.stringify($json.ticket)',
  timeout: 8000,
  fullResponse: true,
  neverError: true,
  onError: 'continueErrorOutput',
});
wf.code('Interpret Django response', [960, 120], 'wf01-interpret-django-response.js');
wf.code('Interpret connection error', [960, 300], 'wf01-interpret-connection-error.js');
wf.ifTrue('Start triage?', [1200, 200], '$json.trigger === true');

// WF2 se llama por su webhook INTERNO (otro token). Se ejecuta aparte, con su propio historial.
wf.http('Start triage (WF2)', [1440, 100], {
  method: 'POST',
  url: 'http://127.0.0.1:5678/webhook/internal/ticket-triage',
  credential: CREDENTIALS.internalWebhookToken,
  bodyExpression: 'JSON.stringify({ ticket_id: $json.ticket_id })',
  timeout: 5000,
  onError: 'continueErrorOutput',
});
wf.code('Triage accepted', [1680, 40], 'wf01-triage-accepted.js');
wf.code('Triage not started', [1680, 200], 'wf01-triage-not-started.js');

wf.respondFromItem('Respond to client', [1920, 300]);
wf.ifTrue('Failure to report?', [2160, 300], '$json.failure !== null && $json.failure !== undefined');
// Respondido ya el cliente, se hace fallar la ejecucion para que el workflow de errores (WF3) la registre.
// `failure_message` va codificado (ver encodeFailure en snippets/shared.js): n8n reescribe los mensajes de error
// que contienen codigos de red como ECONNREFUSED y se perderia la informacion.
wf.stopAndError('Report failure', [2400, 220], '$json.failure_message');

wf.connect('Webhook - ticket intake', 'Validate payload');
wf.connect('Validate payload', 'Payload valid?');
wf.connect('Payload valid?', 'Create ticket in Django', 0);
wf.connect('Payload valid?', 'Respond to client', 1); // datos invalidos: ya lleva su respuesta 400
wf.connect('Create ticket in Django', 'Interpret Django response', 0);
wf.connect('Create ticket in Django', 'Interpret connection error', 1);
wf.connect('Interpret Django response', 'Start triage?');
wf.connect('Interpret connection error', 'Start triage?');
wf.connect('Start triage?', 'Start triage (WF2)', 0);
wf.connect('Start triage?', 'Respond to client', 1);
wf.connect('Start triage (WF2)', 'Triage accepted', 0);
wf.connect('Start triage (WF2)', 'Triage not started', 1);
wf.connect('Triage accepted', 'Respond to client');
wf.connect('Triage not started', 'Respond to client');
wf.connect('Respond to client', 'Failure to report?');
wf.connect('Failure to report?', 'Report failure', 0);

module.exports = wf;
