-- Doctor portal foundation for Dr Mansoor
-- Run this once in Supabase SQL Editor. Does not expose service-role credentials.

create table if not exists public.prescriptions (
  id uuid primary key default gen_random_uuid(),
  appointment_id uuid not null references public.appointments(id) on delete cascade,
  doctor_id uuid not null references auth.users(id) on delete restrict,
  diagnosis text not null,
  medicines text not null default '',
  advice text not null default '',
  follow_up_date date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.prescriptions enable row level security;

drop policy if exists "Doctors read approved appointments" on public.appointments;
create policy "Doctors read approved appointments"
on public.appointments for select to authenticated
using (
  status = 'approved'
  and (auth.jwt() -> 'app_metadata' ->> 'role') = 'doctor'
);

drop policy if exists "Doctors read own prescriptions" on public.prescriptions;
create policy "Doctors read own prescriptions"
on public.prescriptions for select to authenticated
using (
  doctor_id = auth.uid()
  and (auth.jwt() -> 'app_metadata' ->> 'role') = 'doctor'
);

drop policy if exists "Doctors create own prescriptions" on public.prescriptions;
create policy "Doctors create own prescriptions"
on public.prescriptions for insert to authenticated
with check (
  doctor_id = auth.uid()
  and (auth.jwt() -> 'app_metadata' ->> 'role') = 'doctor'
  and exists (
    select 1 from public.appointments a
    where a.id = appointment_id and a.status = 'approved'
  )
);

drop policy if exists "Doctors update own prescriptions" on public.prescriptions;
create policy "Doctors update own prescriptions"
on public.prescriptions for update to authenticated
using (
  doctor_id = auth.uid()
  and (auth.jwt() -> 'app_metadata' ->> 'role') = 'doctor'
)
with check (
  doctor_id = auth.uid()
  and (auth.jwt() -> 'app_metadata' ->> 'role') = 'doctor'
);

create index if not exists prescriptions_appointment_id_idx
on public.prescriptions(appointment_id);

create index if not exists prescriptions_doctor_id_idx
on public.prescriptions(doctor_id);
