'use strict';
// WF2 - AI triage + notification.
// Webhook interno (lo llama WF1, o una persona para reprocesar) -> lee el ticket de Django -> LLM -> VALIDA la
// salida -> guarda el triage -> correo (SMTP) -> marca como notificado.
//
// Reintentos (solo donde repetir NO duplica efectos):
//   - Lecturas y escrituras idempotentes en Django (GET, PATCH triage, POST notified): 2 intentos.
//   - Llamada al LLM: 1 reintento dentro del cliente (maxRetries); sin efecto lateral externo.
//   - Envio de correo: NINGUNO. Si falla, la ejecucion queda en error (WF3 lo registra) y se reprocesa a mano:
//     el ticket ya triado reutiliza su triage (no se vuelve a llamar a la IA) y la guardia `notified` evita duplicados.
const { Workflow, CREDENTIALS } = require('../builder');

const API = 'http://api:8000/api/tickets/';
const RETRY = { maxTries: 2, waitMs: 1500 };

const wf = new Workflow({
  id: 'wfAiTriageNotify',
  name: '02 - AI triage and notification',
  // Debe ser MENOR que el umbral con que WF1 considera atascado un ticket (120 s): dos ejecuciones nunca coinciden.
  settings: { executionTimeout: 90, errorWorkflow: 'wfErrorMonitor03' },
});

wf.webhook('Webhook - internal triage', [0, 300], {
  path: 'internal/ticket-triage',
  credential: CREDENTIALS.internalWebhookToken,
  responseMode: 'onReceived',
  // 202 Accepted: WF2 trabaja de forma asincrona respecto a quien la llama.
  options: { responseCode: { values: { responseCode: 'customCode', customCode: 202 } } },
});
wf.code('Validate input', [220, 300], 'wf02-validate-input.js');

wf.http('Get ticket', [440, 300], {
  method: 'GET',
  url: `={{ '${API}' + $json.ticket_id + '/' }}`,
  credential: CREDENTIALS.djangoApiKey,
  timeout: 8000,
  retry: RETRY,
  onError: 'continueErrorOutput',
});

// Guardias de idempotencia: un ticket ya notificado no se vuelve a procesar; uno ya triado reutiliza su triage.
wf.ifTrue('Already notified?', [660, 300], "$json.status === 'notified'");
wf.noOp('Skip - already notified', [880, 160]);
wf.ifTrue('Already triaged?', [880, 340], '$json.triaged_at !== null && $json.triaged_at !== undefined');

// --- Triage con IA (con degradacion a reglas) ---
wf.code('Prepare AI input', [1100, 440], 'wf02-prepare-ai-input.js');
wf.llmChain('Triage with AI', [1320, 440], {
  systemMessage: 'You are a support ticket triage assistant. You only output the requested JSON object.',
  textExpression: '$json.ai_prompt',
  onError: 'continueErrorOutput',
});
wf.openAiChatModel('OpenAI Chat Model', [1320, 640], {
  // El nombre del modelo solo lo usa Gemini; el LLM simulado lo ignora. El proveedor lo fija la credencial.
  // OJO: los modelos de la capa gratuita se retiran con frecuencia (gemini-2.5-flash-lite dejo de estar disponible
  // para cuentas nuevas y devolvia 404). Si Gemini falla con `ai_config_error`, comprueba el modelo con:
  //   curl -H "x-goog-api-key: <clave>" https://generativelanguage.googleapis.com/v1beta/models
  model: 'gemini-3.5-flash-lite',
  credential: CREDENTIALS.llm,
  timeoutMs: 20000,
  maxRetries: 1,
  maxTokens: 400,
});
wf.code('Validate AI output', [1560, 380], 'wf02-validate-ai-output.js');
wf.code('AI call failed', [1560, 520], 'wf02-ai-call-failed.js');
wf.http('Save triage', [1800, 440], {
  method: 'PATCH',
  url: `={{ '${API}' + $('Prepare AI input').first().json.ticket_id + '/triage/' }}`,
  credential: CREDENTIALS.djangoApiKey,
  bodyExpression: 'JSON.stringify($json.triage)',
  timeout: 8000,
  retry: RETRY,
  onError: 'continueErrorOutput',
});

// --- Notificacion ---
wf.code('Compose email', [2040, 340], 'wf02-compose-email.js');
wf.emailSend('Send notification email', [2260, 340], {
  credential: CREDENTIALS.smtp,
  fromExpression: '$json.email.from',
  toExpression: '$json.email.to',
  subjectExpression: '$json.email.subject',
  textExpression: '$json.email.text',
  onError: 'continueErrorOutput',
});
wf.http('Mark notified', [2480, 340], {
  method: 'POST',
  url: `={{ '${API}' + $('Compose email').first().json.ticket_id + '/notified/' }}`,
  credential: CREDENTIALS.djangoApiKey,
  timeout: 8000,
  retry: RETRY,
  onError: 'continueErrorOutput',
});
wf.ifTrue('AI config failure to report?', [2700, 340], "$('Compose email').first().json.report_needed === true");
wf.stopAndError('Report failure', [2920, 260], "$('Compose email').first().json.failure_message");

// --- Fallos TECNICOS gestionados: cada etapa que habla con Django o el SMTP envia su error a un nodo que lo describe
// con el ticket afectado (el error crudo de n8n no dice de que ticket se trataba) y hace fallar la ejecucion para WF3.
wf.code('Stage failure - Get ticket', [660, 100], 'wf02-stage-failure.js', { STAGE: 'Get ticket', KIND: 'http' });
wf.code('Stage failure - Save triage', [1800, 640], 'wf02-stage-failure.js', { STAGE: 'Save triage', KIND: 'http' });
wf.code('Stage failure - Send email', [2260, 540], 'wf02-stage-failure.js', { STAGE: 'Send notification email', KIND: 'smtp' });
wf.code('Stage failure - Mark notified', [2480, 540], 'wf02-stage-failure.js', { STAGE: 'Mark notified', KIND: 'http' });
wf.stopAndError('Report stage failure', [2920, 640], '$json.failure_message');

wf.connect('Webhook - internal triage', 'Validate input');
wf.connect('Validate input', 'Get ticket');
wf.connect('Get ticket', 'Already notified?');
wf.connect('Already notified?', 'Skip - already notified', 0);
wf.connect('Already notified?', 'Already triaged?', 1);
wf.connect('Already triaged?', 'Compose email', 0); // ya triado: reutiliza su triage, sin volver a llamar a la IA
wf.connect('Already triaged?', 'Prepare AI input', 1);
wf.connect('Prepare AI input', 'Triage with AI');
wf.connectAi('OpenAI Chat Model', 'Triage with AI');
wf.connect('Triage with AI', 'Validate AI output', 0);
wf.connect('Triage with AI', 'AI call failed', 1);
wf.connect('Validate AI output', 'Save triage');
wf.connect('AI call failed', 'Save triage');
wf.connect('Save triage', 'Compose email');
wf.connect('Compose email', 'Send notification email');
wf.connect('Send notification email', 'Mark notified');
wf.connect('Mark notified', 'AI config failure to report?');
wf.connect('AI config failure to report?', 'Report failure', 0);
wf.connect('Get ticket', 'Stage failure - Get ticket', 1);
wf.connect('Save triage', 'Stage failure - Save triage', 1);
wf.connect('Send notification email', 'Stage failure - Send email', 1);
wf.connect('Mark notified', 'Stage failure - Mark notified', 1);
for (const stage of ['Get ticket', 'Save triage', 'Send email', 'Mark notified']) wf.connect(`Stage failure - ${stage}`, 'Report stage failure');

module.exports = wf;
