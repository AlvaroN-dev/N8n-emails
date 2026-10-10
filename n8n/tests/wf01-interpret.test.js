'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { runCode } = require('./harness');

const SENT = { external_id: 'TCK-1001', customer_email: 'ana@example.com', subject: 's', message: 'm' };
const nodes = { 'Validate payload': [{ ok: true, ticket: SENT }] };
const interpret = (res) => runCode('wf01-interpret-django-response.js', { input: [res], nodes })[0].json;
const minutesAgo = (m) => new Date(Date.now() - m * 60000).toISOString();

const TICKET = { id: 7, external_id: 'TCK-1001', status: 'received', created_at: new Date().toISOString() };

test('201: acepta, responde 201 y lanza WF2', () => {
  const out = interpret({ statusCode: 201, body: { ...TICKET, duplicate: false } });
  assert.deepEqual(out.respond, { statusCode: 201, body: { status: 'accepted', ticket_id: 7, external_id: 'TCK-1001' } });
  assert.equal(out.trigger, true);
  assert.equal(out.ticket_id, 7);
  assert.equal(out.failure, null);
});

test('200 duplicado reciente: responde duplicate y NO lanza WF2 (evita doble correo)', () => {
  const out = interpret({ statusCode: 200, body: { ...TICKET, duplicate: true } });
  assert.equal(out.respond.statusCode, 200);
  assert.equal(out.respond.body.status, 'duplicate');
  assert.equal(out.respond.body.reprocessing, false);
  assert.equal(out.trigger, false);
});

test('200 duplicado antiguo y sin notificar: se considera atascado y se reprocesa', () => {
  for (const status of ['received', 'triaged']) {
    const out = interpret({ statusCode: 200, body: { ...TICKET, status, created_at: minutesAgo(5), duplicate: true } });
    assert.equal(out.trigger, true, status);
    assert.equal(out.respond.body.reprocessing, true);
  }
});

test('200 duplicado antiguo pero ya notificado: nunca se reprocesa', () => {
  const out = interpret({ statusCode: 200, body: { ...TICKET, status: 'notified', created_at: minutesAgo(60), duplicate: true } });
  assert.equal(out.trigger, false);
});

test('200 con fecha ilegible: no se reprocesa (ante la duda, no duplicar efectos)', () => {
  const out = interpret({ statusCode: 200, body: { ...TICKET, created_at: 'basura', duplicate: true } });
  assert.equal(out.trigger, false);
});

test('400 de Django: se devuelve al cliente tal cual y NO se registra como fallo', () => {
  const details = { subject: ['Ensure this field has at least 3 characters.'] };
  const out = interpret({ statusCode: 400, body: { code: 'validation_error', details } });
  assert.equal(out.respond.statusCode, 400);
  assert.deepEqual(out.respond.body.details, details);
  assert.equal(out.failure, null);
  assert.equal(out.trigger, false);
});

test('401/403/404 de Django: fallo de configuracion -> 502, tipo http_4xx, no reintentable', () => {
  for (const status of [401, 403, 404, 415]) {
    const out = interpret({ statusCode: status, body: { code: 'unauthorized' } });
    assert.equal(out.respond.statusCode, 502, String(status));
    assert.equal(out.respond.body.code, 'upstream_rejected');
    assert.equal(out.failure.type, 'http_4xx');
    assert.equal(out.failure.retryable, 'no');
    assert.equal(out.failure.detail, `HTTP ${status}`);
    assert.equal(out.failure.ticket_external_id, 'TCK-1001');
  }
});

test('500/503 de Django: 502, tipo http_5xx, reintentable', () => {
  for (const status of [500, 502, 503]) {
    const out = interpret({ statusCode: status, body: 'Internal Server Error' });
    assert.equal(out.respond.statusCode, 502);
    assert.equal(out.respond.body.code, 'upstream_error');
    assert.equal(out.failure.type, 'http_5xx');
    assert.equal(out.failure.retryable, 'yes');
  }
});

