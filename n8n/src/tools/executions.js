'use strict';
// Herramienta de PRUEBAS: lista ejecuciones de n8n leyendo su base SQLite en SOLO LECTURA.
// Evita crear una API key manual solo para verificar resultados. Depende del esquema interno de n8n
// (execution_entity / execution_data), por eso solo se usa con la version fijada en docker-compose.yml.
//
//   node n8n/src/tools/executions.js [--workflow <id>] [--after-id <n>] [--limit <n>]
//
// Se ejecuta dentro del contenedor:
//   docker compose exec -T n8n node --no-warnings /import/src/tools/executions.js --limit 5
const { DatabaseSync } = require('node:sqlite');

const DB_PATH = process.env.N8N_DB_PATH || '/home/node/.n8n/database.sqlite';
const FLATTED = '/usr/local/lib/node_modules/n8n/node_modules/.pnpm/flatted@3.4.2/node_modules/flatted/cjs/index.js';

const arg = (name, fallback) => {
  const i = process.argv.indexOf(`--${name}`);
  return i > -1 && process.argv[i + 1] !== undefined ? process.argv[i + 1] : fallback;
};

// --node <nombre>: incluye en cada ejecucion la PRIMERA salida de ese nodo (para depurar; puede contener datos de prueba).
const nodeName = arg('node', null);
const workflow = arg('workflow', null);
const afterId = Number(arg('after-id', 0));
const limit = Number(arg('limit', 10));

const db = new DatabaseSync(DB_PATH, { readOnly: true });
let flatted = null;
try { flatted = require(FLATTED); } catch { /* sin flatted solo se omite el detalle */ }

const where = ['e.id > ?'];
const params = [afterId];
if (workflow) { where.push('e.workflowId = ?'); params.push(workflow); }

const rows = db.prepare(
  `SELECT e.id, e.workflowId, e.status, e.mode, e.startedAt, e.stoppedAt, d.data
     FROM execution_entity e LEFT JOIN execution_data d ON d.executionId = e.id
    WHERE ${where.join(' AND ')} ORDER BY e.id DESC LIMIT ${Math.max(1, limit)}`,
).all(...params);

const out = rows.map((r) => {
  const item = {
    id: r.id, workflowId: r.workflowId, status: r.status, mode: r.mode,
    startedAt: r.startedAt, stoppedAt: r.stoppedAt,
    lastNode: null, error: null, errorNode: null, nodeErrors: {}, nodesRun: [],
  };
  if (flatted && r.data) {
    try {
      const result = flatted.parse(r.data).resultData || {};
      item.lastNode = result.lastNodeExecuted || null;
      item.nodesRun = Object.keys(result.runData || {});
      if (result.error) {
        item.error = String(result.error.message || result.error).slice(0, 4000); // el mensaje HANDLED_FAILURE va en hex: ocupa el doble
        item.errorNode = (result.error.node && result.error.node.name) || null;
      }
      if (nodeName) {
        const run = (result.runData || {})[nodeName];
        const json = run && run[0] && run[0].data && run[0].data.main && run[0].data.main[0] && run[0].data.main[0][0]
          ? run[0].data.main[0][0].json : null;
        item.nodeOutput = json ? JSON.parse(JSON.stringify(json)) : null;
      }
      // Errores registrados por nodo (incluye los que n8n encamina a una "salida de error").
      for (const [name, runs] of Object.entries(result.runData || {})) {
        for (const run of runs) {
          if (run && run.error) item.nodeErrors[name] = String(run.error.message || run.error).slice(0, 4000);
        }
      }
    } catch { /* datos ilegibles: se devuelve lo basico */ }
  }
  return item;
});

process.stdout.write(`${JSON.stringify(out, null, 2)}\n`);
