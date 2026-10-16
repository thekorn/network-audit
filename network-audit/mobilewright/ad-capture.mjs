import { execFile } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { closeSync, fsyncSync, openSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { setTimeout as wait } from 'node:timers/promises';
import { promisify } from 'node:util';
import { installAdObserver } from './ad-observer.mjs';

const execute = promisify(execFile);

// A persistent CDP socket is necessary: Mobilewright 0.0.64 has no init scripts
// or event subscriptions, and its Android injection helper is ARM64-only.
export async function connectCdp(url, onEvent, onDisconnect) {
  const socket = new WebSocket(url);
  const pending = new Map();
  let nextId = 0;
  let closing = false;
  const fail = (error) => {
    for (const request of pending.values()) request.reject(error);
    pending.clear();
  };
  socket.addEventListener('message', ({ data }) => {
    const message = JSON.parse(data);
    if (message.id) {
      const request = pending.get(message.id);
      if (!request) return;
      pending.delete(message.id);
      if (message.error) request.reject(new Error(message.error.message));
      else request.resolve(message.result);
    } else {
      onEvent(message);
    }
  });
  socket.addEventListener('close', () => {
    fail(new Error('WebView CDP disconnected'));
    if (!closing) onDisconnect();
  });
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      socket.close();
      reject(new Error('Timed out connecting to WebView CDP'));
    }, 10_000);
    socket.addEventListener('open', () => { clearTimeout(timer); resolve(); }, { once: true });
    socket.addEventListener('error', () => {
      clearTimeout(timer);
      reject(new Error('Could not connect to WebView CDP'));
    }, { once: true });
  });
  return {
    async send(method, params = {}) {
      if (socket.readyState !== WebSocket.OPEN) throw new Error('WebView CDP is not connected');
      const id = ++nextId;
      let timer;
      try {
        return await new Promise((resolve, reject) => {
          pending.set(id, { resolve, reject });
          timer = setTimeout(() => reject(new Error(`WebView CDP timed out: ${method}`)), 5000);
          socket.send(JSON.stringify({ id, method, params }));
        });
      } finally {
        clearTimeout(timer);
        pending.delete(id);
      }
    },
    close() {
      closing = true;
      fail(new Error('WebView CDP closed'));
      socket.close();
    },
  };
}

// Low-level transport also used by the real-browser integration tests. It never
// rewrites prior records; a killed process leaves a visibly unfinished capture.
export async function captureAdTarget({ url, sessionDirectory, navigateTo, waitForGate = false }) {
  const captureId = randomUUID();
  const binding = `__networkAuditAd_${captureId.replaceAll('-', '')}`;
  const descriptor = openSync(join(sessionDirectory, 'ad-events.jsonl'), 'a', 0o600);
  let closed = false;
  let disconnected = false;
  let client;
  let script;
  let stopping;
  const write = (record) => {
    if (closed) return;
    writeFileSync(descriptor, JSON.stringify({
      ...record, schemaVersion: 1, captureId, receivedAt: new Date().toISOString(),
    }) + '\n');
    // Ad evidence is small relative to HTTP bodies. Persist it as it arrives,
    // not only when the scenario finishes or a WebView snapshot is requested.
    fsyncSync(descriptor);
  };
  const host = (type, data) => write({ type, data, source: 'host' });
  const evaluate = async (expression) => {
    const result = await client.send('Runtime.evaluate', { expression, returnByValue: true });
    if (result.exceptionDetails) throw new Error(`Ad observer evaluation failed: ${result.exceptionDetails.exception?.description ?? result.exceptionDetails.text}`);
    return result.result?.value;
  };
  const stop = () => {
    stopping ||= (async () => {
      let flushed = false;
      try {
        if (client && !disconnected) {
          if (script) await client.send('Page.removeScriptToEvaluateOnNewDocument', { identifier: script });
          flushed = await evaluate('!!window.__networkAuditAds && (window.__networkAuditAds.stop(), true)');
          await client.send('Runtime.removeBinding', { name: binding });
        }
      } catch (error) {
        host('diagnostic', { message: `Final ad flush failed: ${error.message}` });
      } finally {
        client?.close();
        host('captureStopped', { flushed, disconnected });
        closed = true;
        closeSync(descriptor);
      }
    })();
    return stopping;
  };
  host('captureStarted', { transport: 'Android WebView CDP', gated: !!navigateTo });
  try {
    client = await connectCdp(url, (event) => {
      if (event.method !== 'Runtime.bindingCalled' || event.params.name !== binding) return;
      // Page data is untrusted. Never interpret it as code or a file path.
      let record;
      try {
        record = JSON.parse(event.params.payload);
        if (!record || typeof record.type !== 'string' || !Number.isInteger(record.sequence) ||
            typeof record.documentId !== 'string' || !record.data || typeof record.data !== 'object') {
          throw new Error('invalid record');
        }
      } catch {
        host('diagnostic', { message: 'Invalid ad binding record; evidence may be missing.' });
        return;
      }
      write(record);
    }, () => {
      disconnected = true;
      host('diagnostic', { message: 'WebView CDP disconnected; subsequent ad evidence is not captured.' });
    });
    await client.send('Runtime.enable');
    await client.send('Page.enable');
    const current = await evaluate('location.href');
    if (navigateTo && current !== 'about:blank') {
      throw new Error('Gated ad capture requires about:blank. Build the sample with browse.env.json; refusing to reload and lose the first auction.');
    }
    if (waitForGate) {
      const deadline = Date.now() + 10_000;
      while (!(await evaluate('window.__networkAuditGateReady === true'))) {
        if (Date.now() > deadline) throw new Error('WebView audit gate did not become ready');
        await wait(100);
      }
    }
    await client.send('Runtime.addBinding', { name: binding });
    const source = (mode) => `(${installAdObserver.toString()})(${JSON.stringify(binding)}, ${JSON.stringify(mode)})`;
    ({ identifier: script } = await client.send('Page.addScriptToEvaluateOnNewDocument', { source: source('document-start') }));
    await evaluate(source(current === 'about:blank' ? 'initial-blank' : 'late-attach'));
    if (navigateTo) {
      const result = await client.send('Page.navigate', { url: navigateTo });
      if (result.errorText) throw new Error(`WebView navigation failed: ${result.errorText}`);
    }
    return { stop };
  } catch (error) {
    host('diagnostic', { message: error.message });
    await stop();
    throw error;
  }
}

