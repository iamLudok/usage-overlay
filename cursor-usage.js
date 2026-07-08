// Reads Cursor's session token from its local state.vscdb and prints
// the plan usage summary as one JSON line. Called by usage-overlay.ps1.
const { DatabaseSync } = require('node:sqlite');
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
