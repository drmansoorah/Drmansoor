-- Clinic-scoped psychiatrist workspace access.
-- Run AFTER clinic-routing.sql, permanent-patient-access.sql,
-- master-admin-doctor-access.sql and doctor-clinic-workspace.sql.
-- Clinic admins are the treating psychiatrist for their assigned clinic.
-- No staff-management tables or staff roles are introduced.

alter table public.patients
  add column if not exists clinic_key text;

alter table public.prescriptions
  add column if not exists clinic_key text;

-- Attach older prescriptions to the clinic already assigned to their patient
-- or original appointment. Preserve existing history and values.
update public.prescriptions r
set clinic_key = p.clinic_key
from public.patients p
where r.patient_id = p.id
  and r.clinic_key is null
  and p.clinic_key is not null;

update public.prescriptions r
set clinic_key = a.clinic_key
from public.appointments a
where r.appointment_id = a.id
  and r.clinic_key is null
  and a.clinic_key is not null;

create index if not exists prescriptions_clinic_created_idx
  on public.prescriptions(clinic_key, created_at desc);

-- A clinic admin may read only the patient records attached to the clinic
-- assigned in the signed app_metadata JWT.
drop policy if exists "Clinic clinicians read assigned patients" on public.patients;
create policy "Clinic clinicians read assigned patients"
on public.patients
for select
to authenticated
using (
  (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin'
  and coalesce(nullif(auth.jwt() -> 'app_metadata' ->> 'clinic_key', ''), '*')
      in ('mansoor-private', 'gmc-anantnag', 'south-kashmir')
  and clinic_key = auth.jwt() -> 'app_metadata' ->> 'clinic_key'
);

drop policy if exists "Clinic clinicians create assigned patients" on public.patients;
create policy "Clinic clinicians create assigned patients"
on public.patients
for insert
to authenticated
with check (
  (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin'
  and clinic_key = auth.jwt() -> 'app_metadata' ->> 'clinic_key'
);

drop policy if exists "Clinic clinicians update assigned patients" on public.patients;
create policy "Clinic clinicians update assigned patients"
on public.patients
for update
to authenticated
using (
  (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin'
  and clinic_key = auth.jwt() -> 'app_metadata' ->> 'clinic_key'
)
with check (
  (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin'
  and clinic_key = auth.jwt() -> 'app_metadata' ->> 'clinic_key'
);

-- Prescription access is scoped through the saved clinic_key and, on writes,
-- cross-checked against the patient record in the same clinic.
drop policy if exists "Clinic clinicians read assigned prescriptions" on public.prescriptions;
create policy "Clinic clinicians read assigned prescriptions"
on public.prescriptions
for select
to authenticated
using (
  (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin'
  and clinic_key = auth.jwt() -> 'app_metadata' ->> 'clinic_key'
  and coalesce(nullif(auth.jwt() -> 'app_metadata' ->> 'clinic_key', ''), '*')
      in ('mansoor-private', 'gmc-anantnag', 'south-kashmir')
);

drop policy if exists "Clinic clinicians create assigned prescriptions" on public.prescriptions;
create policy "Clinic clinicians create assigned prescriptions"
on public.prescriptions
for insert
to authenticated
with check (
  (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin'
  and clinic_key = auth.jwt() -> 'app_metadata' ->> 'clinic_key'
  and exists (
    select 1
    from public.patients p
    where p.id = patient_id
      and p.clinic_key = auth.jwt() -> 'app_metadata' ->> 'clinic_key'
      and prescriptions.doctor_id in (auth.uid(), p.doctor_id)
  )
);

drop policy if exists "Clinic clinicians update assigned prescriptions" on public.prescriptions;
create policy "Clinic clinicians update assigned prescriptions"
on public.prescriptions
for update
to authenticated
using (
  (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin'
  and clinic_key = auth.jwt() -> 'app_metadata' ->> 'clinic_key'
)
with check (
  (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin'
  and clinic_key = auth.jwt() -> 'app_metadata' ->> 'clinic_key'
  and exists (
    select 1
    from public.patients p
    where p.id = patient_id
      and p.clinic_key = auth.jwt() -> 'app_metadata' ->> 'clinic_key'
      and prescriptions.doctor_id in (auth.uid(), p.doctor_id)
  )
);

grant select, insert, update on public.patients to authenticated;
grant select, insert, update on public.prescriptions to authenticated;

-- Allow the assigned clinic psychiatrist, the doctor account, or the
-- unscoped Master Admin to retrieve/initialize a patient's permanent code.
-- A scoped clinic admin can never use this RPC against another clinic.
create or replace function public.doctor_initialize_patient_portal_code(p_patient_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $issue$
declare
  v_patient public.patients%rowtype;
  v_role text;
  v_clinic_key text;
  v_code text;
  v_key text;
  v_random bytea;
  v_i integer;
  v_alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
begin
  v_role := coalesce(auth.jwt()->'app_metadata'->>'role','');
  v_clinic_key := coalesce(nullif(auth.jwt()->'app_metadata'->>'clinic_key',''), '*');

  if auth.uid() is null or not (
    v_role = 'doctor'
    or (v_role = 'admin' and v_clinic_key = '*')
    or (v_role = 'admin' and v_clinic_key in ('mansoor-private','gmc-anantnag','south-kashmir'))
  ) then
    raise exception 'Clinician or Master Admin access required';
  end if;

  select * into v_patient
  from public.patients
  where id = p_patient_id
    and (
      (v_role = 'doctor' and doctor_id = auth.uid())
      or (v_role = 'admin' and v_clinic_key = '*' )
      or (v_role = 'admin' and clinic_key = v_clinic_key)
    )
  for update;

  if not found then
    raise exception 'Patient record not found in your assigned clinic';
  end if;

  if v_patient.access_code_ciphertext is null then
    v_code := '';
    v_random := gen_random_bytes(7);
    for v_i in 0..6 loop
      v_code := v_code || substr(v_alphabet,(get_byte(v_random,v_i) % length(v_alphabet))+1,1);
    end loop;
    v_key := public._patient_portal_encryption_key();

    update public.patients
    set patient_code = coalesce(patient_code,public.generate_patient_portal_id()),
        access_code_hash = crypt(v_code,gen_salt('bf')),
        access_code_ciphertext = pgp_sym_encrypt(v_code,v_key),
        portal_access_enabled = true,
        portal_access_updated_at = now(),
        updated_at = now()
    where id = p_patient_id
    returning patient_code into v_patient.patient_code;

    return jsonb_build_object('patient_code',v_patient.patient_code,'access_code',v_code,'created',true);
  end if;

  v_key := public._patient_portal_encryption_key();
  v_code := pgp_sym_decrypt(v_patient.access_code_ciphertext,v_key);
  return jsonb_build_object('patient_code',v_patient.patient_code,'access_code',v_code,'created',false);
end;
$issue$;

revoke all on function public.doctor_initialize_patient_portal_code(uuid) from public;
grant execute on function public.doctor_initialize_patient_portal_code(uuid) to authenticated;

-- Read a permanent access code only after verifying the requesting clinic.
create or replace function public.staff_get_patient_portal_credentials(p_patient_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $staff$
declare
  v_role text;
  v_clinic_key text;
  v_cipher bytea;
  v_code text := upper(trim(coalesce(p_patient_code,'')));
  v_key text;
  v_name text;
  v_phone text;
begin
  v_role := coalesce(auth.jwt()->'app_metadata'->>'role','');
  v_clinic_key := coalesce(nullif(auth.jwt()->'app_metadata'->>'clinic_key',''), '*');

  if auth.uid() is null or v_role not in ('doctor','admin') then
    raise exception 'Clinician or admin access required';
  end if;

  if v_role = 'admin' and v_clinic_key <> '*' then
    if v_clinic_key not in ('mansoor-private','gmc-anantnag','south-kashmir') then
      raise exception 'Unknown clinic assignment';
    end if;
    select p.access_code_ciphertext,p.patient_code,p.full_name,p.phone
      into v_cipher,v_code,v_name,v_phone
    from public.patients p
    where upper(p.patient_code) = upper(trim(p_patient_code))
      and p.clinic_key = v_clinic_key
    limit 1;

    if not found then
      select a.portal_access_ciphertext,a.patient_code,a.patient_name,a.phone
        into v_cipher,v_code,v_name,v_phone
      from public.appointments a
      where upper(a.patient_code) = upper(trim(p_patient_code))
        and a.clinic_key = v_clinic_key
      order by a.created_at asc
      limit 1;
    end if;
  elsif v_role = 'doctor' then
    select p.access_code_ciphertext,p.patient_code,p.full_name,p.phone
      into v_cipher,v_code,v_name,v_phone
    from public.patients p
    where upper(p.patient_code) = upper(trim(p_patient_code))
      and p.doctor_id = auth.uid()
    limit 1;

    if not found then
      select a.portal_access_ciphertext,a.patient_code,a.patient_name,a.phone
        into v_cipher,v_code,v_name,v_phone
      from public.appointments a
      where upper(a.patient_code) = upper(trim(p_patient_code))
        and a.status = 'approved'
      order by a.created_at asc
      limit 1;
    end if;
  else
    select p.access_code_ciphertext,p.patient_code,p.full_name,p.phone
      into v_cipher,v_code,v_name,v_phone
    from public.patients p
    where upper(p.patient_code) = upper(trim(p_patient_code))
    limit 1;

    if not found then
      select a.portal_access_ciphertext,a.patient_code,a.patient_name,a.phone
        into v_cipher,v_code,v_name,v_phone
      from public.appointments a
      where upper(a.patient_code) = upper(trim(p_patient_code))
      order by a.created_at asc
      limit 1;
    end if;
  end if;

  if v_name is null then
    return jsonb_build_object('patient_code',v_code,'access_code',null,'message','Patient record not found in your workspace.');
  end if;

  if v_cipher is null then
    return jsonb_build_object(
      'patient_code',v_code,'access_code',null,'patient_name',v_name,'phone',v_phone,
      'message','This older code was saved only as a one-way hash and cannot be displayed. Verify the patient before issuing a new permanent code.'
    );
  end if;

  v_key := public._patient_portal_encryption_key();
  return jsonb_build_object(
    'patient_code',v_code,
    'access_code',pgp_sym_decrypt(v_cipher,v_key),
    'patient_name',v_name,
    'phone',v_phone
  );
end;
$staff$;

revoke all on function public.staff_get_patient_portal_credentials(text) from public, anon;
grant execute on function public.staff_get_patient_portal_credentials(text) to authenticated;
