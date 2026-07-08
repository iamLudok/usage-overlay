// OpenCode Zen is a prepaid-credit product with no usage/quota API reachable
// from the local API key, so we report locally-tracked spend from opencode.db
// (this calendar month + all-time). Prints one JSON line for usage-overlay.ps1.
const os = require('os'), path = require('path');
const { DatabaseSync } = require('node:sqlite');
try {
  const db = new DatabaseSync(path.join(os.homedir(), '.local/share/opencode/opencode.db'), { readOnly: true });
  const now = new Date();
  const monthStart = new Date(now.getFullYear(), now.getMonth(), 1).getTime();
  const all = db.prepare('SELECT SUM(cost) c, SUM(tokens_input) ti, SUM(tokens_output) to_ FROM session').get();
  const mo = db.prepare('SELECT SUM(cost) c FROM session WHERE time_created >= ?').get(monthStart);
  console.log(JSON.stringify({
    month: mo.c || 0,
    total: all.c || 0,
    tin: all.ti || 0,
    tout: all.to_ || 0,
  }));
} catch (e) {
  console.log(JSON.stringify({ error: String(e) }));
}
