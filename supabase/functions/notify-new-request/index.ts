// Edge Function Supabase: invia una notifica push a tutti i dispositivi
// registrati in push_subscriptions, non appena arriva una nuova riga in
// booking_requests. Va incollata nel pannello Supabase -> Edge Functions
// (creazione ed editor direttamente dal browser, nessun CLI necessario),
// e collegata con un Database Webhook su booking_requests (evento INSERT).
//
// Secrets da impostare nel pannello Edge Functions (Settings -> Secrets),
// oltre a SUPABASE_URL/SUPABASE_SERVICE_ROLE_KEY che Supabase inietta già
// automaticamente in ogni funzione:
//   VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT (es. mailto:gonta.kam@gmail.com)

import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2";

const VAPID_PUBLIC_KEY = Deno.env.get("VAPID_PUBLIC_KEY")!;
const VAPID_PRIVATE_KEY = Deno.env.get("VAPID_PRIVATE_KEY")!;
const VAPID_SUBJECT = Deno.env.get("VAPID_SUBJECT") || "mailto:gonta.kam@gmail.com";

webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY);

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
);

Deno.serve(async (req) => {
  try {
    const payload = await req.json();
    const record = payload.record || payload.new || {};

    const { data: subs, error } = await supabase.from("push_subscriptions").select("*");
    if (error) throw error;

    const when = record.preferred_at
      ? new Date(record.preferred_at).toLocaleString("it-IT", { dateStyle: "medium", timeStyle: "short" })
      : "";
    const body = [record.full_name, when].filter(Boolean).join(" — ");

    const notifPayload = JSON.stringify({
      title: "Nuova richiesta di prenotazione",
      body: body || "Hai una nuova richiesta in attesa.",
      url: "./calendario.html"
    });

    await Promise.allSettled(
      (subs || []).map((s) =>
        webpush
          .sendNotification(
            { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth_key } },
            notifPayload
          )
          .catch(async (err: any) => {
            // subscription scaduta/revocata sul dispositivo: la rimuove
            if (err.statusCode === 404 || err.statusCode === 410) {
              await supabase.from("push_subscriptions").delete().eq("id", s.id);
            }
          })
      )
    );

    return new Response(JSON.stringify({ ok: true, sent: (subs || []).length }), {
      headers: { "Content-Type": "application/json" }
    });
  } catch (e) {
    return new Response(JSON.stringify({ ok: false, error: String(e) }), {
      status: 500,
      headers: { "Content-Type": "application/json" }
    });
  }
});
