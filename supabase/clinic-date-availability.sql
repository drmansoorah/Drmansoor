-- Clinic date availability: only dates explicitly opened by clinic admins can be booked.
create table if not exists public.clinic_date_availability (
  clinic_key text not null,
  available_date date not null,
  is_available boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (clinic_key, available_date)
);

alter table public.clinic_date_availability enable row level security;

drop policy if exists "Public can read available clinic dates" on public.clinic_date_availability;
create policy "Public can read available clinic dates"
on public.clinic_date_availability for select to anon, authenticated
using (
  is_available = true
  or (
    (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin'
    and (
      coalesce(auth.jwt() -> 'app_metadata' ->> 'clinic_key', '*') = '*'
      or clinic_key = (auth.jwt() -> 'app_metadata' ->> 'clinic_key')
    )
  )
);

drop policy if exists "Clinic admins can add availability" on public.clinic_date_availability;
create policy "Clinic admins can add availability"
on public.clinic_date_availability for insert to authenticated
with check (
  (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin'
  and (
    coalesce(auth.jwt() -> 'app_metadata' ->> 'clinic_key', '*') = '*'
    or clinic_key = (auth.jwt() -> 'app_metadata' ->> 'clinic_key')
  )
);

drop policy if exists "Clinic admins can update availability" on public.clinic_date_availability;
create policy "Clinic admins can update availability"
on public.clinic_date_availability for update to authenticated
using (
  (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin'
  and (
    coalesce(auth.jwt() -> 'app_metadata' ->> 'clinic_key', '*') = '*'
    or clinic_key = (auth.jwt() -> 'app_metadata' ->> 'clinic_key')
  )
)
with check (
  (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin'
  and (
    coalesce(auth.jwt() -> 'app_metadata' ->> 'clinic_key', '*') = '*'
    or clinic_key = (auth.jwt() -> 'app_metadata' ->> 'clinic_key')
  )
);

grant select on public.clinic_date_availability to anon, authenticated;
grant insert, update on public.clinic_date_availability to authenticated;

-- Database-side protection: reject a new appointment unless its clinic/date is open.
create or replace function public.enforce_clinic_date_availability()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_clinic_key text;
begin
  v_clinic_key := coalesce(
    nullif(new.clinic_key, ''),
    nullif(split_part(coalesce(new.clinic, ''), '::', 1), '')
  );

  if v_clinic_key is null
     or new.appointment_date is null
     or not exists (
       select 1
       from public.clinic_date_availability a
       where a.clinic_key = v_clinic_key
         and a.available_date = new.appointment_date
         and a.is_available = true
     ) then
    raise exception 'This date is not currently available for booking at the selected clinic.'
      using errcode = 'P0001';
  end if;

  return new;
end;
$$;

drop trigger if exists enforce_clinic_date_availability_before_insert on public.appointments;
create trigger enforce_clinic_date_availability_before_insert
before insert on public.appointments
for each row execute function public.enforce_clinic_date_availability();
