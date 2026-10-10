'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { runCode, runShared } = require('./harness');

const WF2 = { id: 'wfAiTriageNotify', name: '02 - AI triage and notification' };
const trigger = ({ message = 'x', lastNode = 'Get ticket', id = 321, wf = WF2 } = {}) => ({
  execution: {
    id,
    url: `http://localhost:5678/workflow/${wf.id}/executions/${id}`,
    error: { message, stack: 'Error: x\n    at secret/path/file.js:1:1' },
    lastNodeExecuted: lastNode,
    mode: 'webhook',
  },
  workflow: wf,
});
const handled = (failure) => runShared(`encodeFailure(${JSON.stringify(failure)})`);
const describe = (payload) => runCode('wf03-describe-failure.js', { input: [payload] })[0].json;

// ------------------------------------------------------------------ fallos GESTIONADOS (HANDLED_FAILURE)
test('Describe failure: un fallo gestionado se registra con su tipo, etapa, ticket y detalle', () => {
  const failure = {
    node: 'Send notification email', type: 'smtp', retryable: 'manual', ticket_id: 12, ticket_external_id: 'TCK-1',
    detail: 'The connection timed out',
  };
  const { event, execution_url: url, handled: wasHandled } = describe(trigger({ message: handled(failure), lastNode: 'Report stage failure' }));
  assert.equal(wasHandled, true);
  assert.deepEqual(event, {
    workflow_id: 'wfAiTriageNotify',
    workflow_name: '02 - AI triage and notification',
    execution_id: '321',
    failed_node: 'Send notification email', // la ETAPA real, no el nodo "Stop and Error" que lanzo el error
    error_type: 'smtp',
    retryable: 'manual',
    message: 'The connection timed out',
    ticket_id: 12,
    ticket_external_id: 'TCK-1',
  });
  assert.equal(url, 'http://localhost:5678/workflow/wfAiTriageNotify/executions/321');
});

test('Describe failure: tipo o retryable fuera del vocabulario se normalizan (unknown / manual)', () => {
  const { event } = describe(trigger({ message: handled({ node: 'N', type: 'explosion', retryable: 'quizas', detail: 'd' }) }));
  assert.deepEqual([event.error_type, event.retryable], ['unknown', 'manual']);
});

test('Describe failure: ticket_id invalido y external_id no permitido se descartan', () => {
  for (const ticket_id of ['12', 0, -1, 1.5, null, undefined, [3]]) {
    const out = describe(trigger({ message: handled({ type: 'unknown', retryable: 'no', ticket_id }) }));
    assert.equal(out.event.ticket_id, null, String(ticket_id));
  }
  const { event } = describe(trigger({ message: handled({ type: 'unknown', retryable: 'no', ticket_external_id: 'ana@example.com' }) }));
  assert.equal(event.ticket_external_id, '');
});

test('Describe failure: el detalle se redacta, se aplana a una linea y se recorta a 500', () => {
  const detail = `fallo para ana.lopez@example.com\ntel +34 612 345 678. ${'x'.repeat(900)}`;
  const { event } = describe(trigger({ message: handled({ type: 'unknown', retryable: 'manual', detail }) }));
  assert.ok(event.message.startsWith('fallo para [email] tel [phone].'));
  assert.equal(/[\r\n]/.test(event.message), false);
  assert.ok(event.message.length <= 500);
});

// ------------------------------------------------------------------ fallos NO gestionados (error crudo de n8n)
const raw = (message, lastNode) => describe(trigger({ message, lastNode })).event;

test('Describe failure (crudo): Validate input -> validation, no reintentar', () => {
  const e = raw('VALIDATION: ticket_id must be a positive integer [line 5]', 'Validate input');
  assert.deepEqual([e.error_type, e.retryable, e.failed_node], ['validation', 'no', 'Validate input']);
});

test('Describe failure (crudo): fallo del envio de correo -> smtp, reintento MANUAL', () => {
  const e = raw("The connection timed out, consider setting the 'Retry on Fail' option in the node settings", 'Send notification email');
  assert.deepEqual([e.error_type, e.retryable], ['smtp', 'manual']);
});

