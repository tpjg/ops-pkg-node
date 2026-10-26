// The HTTP and WebSocket endpoints the host driver calls through ops' port forward.
import Fastify from 'fastify';
import websocket from '@fastify/websocket';
import { emit } from './report.ts';

export async function serve(port: number): Promise<void> {
  const app = Fastify({ logger: false });
  await app.register(websocket);

  app.get('/health', async () => ({ status: 'ok', version: process.version, arch: process.arch }));

  app.get('/ws', { websocket: true }, (socket) => {
    socket.on('message', (data: Buffer) => socket.send(`echo:${data.toString()}`));
  });

  // The driver ends the run with an ACPI power-button press (QMP system_powerdown). Nanos turns
  // that into SIGTERM; reporting it here shows what Node sees when the VM is asked to shut down.
  process.once('SIGTERM', () => {
    emit({ name: 'sigterm-on-powerdown', ok: true, detail: 'SIGTERM received' });
    app.close().then(() => process.exit(0));
  });

  // Fallback exit when the driver could not send a power-button press.
  app.post('/shutdown', async (_req, reply) => {
    reply.send({ bye: true });
    setImmediate(() => app.close().then(() => process.exit(0)));
  });

  await app.listen({ host: '0.0.0.0', port });
  process.stdout.write(`READY ${port}\n`);
}
