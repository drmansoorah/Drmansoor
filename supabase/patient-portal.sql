-- Patient portal without SMS OTP.
-- Patients use Patient ID + date of birth + a private 16-character access code
-- issued by the doctor. Run AFTER doctor-portal.sql in Supabase SQL Editor.

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

alter table public.patients add column if not exists date_of_birth date;
alter table public.patients add column if not exists patient_code text;
alter table public.patients add column if not exists access_code_hash text;
alter table public.patients add column if not exists portal_access_enabled boolean not null default false;
alter table public.patients add column if not exists portal_access_updated_at timestamptz;

update public.patients
set patient_code = 'PT-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10))
where patient_code is null or trim(patient_code) = '';

alter table public.patients
  alter column patient_code set default ('PT-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10)));
alter table public.patients alter column patient_code set not null;

create unique index if not exists patients_patient_code_unique
on public.patients (patient_code);

-- Remove the older OTP-dependent lookup signature.
drop function if exists public.patient_portal_lookup(text, date);

-- Doctor creates or resets the patient's private portal access code.
-- Only the doctor who owns this patient record can set the code; only a bcrypt
-- hash is stored in the database. The plain code is shown once in the doctor UI.
create or replace function public.doctor_set_patient_portal_code(
  p_patient_id uuid,
  p_access_code text
)
returns boolean
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
begin
  if auth.uid() is null
     or (auth.jwt() -> 'app_metadata' ->> 'role') <> 'doctor' then
    raise exception 'Doctor access required';
  end if;

  if p_access_code is null or p_access_code !~ '^[A-Za-z0-9]{16}$' then
    raise exception 'Access code must be exactly 16 letters or numbers';
  end if;

  update public.patients
  set access_code_hash = crypt(p_access_code, gen_salt('bf')),
      portal_access_enabled = true,
      portal_access_updated_at = now(),
      updated_at = now()
  where id = p_patient_id
    and doctor_id = auth.uid();

  if not found then
    raise exception 'Patient record not found for this doctor';
  end if;

  return true;
end;
$$;

-- Public lookup returns patient data only when all three values match:
-- Patient ID, date of birth, and the private high-entropy access code.
-- The RPC is security-definer; base tables are never made public.
create or replace function public.patient_portal_lookup(
  p_patient_code text,
  p_date_of_birth date,
  p_access_code text
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_patient public.patients%rowtype;
  v_prescriptions jsonb;
begin
  if p_patient_code is null
     or p_date_of_birth is null
     or p_access_code is null
     or p_access_code !~ '^[A-Za-z0-9]{16}$' then
    return jsonb_build_object(
      'patient', null,
      'prescriptions', '[]'::jsonb,
      'message', 'The details did not match. Check your Patient ID, date of birth and private access code.'
    );
  end if;

  select p.* into v_patient
  from public.patients p
  where upper(p.patient_code) = upper(trim(p_patient_code))
    and p.date_of_birth = p_date_of_birth
    and p.portal_access_enabled = true
    and p.access_code_hash is not null
    and crypt(p_access_code, p.access_code_hash) = p.access_code_hash
  limit 1;

  if not found then
    return jsonb_build_object(
      'patient', null,
      'prescriptions', '[]'::jsonb,
      'message', 'The details did not match. Check your Patient ID, date of birth and private access code.'
    );
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', r.id,
        'diagnosis', r.diagnosis,
        'complaints', r.complaints,
        'medicines', r.medicines,
        'medication_items', r.medication_items,
        'advice', r.advice,
        'clinical_notes', r.clinical_notes,
        'vitals', r.vitals,
        'follow_up_date', r.follow_up_date,
        'created_at', r.created_at
      ) order by r.created_at desc
    ),
    '[]'::jsonb
  )
  into v_prescriptions
  from public.prescriptions r
  where r.patient_id = v_patient.id
    and r.doctor_id = v_patient.doctor_id;

  return jsonb_build_object(
    'patient', jsonb_build_object(
      'patient_code', v_patient.patient_code,
      'full_name', v_patient.full_name,
      'phone', v_patient.phone,
      'date_of_birth', v_patient.date_of_birth,
      'age', v_patient.age,
      'gender', v_patient.gender,
      'allergies', v_patient.allergies
    ),
    'prescriptions', v_prescriptions
  );
end;
$$;

revoke all on function public.doctor_set_patient_portal_code(uuid, text) from public;
grant execute on function public.doctor_set_patient_portal_code(uuid, text) to authenticated;

revoke all on function public.patient_portal_lookup(text, date, text) from public;
grant execute on function public.patient_portal_lookup(text, date, text) to anon, authenticated;