test('respuesta 2xx con forma inesperada (sin id): no se da por buena', () => {
  for (const body of [{}, { id: 'siete' }, 'ok', null]) {
    const out = interpret({ statusCode: 201, body });
    assert.equal(out.respond.statusCode, 502, JSON.stringify(body));
    assert.equal(out.failure.type, 'unknown');
    assert.equal(out.trigger, false);
  }
});

test('un external_id con formato no permitido (p. ej. un email) nunca llega al registro de fallos', () => {
  const dirty = { 'Validate payload': [{ ok: true, ticket: { ...SENT, external_id: 'ana@example.com' } }] };
  const out = runCode('wf01-interpret-django-response.js', { input: [{ statusCode: 500, body: {} }], nodes: dirty })[0].json;
  assert.equal(out.failure.ticket_external_id, '');
});

// --- Fallos sin respuesta HTTP (salida de error del nodo HTTP) ---
const connErr = (error) => runCode('wf01-interpret-connection-error.js', { input: [{ error }], nodes })[0].json;

test('timeout -> 504 upstream_timeout, tipo timeout', () => {
  for (const error of ['timeout of 8000ms exceeded', { message: 'The connection timed out' }, { code: 'ETIMEDOUT' }]) {
    const out = connErr(error);
    assert.equal(out.respond.statusCode, 504, JSON.stringify(error));
    assert.equal(out.respond.body.code, 'upstream_timeout');
    assert.equal(out.failure.type, 'timeout');
  }
});

test('API caida -> 503 upstream_unavailable, tipo connection', () => {
  for (const error of ['connect ECONNREFUSED 172.20.0.3:8000', { message: 'getaddrinfo ENOTFOUND api' }, { code: 'ECONNRESET' }]) {
    const out = connErr(error);
    assert.equal(out.respond.statusCode, 503, JSON.stringify(error));
    assert.equal(out.respond.body.code, 'upstream_unavailable');
    assert.equal(out.failure.type, 'connection');
    assert.equal(out.failure.retryable, 'yes');
  }
});

test('error no reconocido -> 502, tipo unknown, decide una persona', () => {
  const out = connErr({ message: 'algo muy raro' });
  assert.equal(out.respond.statusCode, 502);
  assert.equal(out.failure.type, 'unknown');
  assert.equal(out.failure.retryable, 'manual');
});

test('el detalle registrado es corto y de una sola linea', () => {
  const out = connErr('linea1\n' + 'x'.repeat(1000));
  assert.equal(out.failure.detail.includes('\n'), false);
  assert.ok(out.failure.detail.length <= 200);
});

// --- WF1 no pudo lanzar WF2 ---
const notStarted = (error) => runCode('wf01-triage-not-started.js', {
  input: [{ error }],
  nodes: { 'Interpret Django response': [interpret({ statusCode: 201, body: { ...TICKET } })] },
})[0].json;

test('WF2 no arranco: se responde 502 con el id del ticket guardado y se registra', () => {
  const out = notStarted({ message: 'Forbidden - perhaps check your credentials?', httpCode: '403' });
  assert.equal(out.respond.statusCode, 502);
  assert.equal(out.respond.body.code, 'triage_not_started');
  assert.equal(out.respond.body.ticket_id, 7);
  assert.equal(out.failure.node, 'Start triage (WF2)');
  assert.equal(out.failure.type, 'http_4xx');
  assert.equal(out.failure.ticket_external_id, 'TCK-1001');
});

test('triage accepted: devuelve la respuesta preparada y ningun fallo', () => {
  const prepared = interpret({ statusCode: 201, body: { ...TICKET } });
  const out = runCode('wf01-triage-accepted.js', { input: [{}], nodes: { 'Interpret Django response': [prepared] } })[0].json;
  assert.deepEqual(out.respond, prepared.respond);
  assert.equal(out.failure, null);
});
