// Drives the real public capture API against the native WKWebView fixture.
import assert from 'node:assert/strict';
import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { setTimeout as wait } from 'node:timers/promises';
import { captureIOSWebViewAds } from '../mobilewright/ios-ad-capture.mjs';

const [channel, sessionDirectory, navigateTo, mode] = process.argv.slice(2);
const capture = await captureIOSWebViewAds({ channel, sessionDirectory, navigateTo, waitForGate: true });
try {
  const deadline = Date.now() + 15_000;
  for (;;) {
    const records = (await readFile(join(sessionDirectory, 'ad-events.jsonl'), 'utf8')).trim().split('\n').map(JSON.parse);
    if (records.some((record) => record.type === 'bidResponse' && record.page.endsWith('/second'))) break;
    assert.ok(Date.now() < deadline, 'The second document must produce a bid response');
    await wait(100);
  }
  if (mode === 'closed') {
    await writeFile(join(sessionDirectory, 'fixture-command'), 'close');
    await wait(500);
  }
} finally {
  await capture.stop();
  await capture.stop(); // Teardown is idempotent.
}
if (mode !== 'closed') await writeFile(join(sessionDirectory, 'fixture-command'), 'navigate');
