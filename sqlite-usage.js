// Node helper for the two providers that need SQLite, which PowerShell 5.1
// can't read natively. Prints one JSON line for usage-overlay.ps1:
//   node sqlite-usage.js cursor    -> Cursor plan usage (token from state.vscdb)
//   node sqlite-usage.js opencode  -> OpenCode local spend from opencode.db
const os = require('os'), path = require('path');
const { DatabaseSync } = require('node:sqlite');

const mode = process.argv[2];

if (mode === 'cursor') {
  // Read Cursor's session token from its local state.vscdb and print the plan
  // usage summary. Cursor stores no quota locally, so we still hit its API,
  // but the SQLite read is what makes this a Node helper.
  try {
    const db = new DatabaseSync(process.env.APPDATA + '\\Cursor\\User\\globalStorage\\state.vscdb', { readOnly: true });
    const token = db.prepare("SELECT value FROM ItemTable WHERE key='cursorAuth/accessToken'").get().value;
    const sub = JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString()).sub;
    const userId = sub.includes('|') ? sub.split('|').pop() : sub;
    fetch('https://cursor.com/api/usage-summary', {
      headers: { Cookie: `WorkosCursorSessionToken=${userId}%3A%3A${token}` },
      signal: AbortSignal.timeout(8000),
    })
      .then((r) => r.json())
      .then((j) => {
        console.log(JSON.stringify({
          api: j.individualUsage.plan.apiPercentUsed,
          total: j.individualUsage.plan.totalPercentUsed,
          resets: j.billingCycleEnd,
        }));
      })
      .catch((e) => console.log(JSON.stringify({ error: String(e) })));
  } catch (e) {
    console.log(JSON.stringify({ error: String(e) }));
  }
} else if (mode === 'opencode') {
  // OpenCode Zen is a prepaid-credit product with no usage/quota API reachable
  // from the local API key, so we report locally-tracked spend from opencode.db
  // (this calendar month + all-time).
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
} else {
  console.log(JSON.stringify({ error: 'usage: sqlite-usage.js cursor|opencode' }));
}
