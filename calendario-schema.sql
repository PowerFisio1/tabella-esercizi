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