export async function captureWebViewAds({ serial, packageName, sessionDirectory, navigateTo, waitForGate = false }) {
  if (navigateTo && !['https:', 'http:'].includes(new URL(navigateTo).protocol)) {
    throw new Error('Ad capture navigation requires an HTTP(S) URL');
  }
  const adb = async (...args) => (await execute('adb', ['-s', serial, ...args], { timeout: 10_000 })).stdout.trim();
  let port;
  let capture;
  try {
    const deadline = Date.now() + 30_000;
    while (Date.now() < deadline && !port) {
      // Only inspect the audited app's process, never another app's WebView.
      const pids = (await adb('shell', 'pidof', packageName)).split(/\s+/).filter(Boolean);
      const sockets = await adb('shell', 'cat', '/proc/net/unix');
      const names = [...sockets.matchAll(/@webview_devtools_remote_(\d+)\b/g)]
        .filter((match) => pids.includes(match[1])).map((match) => match[0].slice(1));
      if (names.length > 1) throw new Error('Multiple app WebView sockets; refusing ambiguous ad attribution');
      if (names.length === 1) port = await adb('forward', 'tcp:0', `localabstract:${names[0]}`);
      else await wait(200);
    }
    if (!port) throw new Error('No debuggable WebView found in the audited app');
    let targets = [];
    while (Date.now() < deadline) {
      const response = await fetch(`http://127.0.0.1:${port}/json/list`, { signal: AbortSignal.timeout(5000) });
      if (!response.ok) throw new Error(`WebView discovery failed: HTTP ${response.status}`);
      targets = (await response.json()).filter((target) => target.type === 'page');
      if (targets.length) break;
      await wait(200);
    }
    if (targets.length !== 1) throw new Error(`Expected one app WebView target; found ${targets.length}`);
    const endpoint = new URL(targets[0].webSocketDebuggerUrl);
    endpoint.hostname = '127.0.0.1';
    endpoint.port = port;
    capture = await captureAdTarget({ url: endpoint.href, sessionDirectory, navigateTo, waitForGate });
    return {
      async stop() {
        try { await capture.stop(); }
        finally { await adb('forward', '--remove', `tcp:${port}`); }
      },
    };
  } catch (error) {
    if (port) await adb('forward', '--remove', `tcp:${port}`);
    // Discovery failures precede captureStarted; still leave evidence of the
    // attempt, rather than making this look like ads were never requested.
    writeFileSync(join(sessionDirectory, 'ad-events.jsonl'), JSON.stringify({
      schemaVersion: 1, captureId: randomUUID(), source: 'host', type: 'diagnostic',
      receivedAt: new Date().toISOString(), data: { message: error.message },
    }) + '\n', { flag: 'a', mode: 0o600 });
    throw error;
  }
}
