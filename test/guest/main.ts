// Acceptance checks that run inside the unikernel as `node /app/main.ts`. This file and lib/ are
// TypeScript run directly through Node's type stripping, which is itself one of the checks.
// The host driver passes expectations in through the ops config's Env.
import assert from 'node:assert/strict';
import { pbkdf2 } from 'node:crypto';
import { lookup } from 'node:dns/promises';
import https from 'node:https';
import os from 'node:os';
import tls from 'node:tls';
import { check, emit } from './lib/report.ts';
import { serve } from './lib/server.ts';

type Env = Record<string, string | undefined>;
const env: Env = process.env;

function required(name: string): string {
  const value = env[name];
  if (value === undefined) throw new Error(`${name} is not set`);
  return value;
}

// 1. The native addon first: a missing or incompatible library shows up here.
await check('argon2', async () => {
  const { hash, verify } = await import('@node-rs/argon2');
  const digest = await hash('correct horse battery staple');
  assert.match(digest, /^\$argon2id\$v=19\$/);
  assert.equal(await verify(digest, 'correct horse battery staple'), true);
  assert.equal(await verify(digest, 'wrong password'), false);
  return { digest: digest.slice(0, 30) + '…' };
});

await check('version-and-arch', () => {
  assert.equal(process.version, `v${required('EXPECT_NODE_VERSION')}`);
  assert.equal(process.arch, required('EXPECT_ARCH'));
  assert.equal(process.platform, 'linux');
  const header = (process.report.getReport() as { header: { glibcVersionRuntime?: string } }).header;
  return { version: process.version, arch: process.arch, glibc: header.glibcVersionRuntime };
});

await check('typescript', () => {
  assert.equal(process.features.typescript, 'strip');
  assert.ok(import.meta.filename.endsWith('.ts'));
  return { features: process.features.typescript, entry: import.meta.filename };
});

await check('intl', () => {
  const date = new Date(Date.UTC(2026, 9, 26, 12));
  const nl = new Intl.DateTimeFormat('nl-NL', { dateStyle: 'full', timeZone: 'Europe/Amsterdam' });
  // Small-ICU builds fall back to en-US here; full ICU resolves nl-NL.
  assert.equal(nl.resolvedOptions().locale, 'nl-NL');
  assert.equal(nl.format(date), 'maandag 26 oktober 2026');
  assert.equal(new Intl.NumberFormat('de-DE').format(1234567.891), '1.234.567,891');
  return { icu: process.versions.icu, nl: nl.format(date) };
});

await check('threadpool', async () => {
  const iterations = 300_000;
  const job = () => new Promise<void>((resolve, reject) =>
    pbkdf2('password', 'salt', iterations, 64, 'sha512', (err) => (err ? reject(err) : resolve())));
  const time = async (fn: () => Promise<unknown>) => {
    const start = performance.now();
    await fn();
    return performance.now() - start;
  };
  const single = await time(job);
  let ticks = 0;
  const timer = setInterval(() => ticks++, 5);
  const parallel = await time(() => Promise.all([job(), job(), job(), job()]));
  clearInterval(timer);
  const ratio = parallel / (4 * single);
  // The main thread keeps running timers while pbkdf2 runs: the work is on the libuv pool.
  assert.ok(ticks > 0, 'event loop was blocked during pbkdf2');
  // The VM has two vCPUs: four pool jobs overlap rather than running one after another.
  assert.ok(os.availableParallelism() >= 2, `availableParallelism is ${os.availableParallelism()}`);
  assert.ok(ratio < 0.8, `4 parallel jobs took ${ratio.toFixed(2)} x the serial time`);
  return { cpus: os.availableParallelism(), singleMs: Math.round(single), parallelMs: Math.round(parallel), ratio: +ratio.toFixed(2), ticks };
});

await check('env', () => ({
  TEST_ENV_PROBE: required('TEST_ENV_PROBE'),
  TEST_ENV_SPECIAL: required('TEST_ENV_SPECIAL'),
}));

function tlsHandshake(url: string): Promise<string> {
  const { hostname, port } = new URL(url);
  return new Promise((resolve, reject) => {
    const socket = tls.connect({ host: hostname, port: Number(port) }, () => {
      socket.write('hello\n');
      socket.once('data', (data) => { socket.end(); resolve(data.toString().trim()); });
    });
    socket.once('error', reject);
  });
}

function httpsGet(url: string): Promise<string> {
  return new Promise((resolve, reject) => {
    https.get(url, (res) => {
      let body = '';
      res.on('data', (chunk) => (body += chunk));
      res.on('end', () => (res.statusCode === 200 ? resolve(body) : reject(new Error(`HTTP ${res.statusCode}`))));
    }).once('error', reject);
  });
}

await check('tls-extra-ca', async () => {
  // Both servers run on the host (10.0.2.2 from inside QEMU user networking). The first has a
  // certificate from the CA in NODE_EXTRA_CA_CERTS; the second from a CA nobody trusts.
  const trusted = required('TEST_TLS_TRUSTED');
  const untrusted = required('TEST_TLS_UNTRUSTED');
  const viaTls = await tlsHandshake(trusted);
  const viaHttps = await httpsGet(trusted);
  assert.equal(viaTls, 'hello from trusted');
  assert.equal(viaHttps.trim(), 'hello from trusted');
  const rejected = await tlsHandshake(untrusted).then(
    () => { throw new Error('connection to the untrusted server succeeded'); },
    (err: NodeJS.ErrnoException) => err.code);
  assert.equal(rejected, 'UNABLE_TO_VERIFY_LEAF_SIGNATURE');
  return { extraCa: required('NODE_EXTRA_CA_CERTS'), trusted: viaTls, untrustedRejectedWith: rejected };
});

// Not in the acceptance list, but the API resolves its RDS hostname the same way: getaddrinfo in
// the packaged glibc, reading the /etc/resolv.conf ops writes. Skipped when the host is offline.
if (env.TEST_DNS_NAME) {
  await check('dns-getaddrinfo', async () => {
    const result = await lookup(required('TEST_DNS_NAME'));
    return { name: env.TEST_DNS_NAME, address: result.address };
  });
}

emit({ name: 'guest-checks-done', ok: true, detail: null });
await serve(Number(required('HTTP_PORT')));