test('Describe failure (crudo): nodos de IA -> ai_output, manual', () => {
  for (const node of ['Prepare AI input', 'Triage with AI', 'Validate AI output']) {
    const e = raw('boom', node);
    assert.deepEqual([e.error_type, e.retryable], ['ai_output', 'manual'], node);
  }
});

test('Describe failure (crudo): nodos de Django se clasifican por el texto real de n8n', () => {
  const casos = [
    ['The resource you are requesting could not be found', 'http_4xx', 'no'],
    ['Authorization failed - please check your credentials', 'http_4xx', 'no'],
    ['The service was not able to process your request', 'http_5xx', 'yes'],
    ['The DNS server returned an error, perhaps the server is offline', 'connection', 'yes'],
    ['The connection was aborted, perhaps the server is offline', 'timeout', 'yes'],
    ['algo desconocido', 'unknown', 'manual'],
  ];
  for (const [message, type, retryable] of casos) {
    const e = raw(message, 'Get ticket');
    assert.deepEqual([e.error_type, e.retryable], [type, retryable], message);
  }
});

test('Describe failure (crudo): un timeout de la ejecucion completa -> timeout, manual', () => {
  const e = raw('Workflow execution timed out after 90 seconds', 'Send notification email');
  assert.deepEqual([e.error_type, e.retryable], ['timeout', 'manual']);
});

test('Describe failure (crudo): el mensaje se redacta y NUNCA se incluye el stack ni el payload', () => {
  const { event } = describe(trigger({ message: 'VALIDATION: fallo con ana@example.com y +34 612 345 678.', lastNode: 'Validate input' }));
  assert.equal(event.message, 'VALIDATION: fallo con [email] y [phone].');
  assert.equal(JSON.stringify(event).includes('secret/path'), false);
});

test('Describe failure: workflow, ejecucion y casos limite', () => {
  assert.equal(describe(trigger({ id: 77 })).event.execution_id, '77'); // numero -> texto
  const noExec = describe({ workflow: { id: 'w', name: 'Nombre' }, execution: { error: { message: 'm' } } }).event;
  assert.equal(noExec.execution_id, '');
  const empty = describe({}).event; // payload vacio: no debe romper
  assert.deepEqual([empty.workflow_name, empty.error_type, empty.retryable], ['unknown workflow', 'unknown', 'manual']);
});

test('Describe failure: fallo al ACTIVAR el trigger (sin ejecucion) se registra igualmente', () => {
  const payload = {
    workflow: WF2,
    trigger: { mode: 'trigger', error: { message: 'Webhook path already registered', node: { name: 'Webhook - internal triage' } } },
  };
  const { event } = describe(payload);
  assert.deepEqual([event.execution_id, event.failed_node, event.message], ['', 'Webhook - internal triage', 'Webhook path already registered']);
});

test('Describe failure: la URL de la ejecucion solo se admite si es http(s)', () => {
  const bad = trigger();
  bad.execution.url = 'javascript:alert(1)';
  assert.equal(describe(bad).execution_url, '');
});

// ------------------------------------------------------------------ Compose alert email
const alertFor = (event, error = 'Request failed') => runCode('wf03-compose-alert.js', {
  input: [{ event, execution_url: 'http://localhost:5678/workflow/w/executions/9', error }],
})[0].json.email;
const EVENT = {
  workflow_id: 'wfAiTriageNotify', workflow_name: '02 - AI triage and notification', execution_id: '9', failed_node: 'Mark notified',
  error_type: 'connection', retryable: 'yes', message: 'DNS error', ticket_id: 12, ticket_external_id: 'TCK-1',
};

