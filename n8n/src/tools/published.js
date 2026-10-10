'use strict';
// Herramienta de DESPLIEGUE/PRUEBAS: indica si la version ACTIVA de cada workflow ya esta realmente en marcha.
//
// Por que existe: tras un reinicio, n8n pasa a `healthy` y empieza a servir webhooks ANTES de reconciliar las
// publicaciones (tarda ~15 s). En ese intervalo ejecuta la version anterior del workflow. "healthy" no significa
// "mi version nueva esta en marcha". Se considera lista cuando:
//   - no queda ninguna publicacion pendiente (outbox con estado distinto de `completed`), y
//   - los triggers de la version ACTIVA estan todos en estado `activated`, y
//   - hay al menos un trigger activado de esa version (n8n solo escribe esas filas, con el id de la version,
//     al activarla: es la prueba de que esa version ya esta en marcha) o, si el workflow no tiene filas de
//     trigger (p. ej. solo un Error Trigger), existe una fila `completed` del outbox para esa version.
//
// Por que NO se exige siempre una fila `completed`: n8n BORRA las filas completadas a la hora (retencion de 1 h,
// limpieza cada 20 min), asi que en una instancia que lleva mas de una hora arriba esa fila ya no existe aunque
// todo funcione. Y un reinicio de las MISMAS versiones no crea filas nuevas ni reinicia los triggers (son
// persistentes): solo un cambio de version (import + publish) abre la ventana en la que se sirve la version vieja,
// y esa ventana si deja una fila pendiente en el outbox. Verificado empiricamente en n8n 2.42.6.
//
//   node published.js <workflowId> [<workflowId> ...]     -> JSON; sale con codigo 0 si TODOS estan listos, 1 si no
//   (se ejecuta dentro del contenedor: docker compose exec -T n8n node --no-warnings /import/src/tools/published.js wfX)
const { DatabaseSync } = require('node:sqlite');

const ids = process.argv.slice(2);
if (ids.length === 0) {
  console.error('Uso: node published.js <workflowId> [...]');
  process.exit(2);
}

const db = new DatabaseSync(process.env.N8N_DB_PATH || '/home/node/.n8n/database.sqlite', { readOnly: true });
const result = ids.map((id) => {
  const wf = db.prepare('SELECT activeVersionId FROM workflow_entity WHERE id = ?').get(id);
  if (!wf || !wf.activeVersionId) return { id, published: false, ready: false, reason: 'no publicado' };

  const triggers = db.prepare(
    'SELECT status FROM workflow_publication_trigger_status WHERE workflowId = ? AND versionId = ?',
  ).all(id, wf.activeVersionId);
  const pending = db.prepare(
    "SELECT count(*) AS n FROM workflow_publication_outbox WHERE workflowId = ? AND status != 'completed'",
  ).get(id).n;
  const reconciled = db.prepare(
    "SELECT count(*) AS n FROM workflow_publication_outbox WHERE workflowId = ? AND publishedVersionId = ? AND status = 'completed'",
  ).get(id, wf.activeVersionId).n > 0;
  const activated = triggers.filter((t) => t.status === 'activated').length;
  const ready = pending === 0 && activated === triggers.length && (triggers.length > 0 || reconciled);
  return {
    id, published: true, activeVersionId: wf.activeVersionId, reconciled, triggers: triggers.length, activated, pending, ready,
  };
});

process.stdout.write(`${JSON.stringify(result)}\n`);
process.exit(result.every((r) => r.ready) ? 0 : 1);
