// deno test supabase/functions — the request handling, every path, with a fake
// Supabase client (no network, no database).
import { assertEquals } from 'jsr:@std/assert@1.0.19';
import { CLAIM_FAILED_MESSAGE, createHandler, type HandlerDeps, type RpcClient } from './handler.ts';
import { TEST_MODE_MESSAGE } from './sender.ts';

const JOB = '00000000-0000-0000-0000-000000000f05';
const CONFIG: Record<string, string> = {
  SUPABASE_URL: 'http://db.test',
  SUPABASE_ANON_KEY: 'anon',
  SUPABASE_SERVICE_ROLE_KEY: 'service',
};

type Rpc = (fn: string, args?: Record<string, unknown>) => { data: unknown; error: { message: string } | null };

function setup(options: { env?: Record<string, string>; caller?: Rpc; service?: Rpc } = {}) {
  const calls: { client: string; fn: string; args?: Record<string, unknown> }[] = [];
  const logged: string[] = [];
  const client = (name: string, rpc: Rpc): RpcClient => ({
    rpc: (fn, args) => {
      calls.push({ client: name, fn, args });
      return Promise.resolve(rpc(fn, args));
    },
  });
  const deps: HandlerDeps = {
    env: (name) => (options.env ?? CONFIG)[name],
    makeClient: (_url, key, authorization) =>
      authorization !== undefined
        ? client(`caller(${key}, ${authorization})`, options.caller ?? (() => ({ data: true, error: null })))
        : client(`service(${key})`, options.service ?? (() => ({ data: [], error: null }))),
    logError: (message) => logged.push(message),
  };
  return { handle: createHandler(deps), calls, logged };
}

function post(body: unknown, init: RequestInit = {}): Request {
  return new Request('http://fn.test/send-notifications', {
    method: 'POST',
    headers: { Authorization: 'Bearer staff-token' },
    body: JSON.stringify(body),
    ...init,
  });
}

Deno.test('the browser check and anything but POST', async () => {
  const { handle } = setup();
  assertEquals((await handle(new Request('http://fn.test', { method: 'OPTIONS' }))).status, 200);
  const get = await handle(new Request('http://fn.test', { method: 'GET' }));
  assertEquals([get.status, await get.json()], [405, { error: 'Method not allowed' }]);
});

Deno.test('a server without its configuration says so', async () => {
  const { handle } = setup({ env: {} });
  const response = await handle(post({}));
  assertEquals([response.status, await response.json()], [500, { error: 'Server is missing its Supabase configuration' }]);
});

Deno.test('only staff, checked with their own session', async () => {
  const notStaff = setup({ caller: () => ({ data: false, error: null }) });
  const refused = await notStaff.handle(post({}));
  assertEquals([refused.status, await refused.json()], [403, { error: 'Only staff can send customer messages' }]);
  assertEquals(notStaff.calls, [{ client: 'caller(anon, Bearer staff-token)', fn: 'is_staff', args: undefined }]);

  const broken = setup({ caller: () => ({ data: null, error: { message: 'JWT expired' } }) });
  assertEquals((await broken.handle(post({}))).status, 403);
  assertEquals(broken.logged, ['is_staff: JWT expired']);
});

Deno.test('a bad id is refused before anything is claimed', async () => {
  const { handle, calls } = setup();
  const response = await handle(post({ notification_id: 'nope' }));
  assertEquals([response.status, await response.json()], [400, { error: 'notification_id must be an id' }]);
  assertEquals(calls.map((c) => c.fn), ['is_staff']);
});

Deno.test('Send again claims just its message; test mode records it as not sent', async () => {
  const { handle, calls } = setup({
    service: (fn) =>
      fn === 'claim_notifications'
        ? {
          data: [{ id: 'n1', kind: 'job_ready', channel: 'email', to_address: 'a@b.co', subject: 'Ready', body: 'Hi',
                   html: null, attempts: 1, resend_count: 0 }],
          error: null,
        }
        : { data: null, error: null },
  });
  const response = await handle(post({ notification_id: JOB }));
  assertEquals(response.status, 200);
  assertEquals(await response.json(), {
    sent: 0, failed: 0, skipped: 1, results: [{ id: 'n1', status: 'skipped', error: TEST_MODE_MESSAGE }],
  });
  assertEquals(calls.slice(1), [
    { client: 'service(service)', fn: 'claim_notifications', args: { p_string_job_id: null, p_sale_id: null, p_id: JOB } },
    { client: 'service(service)', fn: 'finish_notification',
      args: { p_id: 'n1', p_status: 'skipped', p_provider_id: null, p_error: TEST_MODE_MESSAGE } },
  ]);
});

Deno.test('a database error is logged, and staff get a plain message', async () => {
  const { handle, logged } = setup({
    service: () => ({ data: null, error: { message: 'permission denied for function claim_notifications' } }),
  });
  const response = await handle(post({ string_job_id: JOB }));
  assertEquals([response.status, await response.json()], [500, { error: CLAIM_FAILED_MESSAGE }]);
  assertEquals(logged, ['claim_notifications: permission denied for function claim_notifications']);
});

Deno.test('a result that can\'t be recorded is logged, and the rest still go', async () => {
  const { handle, logged } = setup({
    service: (fn) =>
      fn === 'claim_notifications'
        ? { data: [{ id: 'n1', kind: 'receipt', channel: 'sms', to_address: '+1', subject: null, body: 'x', html: null,
                     attempts: 1, resend_count: 0 }], error: null }
        : { data: null, error: { message: 'connection lost' } },
  });
  const response = await handle(post({}));
  assertEquals(response.status, 200);
  assertEquals(logged, ['finish_notification n1: connection lost']);
});

Deno.test('a body that isn\'t JSON sends the oldest waiting', async () => {
  const { handle, calls } = setup();
  const response = await handle(post(undefined, { body: 'not json' }));
  assertEquals(response.status, 200);
  assertEquals(calls[1].args, { p_string_job_id: null, p_sale_id: null, p_id: null });
});
