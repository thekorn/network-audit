import { randomUUID } from 'node:crypto';
import { open, readFile, rename, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { setTimeout as wait } from 'node:timers/promises';
import { createAdLedger } from './ad-ledger.mjs';
import { installAdObserver } from './ad-observer.mjs';

// The launch-only helper and runner share a private temporary directory. No
// Safari debugging, host-wide WebKit selector, TCP listener or app SDK needed.
export async function captureIOSWebViewAds({ channel, sessionDirectory, navigateTo, waitForGate = false }) {
  const ledger = createAdLedger(sessionDirectory, 'iOS WKWebView script message', !!navigateTo);
  const { binding, host } = ledger;
  let spool, timer, draining, stopping;
  let position = 0;
  let tail = Buffer.alloc(0);
  let attempted = false;
  let readFailure = false;
  const command = async (operation, options = {}) => {
    const id = randomUUID();
    await writeFile(join(channel, 'request.tmp'), JSON.stringify({ id, operation, ...options }), { mode: 0o600 });
    await rename(join(channel, 'request.tmp'), join(channel, 'request.json'));
    const deadline = Date.now() + 10_000;
    while (Date.now() < deadline) {
      let response;
      try { response = JSON.parse(await readFile(join(channel, 'response.json'), 'utf8')); }
      catch (error) { if (error.code !== 'ENOENT') throw error; }
      if (response?.id === id) {
        if (response.error) throw new Error(response.error);
        return response;
      }
      await wait(50);
    }
    throw new Error(`iOS WebView helper timed out: ${operation}; evidence may be incomplete`);
  };
  const drain = () => {
    draining ||= (async () => {
      if (!spool) {
        try { spool = await open(join(channel, 'events.jsonl'), 'r'); }
        catch (error) { if (error.code === 'ENOENT') return; throw error; }
      }
      const buffer = Buffer.alloc(64 * 1024);
      for (;;) {
        const { bytesRead } = await spool.read(buffer, 0, buffer.length, position);
        if (!bytesRead) break;
        position += bytesRead;
        tail = Buffer.concat([tail, buffer.subarray(0, bytesRead)]);
        let newline;
        while ((newline = tail.indexOf(10)) !== -1) {
          ledger.receive(JSON.parse(tail.subarray(0, newline).toString('utf8')).payload);
          tail = tail.subarray(newline + 1);
        }
      }
    })().finally(() => { draining = undefined; });
    return draining;
  };
  const stop = () => {
    stopping ||= (async () => {
      clearInterval(timer);
      let flushed = false, disconnected = false;
      try {
        if (attempted) {
          const result = await command('stop');
          flushed = result.flushed === true;
          disconnected = result.disconnected === true;
        }
      } catch (error) {
        disconnected = true;
        host('diagnostic', { message: `Final ad flush failed: ${error.message}` });
      }
      try {
        await draining;
        if (attempted) await drain();
        if (tail.length) throw new Error('Truncated iOS ad message');
      } catch (error) {
        readFailure = true;
        host('diagnostic', { message: `Ad message read failed: ${error.message}` });
      } finally {
        await spool?.close();
        ledger.close({ flushed: flushed && !readFailure, disconnected });
      }
    })();
    return stopping;
  };
  try {
    if (!channel) throw new Error('iOS ad capture requires the app-scoped WebKit helper on iOS 17+');
    if (navigateTo && !['https:', 'http:'].includes(new URL(navigateTo).protocol)) {
      throw new Error('Ad capture navigation requires an HTTP(S) URL');
    }
    const deadline = Date.now() + 30_000;
    for (;;) {
      const target = await command('inspect');
      if (target.count > 1) throw new Error('Multiple app WKWebViews; refusing ambiguous ad attribution');
      if (target.count === 1) {
        if (navigateTo && target.url !== 'about:blank') {
          throw new Error('Gated ad capture requires about:blank. Build with browse.env.json; refusing to reload and lose the first auction.');
        }
        if (!waitForGate || target.gateReady) break;
      }
      if (Date.now() > deadline) throw new Error('No ready app WKWebView found; check the audit gate');
      await wait(100);
    }
    const source = (mode) => `
      window[${JSON.stringify(binding)}] = (payload) => {
        window.webkit.messageHandlers[${JSON.stringify(binding)}].postMessage(payload).catch(() => {});
      };
      (${installAdObserver.toString()})(${JSON.stringify(binding)}, ${mode});`;
    // Recheck inside the same JS turn as installation, not only during discovery.
    const initialSource = `
      if (${!!navigateTo} && location.href !== 'about:blank') throw new Error('Audit gate navigated before capture');
      if (${!!waitForGate} && window.__networkAuditGateReady !== true) throw new Error('Audit gate is not ready');
      ${source("location.href === 'about:blank' ? 'initial-blank' : 'late-attach'")}
      await window.webkit.messageHandlers[${JSON.stringify(binding)}].postMessage(null);
      return true;`;
    attempted = true;
    await command('start', { binding, source: source("'document-start'"), initialSource, navigateTo });
    await drain();
    timer = setInterval(() => {
      drain().catch((error) => {
        clearInterval(timer);
        readFailure = true;
        host('diagnostic', { message: `Ad message read failed: ${error.message}` });
      });
    }, 100);
    return { stop };
  } catch (error) {
    host('diagnostic', { message: error.message });
    await stop();
    throw error;
  }
}
