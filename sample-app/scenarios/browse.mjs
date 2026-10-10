import { setTimeout as wait } from 'node:timers/promises';

// Run with: network-audit sample-app --scenario sample-app/scenarios/browse.mjs
export default async function ({ screen, expect }) {
  console.log('Wait for the initial ten product requests');
  const loaded = screen.getByText('10 / 10 loaded · 0 failed');
  await expect(loaded).toBeVisible();

  console.log('Scroll down the product feed');
  await screen.swipe('up');
  await screen.swipe('up');

  console.log('Reload the product feed with a new batch of ten GETs');
  const refresh = screen.getByText('Run 10 GETs again');
  await refresh.scrollIntoViewIfNeeded({ direction: 'down', maxSwipes: 8 });
  await refresh.tap();
  await screen.getByText('Sending 10 GETs…').waitFor({ state: 'hidden' });
  await expect(loaded).toBeVisible();

  console.log('Open the BUNTE WebView and accept consent');
  await screen.getByRole('button', { name: /^BUNTE/ }).tap();
  // Native accessibility can reach consent buttons inside cross-origin frames;
  // Mobilewright's WebView Page does not currently implement frameLocator.
  const consent = screen.getByText(/^(Akzeptieren|Alle akzeptieren|Zustimmen|Accept all)$/i);
  await consent.tap({ timeout: 60_000 });
  await consent.waitFor({ state: 'hidden', timeout: 30_000 });

  // BUNTE can show a separate, delayed push-notification opt-in after consent.
  // Decline it when present rather than swiping an overlay or subscribing.
  const declinePush = screen.getByRole('button', { name: /^ABLEHNEN$/i });
  const pushDeadline = Date.now() + 10_000;
  while (Date.now() < pushDeadline) {
    if (await declinePush.isVisible()) {
      console.log('Decline optional push notifications');
      await declinePush.tap();
      await declinePush.waitFor({ state: 'hidden' });
      break;
    }
    await wait(500);
  }

  console.log('Scroll in the WebView, then capture five more seconds');
  await screen.swipe('up');
  await screen.swipe('up');
  await wait(5_000);
}
