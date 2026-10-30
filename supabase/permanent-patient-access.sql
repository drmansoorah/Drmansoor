-- Permanent Patient Portal credentials.
-- Run AFTER doctor-portal.sql and patient-portal.sql.
-- Stores the patient access code encrypted (Vault-backed key) plus a bcrypt hash for patient login.
-- Doctor/admin can retrieve the same code. Existing hashes without ciphertext cannot be reversed.

create extension if not exists pgcrypto with schema extensions;
create extension if not exists supabase_vault with schema vault;

do $vaultkey$
begin
  if not exists (
    select 1 from vault.secrets where name = 'patient_portal_access_code_key'
  ) then
    perform vault.create_secret(
      replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
      'patient_portal_access_code_key',
      'Encryption key for permanent patient portal access codes'
    );
  end if;
end;
$vaultkey$;

alter table public.appointments
  add column if not exists portal_access_ciphertext bytea;

alter table public.patients
  add column if not exists access_code_ciphertext bytea;

-- One patient may have multiple appointments; Patient ID belongs to the patient, not each booking.
drop index if exists public.appointments_patient_code_unique;
create index if not exists appointments_patient_code_idx
  on public.appointments(patient_code) where patient_code is not null;

-- Enforce credential immutability at database level, not just in the dashboard UI.
create or replace function public.prevent_patient_portal_credential_change()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $immutable$
begin
  if tg_table_name = 'patients' then
    if old.patient_code is not null and new.patient_code is distinct from old.patient_code
       and current_user <> 'postgres' then
      raise exception 'Patient ID is permanent and cannot be changed';
    end if;
    if (new.access_code_hash is distinct from old.access_code_hash
        or new.access_code_ciphertext is distinct from old.access_code_ciphertext)
       and current_user <> 'postgres' then
      raise exception 'MindCare Access Code is permanent and cannot be changed';
    end if;
    if old.access_code_ciphertext is not null
       and new.access_code_ciphertext is distinct from old.access_code_ciphertext then
      raise exception 'MindCare Access Code is permanent and cannot be replaced';
    end if;
  elsif tg_table_name = 'appointments' then
    if old.patient_code is not null and new.patient_code is distinct from old.patient_code
       and current_user <> 'postgres' then
      raise exception 'Patient ID is permanent and cannot be changed';
    end if;
    if (new.portal_access_hash is distinct from old.portal_access_hash
        or new.portal_access_ciphertext is distinct from old.portal_access_ciphertext)
       and current_user <> 'postgres' then
      raise exception 'MindCare Access Code is permanent and cannot be changed';
    end if;
    if old.portal_access_ciphertext is not null
       and new.portal_access_ciphertext is distinct from old.portal_access_ciphertext then
      raise exception 'MindCare Access Code is permanent and cannot be replaced';
    end if;
  end if;
  return new;
end;
$immutable$;

drop trigger if exists trg_patient_portal_credentials_immutable on public.patients;
create trigger trg_patient_portal_credentials_immutable
before update on public.patients
for each row execute function public.prevent_patient_portal_credential_change();

drop trigger if exists trg_appointment_portal_credentials_immutable on public.appointments;
create trigger trg_appointment_portal_credentials_immutable
before update on public.appointments
for each row execute function public.prevent_patient_portal_credential_change();

create or replace function public._patient_portal_encryption_key()
returns text
language plpgsql
security definer
set search_path = public, vault, pg_temp
as $key$
declare
  v_key text;
begin
  select decrypted_secret into v_key
  from vault.decrypted_secrets
  where name = 'patient_portal_access_code_key'
  limit 1;

  if coalesce(v_key, '') = '' then
    raise exception 'Patient portal encryption key is unavailable in Supabase Vault';
  end if;
  return v_key;
end;
$key$;

revoke all on function public._patient_portal_encryption_key() from public, anon, authenticated;

