import { createServer } from 'node:net';
import { pathToFileURL } from 'node:url';
import { android, expect } from 'mobilewright';
import { MobilecliDriver, resolveMobilecliBinary } from '@mobilewright/driver-mobilecli';

const [major, minor] = process.versions.node.split('.').map(Number);
if (major < 22 || (major === 22 && minor < 12)) {
  throw new Error('Scenarios require Node.js >=22.12.');
}

if (process.argv[2] === '--check') {
  console.log(resolveMobilecliBinary());
} else {
  const [filename, serial, deviceId, packageName, sessionDirectory] = process.argv.slice(2);
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
  const driver = new MobilecliDriver({ url: `ws://127.0.0.1:${port}/ws` });
  let device;
  try {
    device = await android.launch({
      driver,
      deviceId,
      // The audit already launched the app after installing its capture CA.
      // Relaunching here would issue an unintended second batch of requests.
      autoAppLaunch: false,
      actionTimeout: 30_000,
      expectTimeout: 30_000,
    });
    console.log(`Scenario started: ${filename} on ${serial}`);
    await scenario({ device, screen: device.screen, expect, serial, packageName, sessionDirectory });
    console.log('Scenario completed');
  } finally {
    try {
      await device?.close();
    } finally {
      // Covers failures during discovery/connection before launch returns.
      await driver.dispose();
    }
  }
}
