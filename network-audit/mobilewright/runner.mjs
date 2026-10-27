import { createServer } from 'node:net';
import { pathToFileURL } from 'node:url';
import { android, ios, expect } from 'mobilewright';
import { MobilecliDriver, resolveMobilecliBinary } from '@mobilewright/driver-mobilecli';
import { NativeAndroidDriver } from './native-android-driver.mjs';
import { NativeIOSDriver } from './native-ios-driver.mjs';
import { captureWebViewAds } from './ad-capture.mjs';
import { captureIOSWebViewAds } from './ios-ad-capture.mjs';

const [major, minor] = process.versions.node.split('.').map(Number);
if (major < 22 || (major === 22 && minor < 12)) {
  throw new Error('Scenarios require Node.js >=22.12.');
}

if (process.argv[2] === '--check') {
  console.log(resolveMobilecliBinary());
} else {
  const [filename, serial, deviceId, packageName, sessionDirectory, backend = 'android'] = process.argv.slice(2);
  if (!['android', 'ios'].includes(backend)) {
    throw new Error(`Unsupported backend: ${backend}`);
  }
  const { default: scenario } = await import(pathToFileURL(filename).href);
  if (typeof scenario !== 'function') {
    throw new Error('Scenario must export default async function (context).');
  }

  // Do not adopt a server on Mobilewright's shared default port (12000).
  const reservation = createServer();
  await new Promise((resolve, reject) => {
    reservation.once('error', reject);
    reservation.listen(0, '127.0.0.1', resolve);
  });
  const { port } = reservation.address();
  await new Promise((resolve, reject) => {
    reservation.close((error) => (error ? reject(error) : resolve()));
  });
  const url = `ws://127.0.0.1:${port}/ws`;
  const driver = backend === 'ios'
    ? new NativeIOSDriver({ url, deviceId })
    : process.platform === 'darwin'
      ? new NativeAndroidDriver({ url, deviceId })
      : new MobilecliDriver({ url });
  let device;
  let adCapture;
  let startingCapture;
  const startAds = async (options = {}) => {
    if (startingCapture) throw new Error('WebView ad capture already started');
    startingCapture = backend === 'ios'
      ? captureIOSWebViewAds({ ...options, sessionDirectory, channel: process.env.NETWORK_AUDIT_IOS_AD_CHANNEL })
      : captureWebViewAds({ ...options, serial, packageName, sessionDirectory });
    adCapture = await startingCapture;
  };
  try {
    device = await (backend === 'ios' ? ios : android).launch({
      driver,
      deviceId,
      // The audit already launched the app after installing its capture CA.
      // Relaunching here would issue an unintended second batch of requests.
      autoAppLaunch: false,
      actionTimeout: 30_000,
      expectTimeout: 30_000,
    });
    console.log(`Scenario started: ${filename} on ${serial}`);
    await scenario({ device, screen: device.screen, expect, serial, packageName, sessionDirectory, backend, captureWebViewAds: startAds });
    console.log('Scenario completed');
  } finally {
    try {
      // A failure still flushes the current document. Forced termination leaves
      // an append-only partial ledger (no captureStopped), visible in the report.
      await adCapture?.stop();
    } finally {
      try {
        await device?.close();
      } finally {
        // Covers failures during discovery/connection before launch returns.
        await driver.dispose();
      }
    }
  }
}