-- Existing patients retain their ID and code whenever an encrypted credential already exists.
-- Repeat applications with the same phone reuse the existing patient credentials, but do not
-- reveal an existing code to an unauthenticated applicant.
create or replace function public.request_patient_appointment(
  p_patient_name text,
  p_phone text,
  p_clinic text,
  p_concern text,
  p_appointment_date date,
  p_slot text,
  p_communication_consent boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $booking$
declare
  v_doctor_id uuid;
  v_patient_code text;
  v_access_code text;
  v_hash text;
  v_cipher bytea;
  v_key text;
  v_appointment_id uuid;
  v_i integer;
  v_random bytea;
  v_alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_existing boolean := false;
begin
  if coalesce(length(trim(p_patient_name)),0) < 2 or length(trim(p_patient_name)) > 100 then
    raise exception 'Please enter a valid patient name';
  end if;
  if coalesce(length(trim(p_phone)),0) < 10 or length(trim(p_phone)) > 25
     or length(regexp_replace(p_phone,'[^0-9]','','g')) < 10 then
    raise exception 'Please enter a valid contact number';
  end if;
  if coalesce(length(trim(p_clinic)),0) < 3 or coalesce(length(trim(p_concern)),0) < 3
     or coalesce(length(trim(p_slot)),0) < 3 then
    raise exception 'Please complete all appointment fields';
  end if;
  if p_appointment_date is null or p_appointment_date < current_date then
    raise exception 'Please select today or a future appointment date';
  end if;
  if p_communication_consent is distinct from true then
    raise exception 'Appointment communication consent is required';
  end if;

  select u.id into v_doctor_id
  from auth.users u
  where u.raw_app_meta_data->>'role' = 'doctor'
  order by u.created_at asc
  limit 1;

  if v_doctor_id is null then
    raise exception 'Doctor account with doctor role was not found';
  end if;

  -- Reuse an existing saved patient credential for the same phone.
  select pt.patient_code, pt.access_code_hash, pt.access_code_ciphertext
    into v_patient_code, v_hash, v_cipher
  from public.patients pt
  where pt.doctor_id = v_doctor_id
    and regexp_replace(pt.phone,'[^0-9]','','g') = regexp_replace(trim(p_phone),'[^0-9]','','g')
    and pt.patient_code is not null
    and pt.access_code_hash is not null
    and pt.access_code_ciphertext is not null
  order by pt.created_at asc
  limit 1;

  if found then
    v_existing := true;
  else
    -- Also reuse credentials from an earlier pending booking not yet approved.
    select a.patient_code, a.portal_access_hash, a.portal_access_ciphertext
      into v_patient_code, v_hash, v_cipher
    from public.appointments a
    where regexp_replace(a.phone,'[^0-9]','','g') = regexp_replace(trim(p_phone),'[^0-9]','','g')
      and a.status in ('pending','approved')
      and a.patient_code is not null
      and a.portal_access_hash is not null
      and a.portal_access_ciphertext is not null
    order by a.created_at asc
    limit 1;

    if found then
      v_existing := true;
    end if;
  end if;

  if not v_existing then
    v_access_code := '';
    v_random := extensions.gen_random_bytes(7);
    for v_i in 0..6 loop
      v_access_code := v_access_code ||
        substr(v_alphabet, (get_byte(v_random,v_i) % length(v_alphabet)) + 1, 1);
    end loop;
    v_patient_code := public.generate_patient_portal_id();
    v_hash := extensions.crypt(v_access_code, extensions.gen_salt('bf'));
    v_key := public._patient_portal_encryption_key();
    v_cipher := extensions.pgp_sym_encrypt(v_access_code, v_key);
  end if;

  insert into public.appointments(
    patient_name,phone,clinic,concern,appointment_date,slot,
    communication_consent,status,patient_code,portal_access_hash,
    portal_access_enabled,portal_access_issued_at,portal_access_ciphertext
  ) values (
    trim(p_patient_name),trim(p_phone),trim(p_clinic),trim(p_concern),p_appointment_date,trim(p_slot),
    true,'pending',v_patient_code,v_hash,false,now(),v_cipher
  ) returning id into v_appointment_id;

  return jsonb_build_object(
    'appointment_id',v_appointment_id,
    'patient_code',v_patient_code,
    'portal_access_code',case when v_existing then null else v_access_code end,
    'existing_credentials',v_existing,
    'status','pending',
    'portal_access_enabled',false
  );
end;
$booking$;

revoke all on function public.request_patient_appointment(text,text,text,text,date,text,boolean) from public;
grant execute on function public.request_patient_appointment(text,text,text,text,date,text,boolean) to anon, authenticated;

-- Activate after approval and preserve an existing permanent ID/code.
create or replace function public.activate_patient_portal_after_approval()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $activate$
declare
  v_doctor_id uuid;
begin
  if new.status = 'approved' and old.status is distinct from new.status
     and new.patient_code is not null and new.portal_access_hash is not null then
    select u.id into v_doctor_id
    from auth.users u
    where u.raw_app_meta_data->>'role' = 'doctor'
    order by u.created_at asc
    limit 1;

    if v_doctor_id is null then
      raise exception 'Doctor account with doctor role was not found';
    end if;

    insert into public.patients(
      doctor_id,full_name,phone,patient_code,access_code_hash,
      access_code_ciphertext,portal_access_enabled,allergies,updated_at
    ) values (
      v_doctor_id,new.patient_name,new.phone,new.patient_code,new.portal_access_hash,
      new.portal_access_ciphertext,true,'',now()
    )
    on conflict(doctor_id,phone) do update set
      full_name = excluded.full_name,
      patient_code = case
        when public.patients.access_code_ciphertext is null then excluded.patient_code
        else public.patients.patient_code
      end,
      access_code_hash = case
        when public.patients.access_code_ciphertext is null then excluded.access_code_hash
        else public.patients.access_code_hash
      end,
      access_code_ciphertext = coalesce(public.patients.access_code_ciphertext,excluded.access_code_ciphertext),
      portal_access_enabled = true,
      portal_access_updated_at = now(),
      updated_at = now();

    update public.appointments set portal_access_enabled = true where id = new.id;
  end if;
  return new;
end;
$activate$;

drop trigger if exists trg_activate_patient_portal_after_approval on public.appointments;
create trigger trg_activate_patient_portal_after_approval
after update of status on public.appointments
for each row execute function public.activate_patient_portal_after_approval();

-- Doctor-only initial issue. It never replaces a retrievable permanent code.
-- Legacy hash-only records cannot be decrypted; this performs their one-time migration.
create or replace function public.doctor_initialize_patient_portal_code(p_patient_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $issue$
declare
  v_patient public.patients%rowtype;
  v_code text;
  v_key text;
  v_random bytea;
  v_i integer;
  v_alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
begin
  if auth.uid() is null or (auth.jwt()->'app_metadata'->>'role') <> 'doctor' then
    raise exception 'Doctor access required';
  end if;

  select * into v_patient
  from public.patients
  where id = p_patient_id and doctor_id = auth.uid()
  for update;

  if not found then
    raise exception 'Patient record not found for this doctor';
  end if;

  if v_patient.access_code_ciphertext is null then
    v_code := '';
    v_random := extensions.gen_random_bytes(7);
    for v_i in 0..6 loop
      v_code := v_code || substr(v_alphabet,(get_byte(v_random,v_i) % length(v_alphabet))+1,1);
    end loop;
    v_key := public._patient_portal_encryption_key();

    update public.patients
    set patient_code = coalesce(patient_code,public.generate_patient_portal_id()),
        access_code_hash = extensions.crypt(v_code,extensions.gen_salt('bf')),
        access_code_ciphertext = extensions.pgp_sym_encrypt(v_code,v_key),
        portal_access_enabled = true,
        portal_access_updated_at = now(),
        updated_at = now()
    where id = p_patient_id
    returning patient_code into v_patient.patient_code;

    return jsonb_build_object('patient_code',v_patient.patient_code,'access_code',v_code,'created',true);
  end if;

  v_key := public._patient_portal_encryption_key();
  v_code := extensions.pgp_sym_decrypt(v_patient.access_code_ciphertext,v_key);
  return jsonb_build_object('patient_code',v_patient.patient_code,'access_code',v_code,'created',false);
end;
$issue$;

revoke all on function public.doctor_initialize_patient_portal_code(uuid) from public;
grant execute on function public.doctor_initialize_patient_portal_code(uuid) to authenticated;

-- Staff-only read for the permanent credential. Never executable by anon.
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
begin
  v_role := auth.jwt()->'app_metadata'->>'role';
  if auth.uid() is null or v_role not in ('doctor','admin') then
    raise exception 'Doctor or admin access required';
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
    'access_code',extensions.pgp_sym_decrypt(v_cipher,v_key),
    'patient_name',v_name,
    'phone',v_phone
  );
end;
$staff$;

revoke all on function public.staff_get_patient_portal_credentials(text) from public, anon;
grant execute on function public.staff_get_patient_portal_credentials(text) to authenticated;

revoke all on function public.activate_patient_portal_after_approval() from public;
-- Remove the old reset-capable RPC so no dashboard/client can replace a saved code.
drop function if exists public.doctor_set_patient_portal_code(uuid,text);

revoke all on function public.prevent_patient_portal_credential_change() from public, anon, authenticated;
