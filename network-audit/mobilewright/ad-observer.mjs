// Runs in the page's main world. Keep this function self-contained: CDP sends
// its source, not this module. Only selected ad evidence crosses the binding.
export function installAdObserver(binding, installation) {
  if (window !== window.top || window.__networkAuditAds) return;
  // randomUUID is unavailable on the initial, insecure about:blank document.
  const documentId = Array.from(crypto.getRandomValues(new Uint32Array(4)),
    (word) => word.toString(16).padStart(8, '0')).join('');
  let sequence = 0;
  let stopped = false;
  const clean = (value) => JSON.parse(JSON.stringify(value));
  const pick = (object, fields) => Object.fromEntries(
    fields.map((key) => [key, object?.[key] ?? null]),
  );
  const emit = (type, data, source = 'live') => {
    if (stopped) return;
    // Serialization happens at observation time, before the publisher can
    // mutate bid/auction objects. No creative HTML, IDs for users, or cookies.
    window[binding](JSON.stringify({
      type, data, source, documentId, sequence: ++sequence,
      observedAt: new Date().toISOString(), elapsedMs: performance.now(),
      timeOrigin: performance.timeOrigin,
      page: location.protocol === 'about:' ? 'about:blank' : location.origin + location.pathname,
    }));
  };
  const errors = new Set();
  const attempt = (name, action) => {
    try {
      return action();
    } catch (error) {
      if (!errors.has(name)) {
        errors.add(name);
        emit('diagnostic', { message: `${name}: ${String(error)}` });
      }
      return null;
    }
  };
  const bid = (value) => ({
    ...pick(value, [
      'adUnitCode', 'auctionId', 'requestId', 'bidId', 'bidderRequestId', 'adId',
      'bidder', 'bidderCode', 'source', 'src', 'cpm', 'currency', 'originalCpm',
      'originalCurrency', 'pbCg', 'netRevenue', 'width', 'height', 'mediaType',
      'creativeId', 'dealId', 'advertiser', 'status', 'won', 'timeToRespond',
      'requestTimestamp', 'responseTimestamp', 'rejectionReason',
    ]),
    meta: pick(value?.meta, ['brandName', 'advertiserName', 'advertiserDomains']),
  });
  const targeting = (slot) => Object.fromEntries(
    Object.entries(slot?.getTargetingMap?.() || {}).filter(([key]) => /^(hb_|amzn)/.test(key)),
  );
  const types = [
    'auctionInit', 'auctionEnd', 'bidRequested', 'bidResponse', 'noBid',
    'bidTimeout', 'bidRejected', 'bidWon', 'adRenderSucceeded', 'adRenderFailed',
  ];
  const subscriptions = [];
  const prebidInstances = new WeakSet();
  const gptInstances = new WeakSet();
  let prebidObserved = false;
  let gptObserved = false;
  let stfObserved = false;
  let lastSnapshot;

  function prebidEvent(type, args, source = 'live', history = null) {
    let data;
    if (type === 'bidRequested') {
      data = {
        ...pick(args, ['auctionId', 'bidderCode', 'bidderRequestId', 'src']),
        bids: (args?.bids || []).map((item) => ({
          ...bid(item),
          auctionId: item.auctionId ?? args.auctionId ?? null,
          bidderCode: item.bidderCode ?? args.bidderCode ?? null,
          src: item.src ?? args.src ?? null,
        })),
      };
    } else if (type === 'bidTimeout') {
      data = { bids: (Array.isArray(args) ? args : []).map(bid) };
    } else if (type === 'auctionInit' || type === 'auctionEnd') {
      data = pick(args, [
        'auctionId', 'timestamp', 'auctionStart', 'auctionEnd', 'auctionStatus',
        'adUnitCodes', 'timeout',
      ]);
    } else if (type.startsWith('adRender')) {
      // A failed render can carry only adId, with no recoverable bid object.
      data = { bid: args?.bid ? bid(args.bid) : null, ...pick(args, ['adId', 'reason', 'message']) };
    } else {
      data = { bid: bid(args) };
    }
    emit(type, { ...data, history }, source);
    // STF's own callbacks can update its winning flags after our listener.
    queueMicrotask(() => attempt('STF snapshot', snapshot));
  }

  function attachPrebid() {
    const pb = window.pbjs;
    if (!pb?.onEvent || prebidInstances.has(pb)) return;
    prebidInstances.add(pb);
    prebidObserved = true;
    emit('instrumentation', { provider: 'prebid', version: pb.version ?? null });
    for (const type of types) {
      const handler = (args) => attempt(`Prebid ${type}`, () => prebidEvent(type, args));
      pb.onEvent(type, handler);
      subscriptions.push(() => pb.offEvent?.(type, handler));
    }
    // A retained payload may already be mutated. Never label it event-time data.
    if (pb.getEvents) {
      for (const event of pb.getEvents()) {
        if (types.includes(event.eventType)) {
          prebidEvent(event.eventType, event.args, 'backfill',
            pick(event, ['sequence', 'elapsedTime']));
        }
      }
    } else {
      emit('diagnostic', { message: 'Prebid history unavailable; earlier events cannot be recovered.' });
    }
  }

  function attachGpt() {
    if (!window.googletag?.pubads) return;
    const pubads = window.googletag.pubads();
    if (gptInstances.has(pubads)) return;
    gptInstances.add(pubads);
    gptObserved = true;
    emit('instrumentation', { provider: 'gpt' });
    for (const type of ['slotRequested', 'slotResponseReceived', 'slotRenderEnded', 'slotOnload', 'impressionViewable']) {
      const handler = (event) => attempt(`GPT ${type}`, () => {
        emit(type, {
          containerId: event.slot.getSlotElementId(),
          gptAdUnitPath: event.slot.getAdUnitPath(),
          targeting: targeting(event.slot),
          ...pick(event, [
            'isEmpty', 'size', 'advertiserId', 'campaignId', 'lineItemId', 'creativeId',
            'sourceAgnosticLineItemId', 'sourceAgnosticCreativeId', 'responseIdentifier',
          ]),
        });
        queueMicrotask(() => attempt('STF snapshot', snapshot));
      });
      pubads.addEventListener(type, handler);
      subscriptions.push(() => pubads.removeEventListener(type, handler));
    }
  }

  function snapshot() {
    if (typeof window._aeq?.get !== 'function') return;
    const get = (name) => window._aeq.get(name);
    const slots = get('adSlot');
    if (!slots) return;
    stfObserved = true;
    const buckets = get('viewabilityBuckets');
    const data = {
      versions: { stf: get('adEngineVersion') ?? null, config: get('adEngineConfigVersion') ?? null },
      slots: Object.entries(slots).map(([key, slot]) => {
        const bucketKey = String(slot.placementCode || '').split('_').slice(2).join('_');
        return {
          key,
          ...pick(slot, [
            'sequence', 'containerId', 'placementCode', 'adUnitString', 'relevantPlacementId',
            'status', 'latency', 'size', 'allowReload', 'reloadCount', 'visible', 'isVideo',
          ]),
          viewabilityBucket: Object.entries(buckets || {}).find(
            ([, codes]) => Array.isArray(codes) && codes.includes(bucketKey),
          )?.[0] ?? null,
          gptAdObj: slot.gptAdObj ? pick(slot.gptAdObj, [
            'width', 'height', 'campaignId', 'lineItemId', 'creativeId', 'adResponseId',
          ]) : null,
          debugInfo: slot.debugInfo ? pick(slot.debugInfo, [
            'type', 'template', 'size', 'advertiserId', 'orderId', 'lineItemId', 'creativeId',
          ]) : null,
          gptAdUnitPath: slot.googleTagObject?.getAdUnitPath?.() ?? null,
          currentAdTargeting: targeting(slot.googleTagObject),
          overlayBids: (slot.preBids || []).map(bid),
          retainedPrebidBids: slot.relevantPlacementId
            ? (window.pbjs?.getBidResponsesForAdUnitCode?.(slot.relevantPlacementId)?.bids || []).map(bid) : [],
          amazon: { apsBidCount: slot.apsBids?.length ?? null,
            relevantBidPresent: !!slot.amazonRYBid, price: 'not exposed by the overlay' },
        };
      }),
      prebidRecordedWins: (window.pbjs?.getAllWinningBids?.() || []).map(bid),
    };
    const encoded = JSON.stringify(data);
    if (encoded !== lastSnapshot) {
      lastSnapshot = encoded;
      emit('slotSnapshot', clean(data), 'snapshot');
    }
  }

  const coverage = () => ({ prebidObserved, gptObserved, stfObserved });
  const sample = () => {
    attempt('Prebid attach', attachPrebid);
    attempt('GPT attach', attachGpt);
    attempt('STF snapshot', snapshot);
  };
  emit('documentStarted', {
    installation, scope: 'Top-level pbjs, GPT and STF only',
    snapshotIntervalMs: 250,
    excluded: 'Cookies, consent, user IDs, bidder parameters, creative markup and unrelated targeting',
  });
  // Use the vendors' command queues before publisher auction commands. Polling
  // also catches replaced globals, but cannot guarantee transient STF states.
  window.pbjs = window.pbjs || { que: [] };
  window.pbjs.que = window.pbjs.que || [];
  window.pbjs.que.push(() => attempt('Prebid attach', attachPrebid));
  window.googletag = window.googletag || { cmd: [] };
  window.googletag.cmd = window.googletag.cmd || [];
  window.googletag.cmd.push(() => attempt('GPT attach', attachGpt));
  sample();
  const interval = setInterval(sample, 250);
  const heartbeat = setInterval(() => emit('coverage', coverage()), 1000);
  const onPageHide = (event) => {
    sample();
    emit('documentHidden', { ...coverage(), persisted: event.persisted });
  };
  window.addEventListener('pagehide', onPageHide);
  window.__networkAuditAds = {
    stop() {
      sample();
      emit('documentStopped', coverage());
      stopped = true;
      clearInterval(interval);
      clearInterval(heartbeat);
      window.removeEventListener('pagehide', onPageHide);
      for (const unsubscribe of subscriptions) attempt('Unsubscribe', unsubscribe);
    },
  };
}
