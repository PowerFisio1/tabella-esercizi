-- ============================================================================
-- Schema Supabase per il Calendario (appuntamenti + tipologie di lavoro).
-- Da eseguire UNA VOLTA nel SQL editor di Supabase (progetto già usato per
-- exercise_library_sync). Non tocca le tabelle esistenti.
-- ============================================================================

-- ---- Tabella appuntamenti: una riga per appuntamento (non un blob unico,
--      a differenza di exercise_library_sync, perché con una riga per utente
--      due dispositivi che modificano appuntamenti diversi non entrerebbero
--      mai in conflitto tra loro) ----
create table if not exists appointments (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  patient_name text not null,
  start_at timestamptz not null,
  duration_min integer not null default 30,
  work_type_id text,
  notes text,
  updated_at timestamptz not null default now()
);

create index if not exists appointments_user_start_idx on appointments (user_id, start_at);

alter table appointments enable row level security;

create policy "appointments_select_own" on appointments
  for select using (auth.uid() = user_id);
create policy "appointments_insert_own" on appointments
  for insert with check (auth.uid() = user_id);
create policy "appointments_update_own" on appointments
  for update using (auth.uid() = user_id);
create policy "appointments_delete_own" on appointments
  for delete using (auth.uid() = user_id);

-- ---- Tipologie di lavoro: piccola lista configurabile, una riga per utente
--      (stesso pattern "blob" già usato per la libreria esercizi, adatto qui
--      perché la lista è corta e cambia raramente) ----
create table if not exists calendar_settings (
  user_id uuid primary key references auth.users(id) on delete cascade,
  work_types jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now()
);

alter table calendar_settings enable row level security;

create policy "calendar_settings_select_own" on calendar_settings
  for select using (auth.uid() = user_id);
create policy "calendar_settings_insert_own" on calendar_settings
  for insert with check (auth.uid() = user_id);
create policy "calendar_settings_update_own" on calendar_settings
  for update using (auth.uid() = user_id);

-- ---- Realtime: necessario perché un secondo dispositivo veda gli
--      appuntamenti/le tipologie in diretta senza dover ricaricare la pagina.
--      Se questo comando desse errore ("already member of publication" o
--      simile), è già attivo: si può anche attivare a mano da Supabase ->
--      Database -> Replication -> spunta "appointments" e "calendar_settings". ----
alter publication supabase_realtime add table appointments;
alter publication supabase_realtime add table calendar_settings;

-- ============================================================================
-- Aggiunta successiva: sincronizzazione one-way verso Google Calendar.
-- Da eseguire una volta, in aggiunta a quanto sopra (se lo schema sopra è
-- già stato eseguito in precedenza, basta eseguire solo questa riga).
-- ============================================================================
alter table appointments add column if not exists google_event_id text;

-- ============================================================================
-- Aggiunta successiva: richieste di prenotazione dal sito pubblico
-- (sito-kamil-fisioterapista/prenota.html). Chiunque può inserire una
-- richiesta (form pubblico, nessun login), ma solo l'account autenticato
-- (Kamil) può leggerle/aggiornarle dal pannello Calendario. Tutto idempotente:
-- sicuro da rieseguire anche se già presente.
-- ============================================================================
create table if not exists booking_requests (
  id uuid primary key default gen_random_uuid(),
  full_name text not null,
  phone text not null,
  email text,
  preferred_at timestamptz not null,
  reason text,
  status text not null default 'pending', -- pending | confirmed | declined
  appointment_id uuid references appointments(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table booking_requests enable row level security;

create policy "booking_requests_insert_public" on booking_requests
  for insert to anon with check (true);
create policy "booking_requests_admin_select" on booking_requests
  for select using (auth.role() = 'authenticated');
create policy "booking_requests_admin_update" on booking_requests
  for update using (auth.role() = 'authenticated');

alter publication supabase_realtime add table booking_requests;

-- ============================================================================
-- Aggiunta successiva: notifiche push native (una riga per dispositivo
-- iscritto). Solo l'account autenticato può leggere/scrivere le proprie.
-- ============================================================================
create table if not exists push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth_key text not null,
  created_at timestamptz not null default now()
);

alter table push_subscriptions enable row level security;

create policy "push_subscriptions_own_select" on push_subscriptions
  for select using (auth.uid() = user_id);
create policy "push_subscriptions_own_insert" on push_subscriptions
  for insert with check (auth.uid() = user_id);
create policy "push_subscriptions_own_delete" on push_subscriptions
  for delete using (auth.uid() = user_id);

-- ============================================================================
-- Aggiunta successiva: picker giorno/orario sul sito pubblico (slot reali,
-- non più data/ora libere). Il sito pubblico non può leggere Supabase con le
-- stesse tabelle usate dall'app privata (patient_name, notes, ecc. non vanno
-- esposti a chiunque): per questo espone solo due "viste" pubbliche di sola
-- lettura, con dentro solo orari, mai dati dei pazienti.
-- ============================================================================

-- Finestra settimanale "prenotabile" e cache degli impegni Google (letta e
-- aggiornata dall'app ogni volta che apri il Calendario con Google collegato)
alter table calendar_settings add column if not exists booking_window jsonb not null default '{}'::jsonb;

create table if not exists google_busy_cache (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  google_event_id text not null,
  start_at timestamptz not null,
  end_at timestamptz not null,
  unique (google_event_id)
);

alter table google_busy_cache enable row level security;

create policy "google_busy_cache_own_select" on google_busy_cache
  for select using (auth.uid() = user_id);
create policy "google_busy_cache_own_insert" on google_busy_cache
  for insert with check (auth.uid() = user_id);
create policy "google_busy_cache_own_update" on google_busy_cache
  for update using (auth.uid() = user_id);
create policy "google_busy_cache_own_delete" on google_busy_cache
  for delete using (auth.uid() = user_id);

-- Vista pubblica: solo gli orari occupati (appuntamenti + richieste in attesa,
-- durata di default 45 min + impegni Google in cache), niente nomi pazienti.
create or replace view public.busy_slots as
  select start_at, start_at + make_interval(mins => duration_min) as end_at
  from appointments
  union all
  select preferred_at as start_at, preferred_at + interval '45 minutes' as end_at
  from booking_requests where status = 'pending'
  union all
  select start_at, end_at from google_busy_cache;

grant select on public.busy_slots to anon;

-- Vista pubblica: solo la finestra settimanale (nessun altro campo di calendar_settings)
create or replace view public.booking_window_public as
  select booking_window from calendar_settings limit 1;

grant select on public.booking_window_public to anon;

-- Finestra settimanale iniziale: Lun-Ven 8:00-20:00 (nessun'app UI ancora per
-- modificarla — per ora si aggiorna così, o chiedendo di farlo in chat)
update calendar_settings set booking_window = '{
  "mon": [{"start":"08:00","end":"20:00"}],
  "tue": [{"start":"08:00","end":"20:00"}],
  "wed": [{"start":"08:00","end":"20:00"}],
  "thu": [{"start":"08:00","end":"20:00"}],
  "fri": [{"start":"08:00","end":"20:00"}],
  "sat": [],
  "sun": []
}'::jsonb;
