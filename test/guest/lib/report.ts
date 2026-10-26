// Result protocol between this guest program and test/driver.mjs on the host: one line per
// check on stdout, `RESULT {"name":…,"ok":…,"detail":…}`.

export interface Result {
  name: string;
  ok: boolean;
  detail: unknown;
}

export function emit(result: Result): void {
  process.stdout.write(`RESULT ${JSON.stringify(result)}\n`);
}

export async function check<T>(name: string, fn: () => T | Promise<T>): Promise<boolean> {
  try {
    emit({ name, ok: true, detail: await fn() });
    return true;
  } catch (err) {
    emit({ name, ok: false, detail: describe(err) });
    return false;
  }
}

// An error's stack plus its causes; native-addon loaders (napi-rs) put the dlopen errors there.
function describe(err: unknown): string {
  if (Array.isArray(err)) return err.map(describe).join('\n');
  if (!(err instanceof Error)) return String(err);
  const cause = err.cause === undefined ? '' : `\ncaused by: ${describe(err.cause)}`;
  return `${err.stack ?? err.message}${cause}`;
}
