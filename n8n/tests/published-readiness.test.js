'use strict';
// Prueba de src/tools/published.js (la senal de "workflow realmente en marcha") contra una base SQLite TEMPORAL
// con las mismas tablas y columnas que usa n8n 2.42.6. Cubre sobre todo el fallo real que se encontro en la Fase 6:
// n8n borra las filas `completed` del outbox a la hora, y la herramienta daba "no listo" para siempre.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { DatabaseSync } = require('node:sqlite');

const TOOL = path.join(__dirname, '..', 'src', 'tools', 'published.js');
const V1 = 'v1-aaaa';
const V2 = 'v2-bbbb';

// Crea la BD con un workflow `w` cuya version activa es `active` y las filas indicadas.
function check({ active = V2, triggers = [], outbox = [] }) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pub-'));
  const file = path.join(dir, 'db.sqlite');
  const db = new DatabaseSync(file);
  db.exec(`
    CREATE TABLE workflow_entity (id TEXT PRIMARY KEY, activeVersionId TEXT);
    CREATE TABLE workflow_publication_trigger_status (workflowId TEXT, versionId TEXT, status TEXT);
    CREATE TABLE workflow_publication_outbox (workflowId TEXT, publishedVersionId TEXT, status TEXT);
  `);
  db.prepare('INSERT INTO workflow_entity VALUES (?, ?)').run('w', active);
  for (const [version, status] of triggers) db.prepare('INSERT INTO workflow_publication_trigger_status VALUES (?, ?, ?)').run('w', version, status);
  for (const [version, status] of outbox) db.prepare('INSERT INTO workflow_publication_outbox VALUES (?, ?, ?)').run('w', version, status);
  db.close();
  try {
    const r = spawnSync(process.execPath, ['--no-warnings', TOOL, 'w'], { env: { ...process.env, N8N_DB_PATH: file }, encoding: 'utf8' });
    return { exit: r.status, state: JSON.parse(r.stdout)[0] };
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

test('instancia estable: triggers activados y filas del outbox ya BORRADAS por n8n -> lista (el fallo real de la Fase 6)', () => {
  const r = check({ triggers: [[V2, 'activated'], [V2, 'activated']], outbox: [] });
  assert.equal(r.exit, 0);
  assert.equal(r.state.ready, true);
  assert.equal(r.state.reconciled, false);
});

test('instancia estable con fila completada -> lista', () => {
  const r = check({ triggers: [[V2, 'activated']], outbox: [[V2, 'completed']] });
  assert.equal(r.exit, 0);
});

test('version nueva publicada y SIN reconciliar: fila pendiente y los triggers siguen siendo los de la version vieja -> NO lista', () => {
  const r = check({ active: V2, triggers: [[V1, 'activated']], outbox: [[V1, 'completed'], [V2, 'pending']] });
  assert.equal(r.exit, 1);
  assert.equal(r.state.ready, false);
  assert.equal(r.state.pending, 1);
});

test('version nueva sin fila pendiente ni triggers propios (nunca activada) -> NO lista', () => {
  const r = check({ active: V2, triggers: [[V1, 'activated']], outbox: [] });
  assert.equal(r.exit, 1);
  assert.equal(r.state.ready, false);
});

test('fila pendiente aunque los triggers de la version activa figuren activados -> NO lista', () => {
  const r = check({ triggers: [[V2, 'activated']], outbox: [[V2, 'in_progress']] });
  assert.equal(r.exit, 1);
});

test('publicacion fallida o parcial en el outbox -> NO lista', () => {
  assert.equal(check({ triggers: [[V2, 'activated']], outbox: [[V2, 'failed']] }).exit, 1);
  assert.equal(check({ triggers: [[V2, 'activated']], outbox: [[V2, 'partial_success']] }).exit, 1);
});

test('un trigger de la version activa en estado failed -> NO lista', () => {
  const r = check({ triggers: [[V2, 'activated'], [V2, 'failed']], outbox: [[V2, 'completed']] });
  assert.equal(r.exit, 1);
  assert.equal(r.state.activated, 1);
});

test('workflow sin filas de trigger (solo Error Trigger): exige la fila completada de esa version', () => {
  assert.equal(check({ triggers: [], outbox: [[V2, 'completed']] }).exit, 0);
  assert.equal(check({ triggers: [], outbox: [] }).exit, 1);
  assert.equal(check({ triggers: [], outbox: [[V1, 'completed']] }).exit, 1);
});

test('workflow no publicado -> NO lista', () => {
  const r = check({ active: null });
  assert.equal(r.exit, 1);
  assert.equal(r.state.published, false);
});
