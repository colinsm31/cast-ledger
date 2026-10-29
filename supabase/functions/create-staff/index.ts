// create-staff — the only way to add a staff account (AceStock, code review #1).
//
// Public sign-up is turned off, so accounts are created here instead:
//   1. The caller must be signed in and an admin. We ask the database
//      (is_admin()) using the caller's own session, so nothing in the request
//      body can claim admin rights.
//   2. The account is created with the service role (which never leaves the
//      server), already email-confirmed, and its profile is set to 'staff'.
//      It's marked as using a temporary password (user_metadata), so the web
//      app reminds the person to change it until they do.
//
// Request:  POST { "email": string, "password": string }
// Response: 201 { "id", "email" } | 4xx/5xx { "error": message }

import { createClient } from 'jsr:@supabase/supabase-js@2';

// Match the web app's lib/passwordRules.ts. Supabase Auth ignores anything
// past 72 characters, so longer is refused rather than silently cut.
const MIN_PASSWORD_LENGTH = 8;
const MAX_PASSWORD_LENGTH = 72;
const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!supabaseUrl || !anonKey || !serviceRoleKey) {
    return json({ error: 'Server is missing its Supabase configuration' }, 500);
  }

  // 1. Only admins may add staff — checked with the caller's own session.
  const authorization = req.headers.get('Authorization') ?? '';
  const callerClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: isAdmin, error: adminCheckError } = await callerClient.rpc('is_admin');
  if (adminCheckError || isAdmin !== true) {
    return json({ error: 'Only an admin can add staff accounts' }, 403);
  }

  // 2. Validate the request.
  let email = '';
  let password = '';
  try {
    const body = await req.json();
    email = String(body?.email ?? '').trim().toLowerCase();
    password = String(body?.password ?? '');
  } catch {
    return json({ error: 'Send JSON with an email and a password' }, 400);
  }
  if (!EMAIL_PATTERN.test(email)) {
    return json({ error: 'Enter a valid email address' }, 400);
  }
  if (password.length < MIN_PASSWORD_LENGTH) {
    return json({ error: `Use a password of at least ${MIN_PASSWORD_LENGTH} characters` }, 400);
  }
  if (password.length > MAX_PASSWORD_LENGTH) {
    return json({ error: `Use a password of at most ${MAX_PASSWORD_LENGTH} characters` }, 400);
  }

  // 3. Create the account and make it staff.
  const serviceClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: created, error: createError } = await serviceClient.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: { temporary_password: true },
  });
  if (createError || !created.user) {
    const alreadyExists =
      createError?.code === 'email_exists' || /already (been )?registered/i.test(createError?.message ?? '');
    return alreadyExists
      ? json({ error: 'An account with this email already exists' }, 409)
      : json({ error: createError?.message ?? 'Could not create the account' }, 400);
  }

  const { error: roleError } = await serviceClient
    .from('profiles')
    .update({ role: 'staff' })
    .eq('id', created.user.id);
  if (roleError) {
    // Don't leave a half-made account behind.
    await serviceClient.auth.admin.deleteUser(created.user.id);
    return json({ error: `Could not set the staff role: ${roleError.message}` }, 500);
  }

  return json({ id: created.user.id, email: created.user.email }, 201);
});
