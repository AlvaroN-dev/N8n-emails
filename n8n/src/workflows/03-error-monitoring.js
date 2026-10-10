'use strict';
// WF3 - Error monitoring: es el "error workflow" de WF1 y WF2 (ajuste `errorWorkflow` de cada uno).
// Error Trigger -> Describe failure (sanea, clasifica, decide reintento) -> registra el evento en Django.
// Si el registro falla (lo habitual: Django caido) -> correo de alerta, para que el fallo no se pierda en silencio.
//
// Respuestas a las preguntas del requisito:
//   - Que workflow fallo / en que etapa ........ workflow_name, failed_node
//   - Tipo de error ............................ error_type (http_4xx, http_5xx, timeout, connection, validation, ai_output, smtp, unknown)
//   - Que es seguro registrar .................. solo ids, etapa, tipo y un detalle corto y REDACTADO; nunca el payload ni datos personales
//   - Reintentar o detener ..................... retryable: yes (idempotente, reprocesable) | manual (decide una persona) | no (corregir antes)
//
// El POST a Django es idempotente por (workflow_id, execution_id): reintentarlo es seguro y no duplica eventos.
const { Workflow, CREDENTIALS } = require('../builder');

const wf = new Workflow({
  id: 'wfErrorMonitor03',
  name: '03 - Error monitoring',
  // Cota global: 3 intentos de 8 s + 2 esperas de 5 s = ~34 s, mas el envio de la alerta.
  settings: { executionTimeout: 80 },
});

wf.errorTrigger('Error Trigger', [0, 300]);
wf.code('Describe failure', [220, 300], 'wf03-describe-failure.js');
wf.http('Register event in Django', [440, 300], {
  method: 'POST',
  url: 'http://api:8000/api/error-events/',
  credential: CREDENTIALS.djangoApiKey,
  bodyExpression: 'JSON.stringify($json.event)',
  timeout: 8000,
  retry: { maxTries: 3, waitMs: 5000 }, // seguro: el endpoint es idempotente por ejecucion
  onError: 'continueErrorOutput',
});
wf.code('Compose alert email', [660, 400], 'wf03-compose-alert.js');
wf.emailSend('Send alert email', [880, 400], {
  credential: CREDENTIALS.smtp,
  fromExpression: '$json.email.from',
  toExpression: '$json.email.to',
  subjectExpression: '$json.email.subject',
  textExpression: '$json.email.text',
});

wf.connect('Error Trigger', 'Describe failure');
wf.connect('Describe failure', 'Register event in Django');
wf.connect('Register event in Django', 'Compose alert email', 1); // salida de error: no se pudo registrar
wf.connect('Compose alert email', 'Send alert email');

module.exports = wf;
