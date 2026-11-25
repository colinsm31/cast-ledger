// deno test supabase/functions — no network, no database: fakes stand in for
// both.
import { assertEquals, assertRejects } from 'jsr:@std/assert@1.0.19';
import {
  type ClaimedMessage,
  type SendFilter,
  NO_TEXTING_MESSAGE,
  parseRequest,
  resendEmailSender,
  sendQueued,
  summarize,
  TEST_MODE_MESSAGE,
} from './sender.ts';

const JOB = '00000000-0000-0000-0000-000000000f05';

function message(changes: Partial<ClaimedMessage>): ClaimedMessage {
  return {
    id: 'n1',
    kind: 'job_ready',
    channel: 'email',
    to_address: 'sam@example.com',
    subject: 'Ready',
    body: 'Hi Sam',
    html: null,
    attempts: 1,
    resend_count: 0,
    ...changes,
  };
}

function fakeDeps(messages: ClaimedMessage[], sendEmail?: (m: ClaimedMessage) => Promise<string>) {
  const finished: unknown[][] = [];
  const claims: unknown[] = [];
  return {
    finished,
    claims,
    deps: {
      claim: (filter: SendFilter) => {
        claims.push(filter);
        return Promise.resolve(messages);
      },
      finish: (...args: unknown[]) => {
        finished.push(args);
        return Promise.resolve();
      },
      sendEmail,
    },
  };
}

const NONE: SendFilter = { stringJobId: null, saleId: null, notificationId: null };

Deno.test('parseRequest takes a message, a job, a sale, or none', () => {
  assertEquals(parseRequest({ notification_id: JOB }), { ...NONE, notificationId: JOB });
  assertEquals(parseRequest({ string_job_id: JOB }), { ...NONE, stringJobId: JOB });
  assertEquals(parseRequest({ sale_id: JOB }), { ...NONE, saleId: JOB });
  assertEquals(parseRequest(null), NONE);
  assertEquals(parseRequest({ notification_id: 'x' }), { error: 'notification_id must be an id' });
  assertEquals(parseRequest({ string_job_id: 'drop table' }), { error: 'string_job_id must be an id' });
  assertEquals(parseRequest({ sale_id: 42 }), { error: 'sale_id must be an id' });
});

Deno.test('emails are sent and texts skipped until texting is set up', async () => {
  const sent: ClaimedMessage[] = [];
  const { deps, finished, claims } = fakeDeps(
    [message({}), message({ id: 'n2', channel: 'sms', to_address: '+14155550123', subject: null })],
    (m) => {
      sent.push(m);
      return Promise.resolve('resend-1');
    },
  );
  const results = await sendQueued({ ...NONE, stringJobId: JOB }, deps);
  assertEquals(claims, [{ ...NONE, stringJobId: JOB }]);
  assertEquals(sent.map((m) => m.id), ['n1']);
  assertEquals(finished, [
    ['n1', 'sent', 'resend-1', null],
    ['n2', 'skipped', null, NO_TEXTING_MESSAGE],
  ]);
  assertEquals(summarize(results), { sent: 1, failed: 0, skipped: 1 });
});

Deno.test('test mode: without the email secrets nothing leaves', async () => {
  const { deps, finished } = fakeDeps([message({})]);
  const results = await sendQueued(NONE, deps);
  assertEquals(results, [{ id: 'n1', status: 'skipped', error: TEST_MODE_MESSAGE }]);
  assertEquals(finished, [['n1', 'skipped', null, TEST_MODE_MESSAGE]]);
});

Deno.test('a refused email is recorded as failed and the rest still go', async () => {
  const { deps, finished } = fakeDeps([message({}), message({ id: 'n2' })], (m) =>
    m.id === 'n1' ? Promise.reject(new Error('Invalid to address')) : Promise.resolve('resend-2'),
  );
  const results = await sendQueued(NONE, deps);
  assertEquals(summarize(results), { sent: 1, failed: 1, skipped: 0 });
  assertEquals(finished[0], ['n1', 'failed', null, 'Invalid to address']);
});

function fakeFetch(status: number, body: unknown, seen: { url?: string; init?: RequestInit }) {
  return ((url: string, init?: RequestInit) => {
    seen.url = url;
    seen.init = init;
    return Promise.resolve(new Response(JSON.stringify(body), { status }));
  }) as unknown as typeof fetch;
}

Deno.test('Resend gets the message, the sender and a key that only Send again changes', async () => {
  const seen: { url?: string; init?: RequestInit } = {};
  const send = resendEmailSender({
    apiKey: 'test-key',
    from: 'Ace Racquets <service@ace.example>',
    replyTo: 'shop@ace.example',
    fetch: fakeFetch(200, { id: 'resend-9' }, seen),
  });
  assertEquals(await send(message({ html: '<p>Receipt</p>', attempts: 2, resend_count: 1 })), 'resend-9');
  assertEquals(seen.url, 'https://api.resend.com/emails');
  const headers = seen.init?.headers as Record<string, string>;
  assertEquals(headers.Authorization, 'Bearer test-key');
  assertEquals(headers['Idempotency-Key'], 'acestock-n1-r1');
  assertEquals(JSON.parse(String(seen.init?.body)), {
    from: 'Ace Racquets <service@ace.example>',
    to: ['sam@example.com'],
    subject: 'Ready',
    text: 'Hi Sam',
    html: '<p>Receipt</p>',
    reply_to: 'shop@ace.example',
  });
  // Taken again after a lost "sent" record: the same key, so it isn't delivered twice.
  await send(message({ attempts: 3, resend_count: 1 }));
  assertEquals((seen.init?.headers as Record<string, string>)['Idempotency-Key'], 'acestock-n1-r1');
});

Deno.test('Resend refusing or not answering is a readable error', async () => {
  const refused = resendEmailSender({
    apiKey: 'k',
    from: 'f@ace.example',
    fetch: fakeFetch(422, { message: 'Invalid `to` field' }, {}),
  });
  await assertRejects(() => refused(message({})), Error, 'The email service refused it (422): Invalid `to` field');

  const down = resendEmailSender({
    apiKey: 'k',
    from: 'f@ace.example',
    fetch: (() => Promise.reject(new Error('connection reset'))) as unknown as typeof fetch,
  });
  await assertRejects(() => down(message({})), Error, "The email service didn't answer: connection reset");

  const noId = resendEmailSender({ apiKey: 'k', from: 'f@ace.example', fetch: fakeFetch(200, {}, {}) });
  await assertRejects(() => noId(message({})), Error, 'no reason given');
});
