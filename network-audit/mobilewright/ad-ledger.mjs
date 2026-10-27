import { randomUUID } from 'node:crypto';
import { closeSync, fsyncSync, openSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

// One writer owns the final ledger on either backend. Page messages are data,
// never commands; transport metadata cannot be overridden by the page.
export function createAdLedger(sessionDirectory, transport, gated) {
  const captureId = randomUUID();
  const binding = `__networkAuditAd_${captureId.replaceAll('-', '')}`;
  const descriptor = openSync(join(sessionDirectory, 'ad-events.jsonl'), 'a', 0o600);
  let closed = false;
  const write = (record) => {
    if (closed) return;
    writeFileSync(descriptor, JSON.stringify({
      ...record, schemaVersion: 1, captureId, receivedAt: new Date().toISOString(),
    }) + '\n');
    fsyncSync(descriptor);
  };
  const host = (type, data) => write({ type, data, source: 'host' });
  host('captureStarted', { transport, gated });
  return {
    binding,
    host,
    receive(payload) {
      let record;
      try {
        record = JSON.parse(payload);
        if (!record || typeof record.type !== 'string' || !Number.isInteger(record.sequence) ||
            typeof record.documentId !== 'string' || !record.data || typeof record.data !== 'object') {
          throw new Error('invalid record');
        }
      } catch {
        host('diagnostic', { message: 'Invalid ad binding record; evidence may be missing.' });
        return;
      }
      write(record);
    },
    close(data) {
      if (closed) return;
      try { host('captureStopped', data); }
      finally {
        closed = true;
        closeSync(descriptor);
      }
    },
  };
}
