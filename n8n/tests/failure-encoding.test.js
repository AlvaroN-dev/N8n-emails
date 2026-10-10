'use strict';
// Por que el mensaje de "Stop and Error" va codificado: n8n reescribe los mensajes de error que contienen
// ciertos codigos de red (NodeError.setDescriptiveErrorMessage en n8n-workflow). Estas pruebas usan la clase
// REAL de la imagen de n8n para demostrar el problema y que la solucion lo evita.
const test = require('node:test');
const assert = require('node:assert/strict');
const { runCode, runShared } = require('./harness');

// Codigos que n8n 2.42.6 sustituye (COMMON_ERRORS en n8n-workflow/errors/abstract/node.error.js).
const N8N_REWRITTEN_CODES = [
  'ECONNREFUSED', 'ECONNRESET', 'ENOTFOUND', 'ETIMEDOUT', 'ERRADDRINUSE', 'EADDRNOTAVAIL', 'ECONNABORTED',
  'EHOSTUNREACH', 'EAI_AGAIN', 'ENOENT', 'EISDIR', 'ENOTDIR', 'EACCES', 'EEXIST', 'EPERM', 'GETADDRINFO',
];

function realNodeOperationError(message) {
  const wf = require(require.resolve('n8n-workflow', { paths: ['/usr/local/lib/node_modules/n8n'] }));
  const node = { id: '1', name: 'Report failure', type: 'n8n-nodes-base.stopAndError', typeVersion: 1, position: [0, 0], parameters: {} };
  return new wf.NodeOperationError(node, message);
}

test('premisa: n8n SI reescribe un mensaje que contiene un codigo de red', () => {
  const err = realNodeOperationError('getaddrinfo EAI_AGAIN api');
  assert.notEqual(err.message, 'getaddrinfo EAI_AGAIN api');
  assert.match(err.message, /DNS server/);
});

test('solucion: el mensaje codificado sobrevive intacto a NodeOperationError con cualquiera de los 16 codigos', () => {
  for (const code of N8N_REWRITTEN_CODES) {
    const failure = {
      node: 'Create ticket in Django', type: 'connection', retryable: 'yes',
      ticket_external_id: code, // un cliente puede elegir un external_id asi
      detail: `getaddrinfo ${code} api | ${code}`,
    };
    const message = runShared(`encodeFailure(${JSON.stringify(failure)})`);
    assert.equal(realNodeOperationError(message).message, message, code);
    assert.deepEqual(runShared(`decodeFailure(${JSON.stringify(message)})`), failure, code);
  }
});

test('el mensaje codificado nunca contiene ninguno de los codigos (ni en minusculas)', () => {
  const failure = { type: 'unknown', retryable: 'manual', detail: N8N_REWRITTEN_CODES.join(' ') };
  const message = runShared(`encodeFailure(${JSON.stringify(failure)})`).toUpperCase();
  for (const code of N8N_REWRITTEN_CODES) assert.equal(message.includes(code), false, code);
});

test('type y retryable quedan legibles en el mensaje', () => {
  const message = runShared('encodeFailure({ type: "timeout", retryable: "yes", detail: "x" })');
  assert.match(message, /^HANDLED_FAILURE type=timeout retryable=yes data=[0-9a-f]+$/);
});

test('ida y vuelta con caracteres no ASCII, comillas y saltos de linea', () => {
  const failure = { type: 'unknown', retryable: 'manual', detail: 'fallo ñ "comillas" \n y emoji 😀' };
  const message = runShared(`encodeFailure(${JSON.stringify(failure)})`);
  assert.deepEqual(runShared(`decodeFailure(${JSON.stringify(message)})`), failure);
});

test('decodeFailure devuelve null ante mensajes que no son fallos gestionados', () => {
  for (const text of ['', 'Request failed', 'HANDLED_FAILURE data=zz', 'HANDLED_FAILURE data=abc', undefined]) {
    assert.equal(runShared(`decodeFailure(${JSON.stringify(text === undefined ? null : text)})`), null, String(text));
  }
});

// --- Los nodos Interpret... entregan failure_message listo para Stop and Error ---
const SENT = { external_id: 'ENOENT-1', customer_email: 'a@example.com', subject: 's', message: 'm' };
const nodes = { 'Validate payload': [{ ok: true, ticket: SENT }] };

