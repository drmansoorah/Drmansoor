-- Doctor Workspace: patient directory, longitudinal prescription history and RLS.
-- Safe to run more than once. Uses the existing Supabase Auth doctor role.
-- Run from Supabase Dashboard > SQL Editor.

create table if not exists public.patients (
  id uuid primary key default gen_random_uuid(),
  doctor_id uuid not null references auth.users(id) on delete cascade,
  full_name text not null,
  phone text not null,
  age integer,
  gender text,
  allergies text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint patients_doctor_phone_unique unique (doctor_id, phone)
);

create table if not exists public.prescriptions (
  id uuid primary key default gen_random_uuid(),
  appointment_id uuid references public.appointments(id) on delete set null,
  doctor_id uuid not null references auth.users(id) on delete restrict,
  diagnosis text not null,
  medicines text not null default '',
  advice text not null default '',
  follow_up_date date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.prescriptions alter column appointment_id drop not null;
alter table public.prescriptions add column if not exists patient_id uuid references public.patients(id) on delete restrict;
alter table public.prescriptions add column if not exists patient_name text;
alter table public.prescriptions add column if not exists patient_phone text;
alter table public.prescriptions add column if not exists patient_age integer;
alter table public.prescriptions add column if not exists patient_gender text;
alter table public.prescriptions add column if not exists medication_items jsonb not null default '[]'::jsonb;
alter table public.prescriptions add column if not exists complaints text not null default '';
alter table public.prescriptions add column if not exists clinical_notes text not null default '';
alter table public.prescriptions add column if not exists vitals jsonb not null default '{}'::jsonb;

-- Backfill patient identities for prescriptions created by the earlier appointment-only portal.
insert into public.patients (doctor_id, full_name, phone)
select distinct p.doctor_id, a.patient_name, a.phone
from public.prescriptions p
join public.appointments a on a.id = p.appointment_id
where nullif(trim(a.phone), '') is not null
on conflict (doctor_id, phone) do update
set full_name = excluded.full_name;

update public.prescriptions p
set patient_id = pt.id,
    patient_name = coalesce(p.patient_name, a.patient_name),
    patient_phone = coalesce(p.patient_phone, a.phone)
from public.appointments a
join public.patients pt on pt.phone = a.phone
where p.appointment_id = a.id
  and pt.doctor_id = p.doctor_id
  and p.patient_id is null;

alter table public.patients enable row level security;
alter table public.prescriptions enable row level security;

drop policy if exists "Doctors read approved appointments" on public.appointments;
create policy "Doctors read approved appointments"
on public.appointments for select to authenticated
using (
  status = 'approved'
  and (auth.jwt() -> 'app_metadata' ->> 'role') = 'doctor'
);

drop policy if exists "Doctors read own patients" on public.patients;
create policy "Doctors read own patients"
on public.patients for select to authenticated
using (doctor_id = auth.uid() and (auth.jwt() -> 'app_metadata' ->> 'role') = 'doctor');

drop policy if exists "Doctors create own patients" on public.patients;
create policy "Doctors create own patients"
on public.patients for insert to authenticated
with check (doctor_id = auth.uid() and (auth.jwt() -> 'app_metadata' ->> 'role') = 'doctor');

drop policy if exists "Doctors update own patients" on public.patients;
create policy "Doctors update own patients"
on public.patients for update to authenticated
using (doctor_id = auth.uid() and (auth.jwt() -> 'app_metadata' ->> 'role') = 'doctor')
with check (doctor_id = auth.uid() and (auth.jwt() -> 'app_metadata' ->> 'role') = 'doctor');

drop policy if exists "Doctors read own prescriptions" on public.prescriptions;
create policy "Doctors read own prescriptions"
on public.prescriptions for select to authenticated
using (doctor_id = auth.uid() and (auth.jwt() -> 'app_metadata' ->> 'role') = 'doctor');

drop policy if exists "Doctors create own prescriptions" on public.prescriptions;
create policy "Doctors create own prescriptions"
on public.prescriptions for insert to authenticated
with check (
  doctor_id = auth.uid()
  and (auth.jwt() -> 'app_metadata' ->> 'role') = 'doctor'
  and exists (select 1 from public.patients pt where pt.id = patient_id and pt.doctor_id = auth.uid())
  and (
    appointment_id is null
    or exists (select 1 from public.appointments a where a.id = appointment_id and a.status = 'approved')
  )
);

drop policy if exists "Doctors update own prescriptions" on public.prescriptions;
create policy "Doctors update own prescriptions"
on public.prescriptions for update to authenticated
using (doctor_id = auth.uid() and (auth.jwt() -> 'app_metadata' ->> 'role') = 'doctor')
with check (
  doctor_id = auth.uid()
  and (auth.jwt() -> 'app_metadata' ->> 'role') = 'doctor'
);

create index if not exists patients_doctor_name_idx on public.patients (doctor_id, full_name);
create index if not exists patients_doctor_phone_idx on public.patients (doctor_id, phone);
create index if not exists prescriptions_patient_created_idx on public.prescriptions (patient_id, created_at desc);
create index if not exists prescriptions_doctor_created_idx on public.prescriptions (doctor_id, created_at desc);

grant select, insert, update on public.patients to authenticated;
grant select, insert, update on public.prescriptions to authenticated;
