'use strict';
// Herramienta de PRUEBAS: inventario de lo que n8n tiene guardado, leyendo su SQLite en SOLO LECTURA.
// Sirve para comparar el estado ANTES y DESPUES de un reinicio o de un down/up (persistencia).
// NO imprime nunca el contenido (`data`) de las credenciales: solo id, nombre y tipo.
//
//   docker compose exec -T n8n node --no-warnings /import/src/tools/inventory.js
const { DatabaseSync } = require('node:sqlite');

const db = new DatabaseSync(process.env.N8N_DB_PATH || '/home/node/.n8n/database.sqlite', { readOnly: true });

const workflows = db.prepare(
  'SELECT id, name, activeVersionId IS NOT NULL AS published FROM workflow_entity WHERE isArchived = 0 ORDER BY id',
).all().map((w) => ({ id: w.id, name: w.name, published: Boolean(w.published) }));

const credentials = db.prepare('SELECT id, name, type FROM credentials_entity ORDER BY id').all();

// Usuarios con cuenta ya configurada (el owner creado en la interfaz tiene email y contrasena).
const users = db.prepare("SELECT count(*) AS n FROM user WHERE email IS NOT NULL AND password IS NOT NULL").get().n;

process.stdout.write(`${JSON.stringify({ workflows, credentials, users })}\n`);
