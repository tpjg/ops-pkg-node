// Host side of the acceptance tests: boots the package with `ops pkg load`, serves the TLS
// endpoints the guest calls, calls the guest's HTTP/WebSocket server through the port forward,
// presses the ACPI power button over QMP, and checks every RESULT line.
//
//   node test/driver.mjs --arch x64|arm64 --pkg node_<version> --node-version <version> \
//     --nanos-version <version> --work <dir>
//
// scripts/acceptance.sh runs it in the test container, with the pinned ops on PATH and OPS_HOME set.
import { execFileSync, spawn } from 'node:child_process';
import { lookup } from 'node:dns/promises';
import { cpSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import tls from 'node:tls';
import { parseArgs } from 'node:util';

const { values: opts } = parseArgs({
  options: {
    arch: { type: 'string' },
    pkg: { type: 'string' },
    'node-version': { type: 'string' },
    'nanos-version': { type: 'string' },
    work: { type: 'string' },
    timeout: { type: 'string', default: '600' },
  },
});
const arch = opts.arch;
if (!['x64', 'arm64'].includes(arch)) throw new Error('--arch must be x64 or arm64');
const opsArch = arch === 'x64' ? 'amd64' : 'arm64';
const work = path.resolve(opts.work);
const guestSrc = path.join(import.meta.dirname, 'guest');
const timeoutMs = Number(opts.timeout) * 1000;

// QEMU user networking: the guest reaches the host's loopback at 10.0.2.2.
const HOST_FROM_GUEST = '10.0.2.2';
const SMP = 2;

const hostArch = os.arch();
const kvm = process.platform === 'linux' && hostArch === arch && canWrite('/dev/kvm');
const accel = kvm ? 'kvm' : 'tcg';

function canWrite(file) {
  try { execFileSync('test', ['-w', file]); return true; } catch { return false; }
}

function log(msg) { process.stderr.write(`[driver] ${msg}\n`); }

// --- guest app: sources plus node_modules for the target platform -------------------------
rmSync(work, { recursive: true, force: true });
const app = path.join(work, 'app');
mkdirSync(app, { recursive: true });
cpSync(guestSrc, app, { recursive: true, filter: (src) => !src.includes('node_modules') });
log(`npm ci for linux-${arch}-glibc`);
execFileSync('npm', ['ci', '--omit=dev', '--ignore-scripts', '--no-bin-links', '--no-audit', '--no-fund',
  '--os=linux', `--cpu=${arch}`, '--libc=glibc'], { cwd: app, stdio: ['ignore', 'ignore', 'inherit'] });

// --- certificates: a trusted CA (given to the guest) and an untrusted one ------------------
// Keys stay in host-certs/; only the trusted CA certificate goes into the image.
const hostCerts = path.join(work, 'host-certs');
mkdirSync(hostCerts);
const openssl = (...args) => execFileSync('openssl', args, { cwd: hostCerts, stdio: ['ignore', 'ignore', 'pipe'] });
for (const name of ['trusted', 'untrusted']) {
  openssl('req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256', '-nodes', '-days', '2',
    '-subj', `/CN=${name} test CA`, '-keyout', `${name}-ca.key`, '-out', `${name}-ca.pem`,
    '-addext', 'basicConstraints=critical,CA:TRUE', '-addext', 'keyUsage=critical,keyCertSign');
  openssl('req', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256', '-nodes',
    '-subj', `/CN=${HOST_FROM_GUEST}`, '-keyout', `${name}.key`, '-out', `${name}.csr`);
  writeFileSync(path.join(hostCerts, `${name}.ext`), `subjectAltName=IP:${HOST_FROM_GUEST}\nextendedKeyUsage=serverAuth\n`);
  openssl('x509', '-req', '-in', `${name}.csr`, '-CA', `${name}-ca.pem`, '-CAkey', `${name}-ca.key`,
    '-CAcreateserial', '-days', '1', '-extfile', `${name}.ext`, '-out', `${name}.pem`);
}
mkdirSync(path.join(app, 'certs'));
cpSync(path.join(hostCerts, 'trusted-ca.pem'), path.join(app, 'certs', 'ca.pem'));

function tlsServer(name) {
  return new Promise((resolve) => {
    const server = tls.createServer({
      key: readFileSync(path.join(hostCerts, `${name}.key`)),
      cert: readFileSync(path.join(hostCerts, `${name}.pem`)),
    }, (socket) => {
      // Answers the guest's raw TLS line and its HTTPS GET with the same body.
      socket.once('data', (data) => {
        const body = `hello from ${name}\n`;
        if (data.toString().startsWith('GET ')) {
          socket.end(`HTTP/1.1 200 OK\r\ncontent-length: ${body.length}\r\nconnection: close\r\n\r\n${body}`);
        } else socket.end(body);
      });
      socket.on('error', () => {});
    });
    server.on('tlsClientError', () => {});
    server.listen(0, '127.0.0.1', () => resolve(server));
  });
}
const trustedServer = await tlsServer('trusted');
const untrustedServer = await tlsServer('untrusted');

// --- ops config -------------------------------------------------------------------------
const httpPort = await freePort();
const envProbe = `probe-${process.pid}-${Date.now()}`;
const envSpecial = 'postgres://api:p%40ss w=rd@db.internal:5432/app?sslmode=verify-full&x=ü';
let dnsName;
try { await lookup('nodejs.org'); dnsName = 'nodejs.org'; } catch { log('host cannot resolve nodejs.org; skipping the DNS check'); }

const config = {
  Args: ['/app/main.ts'],
  DisableArgsCopy: true,
  Dirs: ['app'],
  Env: {
    EXPECT_NODE_VERSION: opts['node-version'],
    EXPECT_ARCH: arch,
    HTTP_PORT: String(httpPort),
    NODE_EXTRA_CA_CERTS: '/app/certs/ca.pem',
    TEST_ENV_PROBE: envProbe,
    TEST_ENV_SPECIAL: envSpecial,
    TEST_TLS_TRUSTED: `https://${HOST_FROM_GUEST}:${trustedServer.address().port}/`,
    TEST_TLS_UNTRUSTED: `https://${HOST_FROM_GUEST}:${untrustedServer.address().port}/`,
    ...(dnsName ? { TEST_DNS_NAME: dnsName } : {}),
  },
  RunConfig: { Ports: [String(httpPort)], CPUs: SMP, Memory: '1G', QMP: true },
};
writeFileSync(path.join(work, 'config.json'), JSON.stringify(config, null, 2));

function freePort() {
  return new Promise((resolve) => {
    const s = net.createServer().listen(0, '127.0.0.1', () => { const { port } = s.address(); s.close(() => resolve(port)); });
  });
}

// --- boot ---------------------------------------------------------------------------------
const results = new Map();
const opsArgs = ['pkg', 'load', opts.pkg, '--local', '--arch', opsArch, '-c', 'config.json',
  '--smp', String(SMP), ...(opts['nanos-version'] ? ['--nanos-version', opts['nanos-version']] : [])];
log(`accel=${accel} smp=${SMP}: ops ${opsArgs.join(' ')}`);
const started = Date.now();
const ops = spawn('ops', opsArgs, { cwd: work, stdio: ['ignore', 'pipe', 'inherit'] });
const exited = new Promise((resolve) => ops.on('exit', (code, signal) => resolve({ code, signal })));
const ready = new Promise((resolve) => {
  let buf = '';
  // Decode as a stream: a multi-byte character can straddle two chunks.
  ops.stdout.setEncoding('utf8');
  ops.stdout.on('data', (chunk) => {
    process.stdout.write(chunk);
    buf += chunk;
    let i;
    while ((i = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, i).replace(/\r$/, '');
      buf = buf.slice(i + 1);
      const m = line.match(/RESULT (\{.*\})$/);
      if (m) { const r = JSON.parse(m[1]); results.set(r.name, r); }
      if (/READY \d+$/.test(line)) resolve(true);
    }
  });
  exited.then(() => resolve(false));
});
const timer = setTimeout(() => { log(`timeout after ${timeoutMs / 1000}s`); killQemu(); ops.kill('SIGKILL'); }, timeoutMs);

function record(name, ok, detail) { results.set(name, { name, ok, detail, host: true }); }

async function hostCheck(name, fn) {
  try { record(name, true, await fn()); } catch (err) { record(name, false, String(err?.stack ?? err)); }
}

function qemuPid() {
  try {
    return execFileSync('pgrep', ['-P', String(ops.pid)]).toString().trim().split('\n')[0] || null;
  } catch { return null; }
}

function killQemu() {
  const pid = qemuPid();
  if (pid) try { process.kill(Number(pid), 'SIGKILL'); } catch {}
}

function qmp(port, command) {
  return new Promise((resolve, reject) => {
    const sock = net.connect(port, '127.0.0.1');
    let buf = '';
    let step = 0;
    sock.on('data', (d) => {
      buf += d;
      const lines = buf.split('\n'); buf = lines.pop();
      for (const line of lines) {
        if (!line.trim()) continue;
        const msg = JSON.parse(line);
        if (step === 0 && msg.QMP) { sock.write('{"execute":"qmp_capabilities"}\n'); step = 1; }
        else if (step === 1 && 'return' in msg) { sock.write(JSON.stringify({ execute: command }) + '\n'); step = 2; }
        else if (step === 2 && ('return' in msg || 'error' in msg)) { sock.end(); 'error' in msg ? reject(new Error(JSON.stringify(msg.error))) : resolve(); }
      }
    });
    sock.on('error', reject);
  });
}

if (await ready) {
  log(`guest ready after ${((Date.now() - started) / 1000).toFixed(1)}s`);
  const base = `http://127.0.0.1:${httpPort}`;
  await hostCheck('http', async () => {
    const res = await fetch(`${base}/health`);
    const body = await res.json();
    if (res.status !== 200 || body.status !== 'ok' || body.arch !== arch) throw new Error(`unexpected ${res.status} ${JSON.stringify(body)}`);
    return body;
  });
  await hostCheck('websocket', () => new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://127.0.0.1:${httpPort}/ws`);
    const t = setTimeout(() => reject(new Error('websocket timeout')), 15000);
    ws.onopen = () => ws.send('ping');
    ws.onmessage = (ev) => { clearTimeout(t); ws.close(); ev.data === 'echo:ping' ? resolve(ev.data) : reject(new Error(`got ${ev.data}`)); };
    ws.onerror = (ev) => { clearTimeout(t); reject(new Error(ev.message ?? 'websocket error')); };
  }));

  // Shutdown: press the ACPI power button, as EC2 does on stop/terminate.
  const qemuArgs = (() => { const pid = qemuPid(); return pid ? execFileSync('ps', ['-o', 'args=', '-p', pid]).toString() : ''; })();
  const qmpPort = qemuArgs.match(/-qmp tcp:localhost:(\d+)/)?.[1];
  let pressed = false;
  if (qmpPort) {
    try { await qmp(Number(qmpPort), 'system_powerdown'); pressed = true; log('sent QMP system_powerdown'); }
    catch (err) { log(`QMP failed: ${err}`); }
  } else log('no QMP port found on the qemu command line');
  const powerdownExit = await Promise.race([exited, new Promise((r) => setTimeout(() => r(null), 45000))]);
  if (!powerdownExit) {
    log('VM still running 45s after the power-button press; using POST /shutdown');
    await fetch(`${base}/shutdown`, { method: 'POST' }).catch(() => {});
  }
  if (!pressed || !results.has('sigterm-on-powerdown')) {
    record('sigterm-on-powerdown', false, pressed ? 'no SIGTERM reached Node after system_powerdown' : 'power button not pressed');
  }
}

