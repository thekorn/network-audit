import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { setTimeout as wait } from 'node:timers/promises';

// Native acceptance on a Mac: do not confuse successful UI requests with
// successful interception. Require each of the ten HTTPS responses in capture.
export default async function ({ screen, expect, sessionDirectory, backend }) {
  assert.equal(backend, 'ios', 'Run this scenario with --backend=ios');
  await expect(screen.getByText('10 / 10 loaded · 0 failed')).toBeVisible();
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    const records = (await readFile(join(sessionDirectory, 'events.jsonl'), 'utf8'))
      // Ignore a final line that mitmproxy is still writing; retry next poll.
      .split('\n').slice(0, -1).filter(Boolean).map((line) => JSON.parse(line));
    const captured = new Set(records.filter((record) =>
      record.host === 'dummyjson.com' && record.method === 'GET' &&
      record.response?.status === 200 && new URL(record.url).protocol === 'https:'
    ).map((record) => new URL(record.url).pathname));
    if (Array.from({ length: 10 }, (_, index) => `/products/${index + 1}`)
      .every((path) => captured.has(path))) {
      console.log('Verified all ten product HTTPS responses in the capture');
      return;
    }
    await wait(250);
  }
  throw new Error('App loaded products but capture did not contain all ten responses; inspect local capture and Simulator CA trust');
}
