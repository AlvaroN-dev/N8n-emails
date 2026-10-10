'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { runCode } = require('./harness');

const FILE = 'wf01-validate-payload.js';
const VALID = {
  external_id: 'TCK-1001',
  customer_email: 'ana@example.com',
  subject: 'Cannot log in',
  message: 'I cannot log in since this morning.',
};
const run = (body) => runCode(FILE, { input: [{ body }] })[0].json;

test('cuerpo valido: pasa y reenvia solo los campos conocidos', () => {
  const out = run({ ...VALID, source: 'web', extra: 'x', is_admin: true });
  assert.equal(out.ok, true);
  assert.deepEqual(out.ticket, { ...VALID, source: 'web' });
});

test('source es opcional; null equivale a ausente', () => {
  assert.equal('source' in run(VALID).ticket, false);
  assert.equal('source' in run({ ...VALID, source: null }).ticket, false);
});

test('campos obligatorios ausentes: 400 con un detalle por campo (mismo formato que Django)', () => {
  const out = run({});
  assert.equal(out.ok, false);
  assert.equal(out.respond.statusCode, 400);
  assert.equal(out.respond.body.code, 'validation_error');
  assert.deepEqual(Object.keys(out.respond.body.details).sort(), ['customer_email', 'external_id', 'message', 'subject']);
  assert.deepEqual(out.respond.body.details.subject, ['This field is required.']);
});

test('null cuenta como ausente', () => {
  assert.deepEqual(run({ ...VALID, subject: null }).respond.body.details.subject, ['This field is required.']);
});

test('tipos incorrectos: numero, array, objeto y booleano se rechazan', () => {
  for (const bad of [12345, ['a'], { a: 1 }, true]) {
    const out = run({ ...VALID, subject: bad });
    assert.equal(out.respond.statusCode, 400, JSON.stringify(bad));
    assert.deepEqual(out.respond.body.details.subject, ['Not a valid string.']);
  }
});

test('source de tipo incorrecto se rechaza', () => {
  assert.deepEqual(run({ ...VALID, source: 7 }).respond.body.details.source, ['Not a valid string.']);
});

test('cuerpo que no es un objeto JSON: null, array, texto, numero, indefinido', () => {
  for (const bad of [null, [], 'texto', 42, undefined]) {
    const out = run(bad);
    assert.equal(out.respond.statusCode, 400, String(bad));
    assert.deepEqual(out.respond.body.details.non_field_errors, ['Request body must be a JSON object.']);
  }
});

test('el borde NO aplica reglas de negocio: cadena vacia o email raro llegan a Django', () => {
  const out = run({ ...VALID, customer_email: 'no-es-un-email', subject: '' });
  assert.equal(out.ok, true);
});
