import assert from 'node:assert/strict';
import { test } from 'node:test';
import { runInNewContext } from 'node:vm';
import { installAdObserver } from '../mobilewright/ad-observer.mjs';

function page() {
  const records = [], timers = new Map(), listeners = new Map();
  const window = { emit: (value) => records.push(JSON.parse(value)) };
  window.top = window;
  window.addEventListener = (type, fn) => listeners.set(type, fn);
  window.removeEventListener = (type) => listeners.delete(type);
  let id = 0;
  runInNewContext(`(${installAdObserver})('emit', 'document-start')`, {
    window, crypto: { getRandomValues: (values) => values.fill(1) },
    location: { origin: 'https://publisher.test', pathname: '/news' },
    performance: { now: () => 42, timeOrigin: 1000 },
    setInterval: (fn) => { timers.set(++id, fn); return id; },
    clearInterval: (key) => timers.delete(key),
    queueMicrotask: (fn) => fn(),
  });
  return { window, records, timers, listeners };
}

test('event ledger detaches prices, aliases, timeouts and refresh generations before mutation', () => {
  const { window, records } = page();
  const handlers = new Map();
  Object.assign(window.pbjs, {
    version: 'fixture', getEvents: () => [],
    onEvent: (type, fn) => handlers.set(type, fn), offEvent() {},
  });
  window.pbjs.que.forEach((fn) => fn());
  const send = (type, value) => handlers.get(type)(value);
  const request = { auctionId: 'first', bidderCode: 'yieldlab_s2s_alias', src: 's2s', bids: [
    { bidId: 'request-a', adUnitCode: '/wildcard/*/top', params: { secret: 'PRIVATE_SENTINEL' } },
    { bidId: 'request-b', adUnitCode: '/different-slot' },
  ] };
  send('bidRequested', request);
  send('bidTimeout', [{ bidId: 'request-a', auctionId: 'first', adUnitCode: '/wildcard/*/top' }]);
  const response = { auctionId: 'first', requestId: 'request-a', adId: 'ad-a',
    adUnitCode: '/wildcard/*/top', bidder: 'yieldlab_s2s_alias', cpm: 2.37,
    currency: 'EUR', originalCpm: 2.61, originalCurrency: 'USD', pbCg: '2.30',
    creativeId: 'bidder-creative', ad: '<script>PRIVATE_SENTINEL</script>' };
  send('bidResponse', response);
  send('bidWon', response);
  response.cpm = 999;
  response.won = true;
  request.bids[0].bidId = 'mutated';
  send('noBid', { bidId: 'request-b', auctionId: 'first', adUnitCode: '/different-slot' });
  send('bidRequested', { ...request, auctionId: 'refresh', bids: [{bidId: 'request-c', adUnitCode: '/wildcard/*/top'}] });
  send('adRenderFailed', { adId: 'orphan-ad', reason: 'cannotFindAd', message: 'No bid available' });
  window.__networkAuditAds.stop();
  assert.deepEqual(records.find((r) => r.type === 'adRenderFailed').data, {
    bid: null, adId: 'orphan-ad', reason: 'cannotFindAd', message: 'No bid available', history: null,
  });
  const events = records.filter((r) => ['bidRequested', 'bidTimeout', 'bidResponse', 'bidWon', 'noBid'].includes(r.type));
  assert.deepEqual(events.map((r) => r.type), ['bidRequested', 'bidTimeout', 'bidResponse', 'bidWon', 'noBid', 'bidRequested']);
  assert.deepEqual(events[0].data.bids.map((b) => [b.bidId, b.auctionId, b.bidderCode, b.src]), [
    ['request-a', 'first', 'yieldlab_s2s_alias', 's2s'], ['request-b', 'first', 'yieldlab_s2s_alias', 's2s'],
  ]);
  assert.equal(events[2].data.bid.cpm, 2.37);
  assert.equal(events[2].data.bid.originalCpm, 2.61);
  assert.equal(events[2].data.bid.pbCg, '2.30');
  assert.equal(events[2].data.bid.won, null);
  assert.equal(events[5].data.bids[0].auctionId, 'refresh');
  assert.ok(!JSON.stringify(records).includes('PRIVATE_SENTINEL'));
  assert.deepEqual(records.map((r) => r.sequence), records.map((_, i) => i + 1));
});