test('un fallo de red produce un failure_message que decodifica al failure y sobrevive a NodeOperationError', () => {
  const out = runCode('wf01-interpret-connection-error.js', {
    input: [{ error: { message: 'getaddrinfo EAI_AGAIN api', code: 'EAI_AGAIN' } }], nodes,
  })[0].json;
  assert.equal(realNodeOperationError(out.failure_message).message, out.failure_message);
  assert.deepEqual(runShared(`decodeFailure(${JSON.stringify(out.failure_message)})`), out.failure);
  assert.equal(out.failure.ticket_external_id, 'ENOENT-1');
});

test('un 500 de Django tambien lleva failure_message; un 201 no', () => {
  const run = (statusCode, body) => runCode('wf01-interpret-django-response.js', { input: [{ statusCode, body }], nodes })[0].json;
  assert.match(run(500, {}).failure_message, /^HANDLED_FAILURE type=http_5xx retryable=yes data=/);
  assert.equal(run(201, { id: 5, external_id: 'X' }).failure_message, undefined);
});

// --- Clasificacion de los textos amigables con que n8n reescribe los errores de red ---
test('classifyError reconoce tambien los mensajes reescritos por n8n', () => {
  const type = (msg) => runShared(`classifyError(${JSON.stringify(msg)}).type`);
  assert.equal(type('The connection was aborted, perhaps the server is offline'), 'timeout');
  assert.equal(type('The DNS server returned an error, perhaps the server is offline'), 'connection');
  assert.equal(type('The service refused the connection - perhaps it is offline'), 'connection');
  assert.equal(type('The connection cannot be established, this usually occurs due to an incorrect host'), 'connection');
});

test('classifyError: textos de n8n por codigo HTTP (STATUS_CODE_MESSAGES) se clasifican como http_4xx / http_5xx / timeout', () => {
  const type = (msg) => runShared(`classifyError(${JSON.stringify({ message: msg })}).type`);
  assert.equal(type('The service was not able to process your request'), 'http_5xx');
  assert.equal(type('Bad gateway - the service failed to handle your request'), 'http_5xx');
  assert.equal(type('Service unavailable - try again later'), 'http_5xx');
  assert.equal(type('Gateway timed out - perhaps try again later?'), 'timeout');
  assert.equal(type('Authorization failed - please check your credentials'), 'http_4xx');
  assert.equal(type('Forbidden - perhaps check your credentials?'), 'http_4xx');
  assert.equal(type('The resource you are requesting could not be found'), 'http_4xx');
  assert.equal(type('Bad request - please check your parameters'), 'http_4xx');
  assert.equal(type('un error cualquiera'), 'unknown');
});

test('classifyError: marca retryable correctamente (5xx y red = yes; 4xx = no)', () => {
  const retry = (msg) => runShared(`classifyError(${JSON.stringify({ message: msg })}).retryable`);
  assert.equal(retry('The service was not able to process your request'), 'yes');
  assert.equal(retry('The DNS server returned an error, perhaps the server is offline'), 'yes');
  assert.equal(retry('Authorization failed - please check your credentials'), 'no');
});

test('classifyError: un codigo HTTP al INICIO del texto cuenta (p. ej. el 404 con el cuerpo de Django, observado en WF2)', () => {
  const real = '404 - "{\\"status\\":\\"error\\",\\"code\\":\\"not_found\\",\\"message\\":\\"No Ticket matches the given query.\\"}"';
  const cls = (msg) => runShared(`classifyError(${JSON.stringify(msg)})`);
  assert.deepEqual([cls(real).type, cls(real).retryable], ['http_4xx', 'no']);
  assert.deepEqual([cls('401 - unauthorized').type, cls('403 - forbidden').retryable], ['http_4xx', 'no']);
  assert.deepEqual([cls('500 - "boom"').type, cls('500 - "boom"').retryable], ['http_5xx', 'yes']);
  assert.equal(cls('502 - bad gateway').type, 'http_5xx');
  // No se confunde con otros numeros del texto
  assert.equal(cls('el servidor 404 no responde').type, 'unknown');
  assert.equal(cls('12345 cosas').type, 'unknown');
});
