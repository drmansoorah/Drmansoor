-- Clinic-wise appointment routing and clinic-admin dashboard scope.
-- Run AFTER doctor-portal.sql, patient-portal.sql and permanent-patient-access.sql.
-- Clinic keys:
--   mansoor-private  -> Mansoor Psychiatry & MindCare Clinic
--   gmc-anantnag     -> GMC Anantnag Associated Hospital
--   south-kashmir    -> South Kashmir Mental Wellness Centre
--
-- Assign each clinic admin in Supabase Auth > Users > user > app_metadata:
--   {"role":"admin","clinic_key":"mansoor-private"}
--   {"role":"admin","clinic_key":"gmc-anantnag"}
--   {"role":"admin","clinic_key":"south-kashmir"}
-- Existing admin users without clinic_key (or with clinic_key="*") remain master admins.

alter table public.appointments
  add column if not exists clinic_key text;

-- Backfill previous requests before making the clinic key mandatory.
update public.appointments
set clinic_key = case
  when clinic ilike '%GMC%' then 'gmc-anantnag'
  when clinic ilike '%ExpectCare%' or clinic ilike '%Cheeni Chowk%' then 'mansoor-private'
  else 'south-kashmir'
end
where clinic_key is null or btrim(clinic_key) = '';

-- Replace the old public-facing ExpectCare label with the editable clinic name.
update public.appointments
set clinic = 'Mansoor Psychiatry & MindCare Clinic'
where clinic ilike '%ExpectCare%';

alter table public.appointments
  alter column clinic_key set default 'south-kashmir',
  alter column clinic_key set not null;

create index if not exists appointments_clinic_created_idx
  on public.appointments(clinic_key, created_at desc);

create or replace function public.route_appointment_to_clinic()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $clinic_route$
declare
  v_delimiter integer;
  v_key text;
  v_label text;
begin
  v_delimiter := position('::' in coalesce(new.clinic, ''));

  if v_delimiter > 0 then
    v_key := lower(btrim(left(new.clinic, v_delimiter - 1)));
    v_label := btrim(substr(new.clinic, v_delimiter + 2));

    if v_key not in ('mansoor-private', 'gmc-anantnag', 'south-kashmir') then
      raise exception 'Please select a valid clinic';
    end if;
    if length(v_label) < 3 then
      raise exception 'Clinic name is missing';
    end if;

    new.clinic_key := v_key;
    new.clinic := v_label;
  elsif tg_op = 'INSERT' or new.clinic is distinct from old.clinic then
    if new.clinic ilike '%GMC%' then
      new.clinic_key := 'gmc-anantnag';
    elsif new.clinic ilike '%ExpectCare%' or new.clinic ilike '%Cheeni Chowk%' then
      new.clinic_key := 'mansoor-private';
    elsif coalesce(new.clinic_key, '') not in ('mansoor-private', 'gmc-anantnag', 'south-kashmir') then
      new.clinic_key := 'south-kashmir';
    end if;
  end if;

  return new;
end;
$clinic_route$;

drop trigger if exists trg_route_appointment_to_clinic on public.appointments;
create trigger trg_route_appointment_to_clinic
before insert or update of clinic on public.appointments
for each row execute function public.route_appointment_to_clinic();

-- Keep RLS enabled. A restrictive policy makes clinic scope apply even if an
-- older permissive policy exists on appointments.
alter table public.appointments enable row level security;

drop policy if exists "Admins read assigned clinic appointments" on public.appointments;
create policy "Admins read assigned clinic appointments"
on public.appointments
for select
to authenticated
using ((auth.jwt() -> 'app_metadata' ->> 'role') = 'admin');