const { code, signal } = await exited;
clearTimeout(timer);
trustedServer.close();
untrustedServer.close();

// --- verdict ------------------------------------------------------------------------------
const expected = ['argon2', 'version-and-arch', 'typescript', 'intl', 'threadpool', 'env', 'tls-extra-ca',
  ...(dnsName ? ['dns-getaddrinfo'] : []), 'guest-checks-done', 'http', 'websocket', 'sigterm-on-powerdown'];
const envResult = results.get('env');
if (envResult?.ok) {
  const d = envResult.detail;
  if (d.TEST_ENV_PROBE !== envProbe || d.TEST_ENV_SPECIAL !== envSpecial) {
    results.set('env', { ...envResult, ok: false, detail: { expected: { envProbe, envSpecial }, got: d } });
  }
}
let failed = 0;
const summary = [];
for (const name of expected) {
  const r = results.get(name) ?? { name, ok: false, detail: 'no result (guest crashed or timed out)' };
  if (!r.ok) failed++;
  summary.push(r);
  log(`${r.ok ? 'PASS' : 'FAIL'} ${name}: ${typeof r.detail === 'string' ? r.detail : JSON.stringify(r.detail)}`);
}
log(`ops exited code=${code} signal=${signal}; accel=${accel}; ${failed} failed of ${expected.length}`);
writeFileSync(path.join(work, 'results.json'), JSON.stringify({ arch, accel, smp: SMP, ops: { code, signal }, results: summary }, null, 2));
process.exit(failed ? 1 : 0);
