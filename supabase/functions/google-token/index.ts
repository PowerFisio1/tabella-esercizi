// Edge Function Supabase: gestisce lo scambio/rinnovo del token OAuth di Google
// Calendar lato server, in modo da poter ottenere e usare un refresh_token (cosa
// impossibile da fare in sicurezza nel browser, perché richiede il Client Secret).
// Va incollata nel pannello Supabase -> Edge Functions (creazione ed editor
// direttamente dal browser, nessun CLI necessario). "Verify JWT" per questa
// funzione deve restare ATTIVO (default): il chiamante deve essere un utente
// autenticato Supabase, il suo id utente viene usato per salvare/leggere il
// refresh_token nella tabella google_oauth_tokens (RLS: nessun accesso diretto
// dal client, solo questa funzione con la service role key può leggerla/scriverla).
//
// Secret da impostare nel pannello Edge Functions (Settings -> Secrets), oltre a
// SUPABASE_URL/SUPABASE_SERVICE_ROLE_KEY che Supabase inietta già automaticamente:
//   GOOGLE_CLIENT_SECRET (Google Cloud Console -> APIs & Services -> Credentials
//   -> il client OAuth già usato dall'app -> "Client secret")
//
// Richiesta dal client: POST con body JSON { action: 'exchange'|'refresh'|'disconnect', code?: string }
// e header Authorization: Bearer <access_token della sessione Supabase dell'utente>.

import { createClient } from "npm:@supabase/supabase-js@2";

const GOOGLE_CLIENT_ID = "713281846725-v39g4p2aujtkfku3mrd2lp606c5fgo9f.apps.googleusercontent.com";
const GOOGLE_CLIENT_SECRET = Deno.env.get("GOOGLE_CLIENT_SECRET")!;

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
);

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

async function googleTokenRequest(params: Record<string, string>) {
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(params),
  });
  const data = await res.json();
  return { ok: res.ok, data };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const authHeader = req.headers.get("Authorization") || "";
    const jwt = authHeader.replace("Bearer ", "");
    const { data: { user }, error: userErr } = await supabase.auth.getUser(jwt);
    if (userErr || !user) return json({ error: "unauthorized" }, 401);

    const body = await req.json().catch(() => ({}));

    if (body.action === "exchange") {
      if (!body.code) return json({ error: "missing_code" }, 400);
      const { ok, data } = await googleTokenRequest({
        code: body.code,
        client_id: GOOGLE_CLIENT_ID,
        client_secret: GOOGLE_CLIENT_SECRET,
        redirect_uri: "postmessage", // convenzione richiesta da initCodeClient con ux_mode:'popup'
        grant_type: "authorization_code",
      });
      if (!ok || !data.refresh_token) {
        // niente refresh_token: succede se l'utente aveva già autorizzato senza
        // "prompt:consent" — lato client va sempre passato prompt:'consent' per evitarlo
        return json({ error: data.error || "exchange_failed" }, 400);
      }
      const { error: dbErr } = await supabase.from("google_oauth_tokens").upsert({
        user_id: user.id,
        refresh_token: data.refresh_token,
        updated_at: new Date().toISOString(),
      });
      if (dbErr) return json({ error: "db_error" }, 500);
      return json({ access_token: data.access_token, expires_in: data.expires_in });
    }

    if (body.action === "refresh") {
      const { data: row } = await supabase
        .from("google_oauth_tokens")
        .select("refresh_token")
        .eq("user_id", user.id)
        .maybeSingle();
      if (!row) return json({ error: "not_connected" }, 400);
      const { ok, data } = await googleTokenRequest({
        refresh_token: row.refresh_token,
        client_id: GOOGLE_CLIENT_ID,
        client_secret: GOOGLE_CLIENT_SECRET,
        grant_type: "refresh_token",
      });
      if (!ok) {
        // refresh_token non più valido (revocato dall'utente lato Google, o scaduto):
        // va rimosso, l'utente dovrà ricollegarsi con un consenso vero e proprio
        if (data.error === "invalid_grant") {
          await supabase.from("google_oauth_tokens").delete().eq("user_id", user.id);
        }
        return json({ error: data.error || "refresh_failed" }, 400);
      }
      return json({ access_token: data.access_token, expires_in: data.expires_in });
    }

    if (body.action === "disconnect") {
      await supabase.from("google_oauth_tokens").delete().eq("user_id", user.id);
      return json({ ok: true });
    }

    return json({ error: "unknown_action" }, 400);
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