test('Compose alert: destinatario fijo, asunto con workflow/tipo/etapa y cuerpo con ticket y consejo de reintento', () => {
  const email = alertFor(EVENT, { message: 'connect ECONNREFUSED', code: 'ECONNREFUSED' });
  assert.equal(email.to, 'ops-alerts@example.test');
  assert.equal(email.subject, '[ALERT] 02 - AI triage and notification: connection at Mark notified');
  assert.match(email.text, /Ticket:     #12 \(TCK-1\)/);
  assert.match(email.text, /Safe to reprocess/);
  assert.match(email.text, /could NOT be registered/);
  assert.match(email.text, /Execution:  9 \(http:\/\/localhost:5678\/workflow\/w\/executions\/9\)/);
});

test('Compose alert: el consejo cambia segun retryable', () => {
  assert.match(alertFor({ ...EVENT, retryable: 'manual' }).text, /A person must decide/);
  assert.match(alertFor({ ...EVENT, retryable: 'no' }).text, /Do NOT just retry/);
});

test('Compose alert: ticket sin identificar y detalle del error de registro corto y en una linea', () => {
  const email = alertFor({ ...EVENT, ticket_id: null, ticket_external_id: '' }, `linea1\n${'x'.repeat(1000)}`);
  assert.match(email.text, /Ticket:     not identified/);
  const line = email.text.split('\n').find((l) => l.startsWith('Registration error:'));
  assert.ok(line.length <= 260);
});

// ------------------------------------------------------------------ WF2: Stage failure
const stage = (error, { vars, nodes } = {}) => runCode('wf02-stage-failure.js', {
  input: [{ ticket_id: 12, error }],
  vars: vars || { STAGE: 'Save triage', KIND: 'http' },
  nodes: nodes || { 'Validate input': [{ ticket_id: 12 }], 'Get ticket': [{ id: 12, external_id: 'TCK-1' }] },
})[0].json;

test('Stage failure (http): etapa, ticket afectado y clasificacion; el mensaje se puede decodificar', () => {
  const out = stage({ message: 'The DNS server returned an error, perhaps the server is offline' });
  assert.deepEqual(
    [out.failure.node, out.failure.type, out.failure.retryable, out.failure.ticket_id, out.failure.ticket_external_id],
    ['Save triage', 'connection', 'yes', 12, 'TCK-1'],
  );
  assert.deepEqual(runShared(`decodeFailure(${JSON.stringify(out.failure_message)})`), out.failure);
});

test('Stage failure (smtp): SIEMPRE reintento manual, sea cual sea el error', () => {
  for (const message of ['The connection timed out', 'The DNS server returned an error', 'algo raro']) {
    const out = stage({ message }, { vars: { STAGE: 'Send notification email', KIND: 'smtp' } });
    assert.deepEqual([out.failure.type, out.failure.retryable, out.failure.node], ['smtp', 'manual', 'Send notification email'], message);
  }
});

test('Stage failure (Get ticket): sin respuesta de Django no hay external_id, pero SI el ticket_id', () => {
  // `Get ticket` no se define en el test: el nodo no produjo ninguna salida util.
  const out = stage({ message: 'The resource you are requesting could not be found' }, {
    vars: { STAGE: 'Get ticket', KIND: 'http' },
    nodes: { 'Validate input': [{ ticket_id: 999 }] },
  });
  assert.deepEqual(
    [out.failure.type, out.failure.retryable, out.failure.ticket_id, out.failure.ticket_external_id],
    ['http_4xx', 'no', 999, ''],
  );
});

test('Stage failure: un external_id no permitido nunca llega al registro', () => {
  const out = stage({ message: 'x' }, { nodes: { 'Validate input': [{ ticket_id: 1 }], 'Get ticket': [{ external_id: 'ana@example.com' }] } });
  assert.equal(out.failure.ticket_external_id, '');
});

test('Stage failure: el detalle es corto, de una linea y el mensaje sobrevive a NodeOperationError', () => {
  const out = stage({ message: `getaddrinfo EAI_AGAIN api\n${'x'.repeat(1000)}` });
  assert.ok(out.failure.detail.length <= 200 && !out.failure.detail.includes('\n'));
  const wf = require(require.resolve('n8n-workflow', { paths: ['/usr/local/lib/node_modules/n8n'] }));
  const node = { id: '1', name: 'Report stage failure', type: 'n8n-nodes-base.stopAndError', typeVersion: 1, position: [0, 0], parameters: {} };
  assert.equal(new wf.NodeOperationError(node, out.failure_message).message, out.failure_message);
});