drop policy if exists "Restrict appointments to assigned clinic" on public.appointments;
create policy "Restrict appointments to assigned clinic"
on public.appointments
as restrictive
for select
to authenticated
using (
  (
    (auth.jwt() -> 'app_metadata' ->> 'role') = 'doctor'
    and status = 'approved'
  )
  or
  (
    (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin'
    and (
      coalesce(nullif(auth.jwt() -> 'app_metadata' ->> 'clinic_key', ''), '*') = '*'
      or clinic_key = auth.jwt() -> 'app_metadata' ->> 'clinic_key'
    )
  )
);

grant select on public.appointments to authenticated;

-- Security-definer guard used by the admin page before calling the notification edge function.
create or replace function public.admin_can_access_appointment(p_appointment_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $guard$
  select
    auth.uid() is not null
    and (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin'
    and exists (
      select 1
      from public.appointments a
      where a.id = p_appointment_id
        and (
          coalesce(nullif(auth.jwt() -> 'app_metadata' ->> 'clinic_key', ''), '*') = '*'
          or a.clinic_key = auth.jwt() -> 'app_metadata' ->> 'clinic_key'
        )
    );
$guard$;

revoke all on function public.admin_can_access_appointment(uuid) from public, anon;
grant execute on function public.admin_can_access_appointment(uuid) to authenticated;

-- Apply clinic scoping to the permanent access-code reveal RPC as well.
create or replace function public.staff_get_patient_portal_credentials(p_patient_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $staff$
declare
  v_role text;
  v_cipher bytea;
  v_patient_code text := upper(trim(coalesce(p_patient_code,'')));
  v_key text;
  v_name text;
  v_phone text;
  v_admin_clinic text;
begin
  v_role := auth.jwt()->'app_metadata'->>'role';
  v_admin_clinic := coalesce(nullif(auth.jwt()->'app_metadata'->>'clinic_key',''),'*');

  if auth.uid() is null or coalesce(v_role,'') not in ('doctor','admin') then
    raise exception 'Doctor or admin access required';
  end if;

  if v_role = 'admin' and v_admin_clinic <> '*' then
    if not exists (
      select 1 from public.appointments a
      where upper(a.patient_code) = v_patient_code
        and a.clinic_key = v_admin_clinic
    ) then
      raise exception 'This patient belongs to a different clinic dashboard';
    end if;
  end if;

  if v_role = 'doctor' then
    select p.access_code_ciphertext,p.patient_code,p.full_name,p.phone
      into v_cipher,v_patient_code,v_name,v_phone
    from public.patients p
    where upper(p.patient_code) = upper(trim(p_patient_code))
      and p.doctor_id = auth.uid()
    limit 1;

    if not found then
      select a.portal_access_ciphertext,a.patient_code,a.patient_name,a.phone
        into v_cipher,v_patient_code,v_name,v_phone
      from public.appointments a
      where upper(a.patient_code) = upper(trim(p_patient_code))
        and a.status = 'approved'
      order by a.created_at asc
      limit 1;
    end if;
  else
    select p.access_code_ciphertext,p.patient_code,p.full_name,p.phone
      into v_cipher,v_patient_code,v_name,v_phone
    from public.patients p
    where upper(p.patient_code) = upper(trim(p_patient_code))
    limit 1;

    if not found then
      select a.portal_access_ciphertext,a.patient_code,a.patient_name,a.phone
        into v_cipher,v_patient_code,v_name,v_phone
      from public.appointments a
      where upper(a.patient_code) = upper(trim(p_patient_code))
        and (
          v_admin_clinic = '*'
          or a.clinic_key = v_admin_clinic
        )
      order by a.created_at asc
      limit 1;
    end if;
  end if;

  if not found and v_name is null then
    return jsonb_build_object('patient_code',v_patient_code,'access_code',null,'message','Patient record not found.');
  end if;

  if v_cipher is null then
    return jsonb_build_object(
      'patient_code',v_patient_code,'access_code',null,'patient_name',v_name,'phone',v_phone,
      'message','This older code was saved only as a one-way hash and cannot be displayed. Verify the patient before issuing a new permanent code.'
    );
  end if;

  v_key := public._patient_portal_encryption_key();
  return jsonb_build_object(
    'patient_code',v_patient_code,
    'access_code',pgp_sym_decrypt(v_cipher,v_key),
    'patient_name',v_name,
    'phone',v_phone
  );
end;
$staff$;

revoke all on function public.staff_get_patient_portal_credentials(text) from public, anon;
grant execute on function public.staff_get_patient_portal_credentials(text) to authenticated;

