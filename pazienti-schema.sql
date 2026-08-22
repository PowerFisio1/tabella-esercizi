-- ============================================================================
-- Schema Supabase per la sezione Pazienti (anagrafica + storico visite, base
-- per la generazione dei Report). Da eseguire UNA VOLTA nel SQL editor di
-- Supabase (stesso progetto già usato per le altre tabelle). Non tocca le
-- tabelle esistenti.
-- ============================================================================

-- ---- Anagrafica pazienti: una riga per paziente ----
create table if not exists patients (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  full_name text not null,
  birth_date date,
  referring_doctor text,   -- medico curante/inviante, per l'intestazione dei report
  diagnosis text,          -- diagnosi / motivo dell'invio
  notes text,              -- anamnesi e note iniziali generali
  archived boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists patients_user_idx on patients (user_id, full_name);

alter table patients enable row level security;

create policy "patients_select_own" on patients
  for select using (auth.uid() = user_id);
create policy "patients_insert_own" on patients
  for insert with check (auth.uid() = user_id);
create policy "patients_update_own" on patients
  for update using (auth.uid() = user_id);
create policy "patients_delete_own" on patients
  for delete using (auth.uid() = user_id);

-- ---- Storico visite: una riga per seduta, con i dati oggettivi da cui
--      nasceranno i report (dolore fisso + misurazioni libere per tutto ciò
--      che dipende dalla zona/diagnosi: ROM, forza, test speciali, ecc.) ----
create table if not exists patient_visits (
  id uuid primary key,
  patient_id uuid not null references patients(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  visit_date date not null,
  pain_score integer,             -- NRS 0-10
  pain_context text,              -- 'riposo' | 'movimento' | 'notturno' | null
  measurements jsonb not null default '[]'::jsonb, -- [{type, label, value}, ...]
  functional_goal text,           -- obiettivo funzionale raggiunto
  adherence text,                 -- 'buona' | 'parziale' | 'scarsa' | null
  notes text,                     -- note cliniche narrative
  updated_at timestamptz not null default now()
);

create index if not exists patient_visits_patient_idx on patient_visits (patient_id, visit_date);
create index if not exists patient_visits_user_idx on patient_visits (user_id);

alter table patient_visits enable row level security;

create policy "patient_visits_select_own" on patient_visits
  for select using (auth.uid() = user_id);
create policy "patient_visits_insert_own" on patient_visits
  for insert with check (auth.uid() = user_id);
create policy "patient_visits_update_own" on patient_visits
  for update using (auth.uid() = user_id);
create policy "patient_visits_delete_own" on patient_visits
  for delete using (auth.uid() = user_id);

-- ---- Realtime: perché un secondo dispositivo veda pazienti/visite in diretta.
--      Se questo comando desse errore ("already member of publication" o
--      simile), è già attivo: si può anche attivare a mano da Supabase ->
--      Database -> Replication -> spunta "patients" e "patient_visits". ----
alter publication supabase_realtime add table patients;
alter publication supabase_realtime add table patient_visits;