test('late history stays backfill; STF mappings, GPT IDs and changing win snapshots remain separate', () => {
  const { window, records, timers } = page();
  const response = { adId: 'ad-1', requestId: 'request-1', auctionId: 'auction-1',
    adUnitCode: '/wildcard/*/top', bidder: 'client-alias', creativeId: 'bidder-id', cpm: 0, won: false };
  Object.assign(window.pbjs, {
    onEvent() {}, offEvent() {},
    getEvents: () => [{eventType: 'bidResponse', sequence: 27, elapsedTime: 19, args: response}],
    getBidResponsesForAdUnitCode: () => ({ bids: [response] }),
    getAllWinningBids: () => [],
  });
  const handlers = new Map();
  const pubads = { addEventListener: (name, fn) => handlers.set(name, fn), removeEventListener() {} };
  window.googletag.pubads = () => pubads;
  const googleSlot = { getSlotElementId: () => 'dom-1', getAdUnitPath: () => '/gam/actual',
    getTargetingMap: () => ({ hb_adid: ['ad-1'], amznslots: ['slot'], user: ['PRIVATE_SENTINEL'] }) };
  const slot = { containerId: 'dom-1', placementCode: 'stf-top', relevantPlacementId: '/wildcard/*/top',
    googleTagObject: googleSlot, reloadCount: 0, preBids: [response],
    gptAdObj: { campaignId: 'order-id', lineItemId: 'line-id', creativeId: 'gam-id', adResponseId: 'response-id' } };
  window._aeq = { get: (key) => key === 'adSlot' ? { tag1: slot } : null };
  timers.get(1)();
  handlers.get('slotRenderEnded')({ slot: googleSlot, isEmpty: false, sourceAgnosticCreativeId: 'gam-id' });
  response.won = true;
  slot.reloadCount = 1;
  timers.get(1)();
  window.__networkAuditAds.stop();
  const history = records.find((r) => r.type === 'bidResponse');
  assert.equal(history.source, 'backfill');
  assert.deepEqual(history.data.history, { sequence: 27, elapsedTime: 19 });
  const snapshots = records.filter((r) => r.type === 'slotSnapshot');
  assert.equal(snapshots.length, 2);
  assert.deepEqual(snapshots.map((r) => r.data.slots[0].reloadCount), [0, 1]);
  assert.deepEqual(snapshots.map((r) => r.data.slots[0].overlayBids[0].won), [false, true]);
  const first = snapshots[0].data.slots[0];
  assert.equal(first.placementCode, 'stf-top');
  assert.equal(first.relevantPlacementId, '/wildcard/*/top');
  assert.equal(first.gptAdUnitPath, '/gam/actual');
  assert.equal(first.gptAdObj.creativeId, 'gam-id');
  assert.equal(first.overlayBids[0].creativeId, 'bidder-id');
  assert.equal(first.overlayBids[0].cpm, 0);
  assert.equal(first.viewabilityBucket, null);
  assert.deepEqual(first.currentAdTargeting, { hb_adid: ['ad-1'], amznslots: ['slot'] });
  assert.ok(!JSON.stringify(records).includes('PRIVATE_SENTINEL'));
  assert.deepEqual(records.at(-1).data, { prebidObserved: true, gptObserved: true, stfObserved: true });
  assert.equal(timers.size, 0);
});

test('missing runtimes and pagehide are coverage evidence, never fabricated no-bids', () => {
  const { window, records, listeners } = page();
  listeners.get('pagehide')({ persisted: false });
  window.__networkAuditAds.stop();
  assert.deepEqual(records.map((r) => r.type), ['documentStarted', 'documentHidden', 'documentStopped']);
  assert.deepEqual(records.at(-1).data, { prebidObserved: false, gptObserved: false, stfObserved: false });
});
