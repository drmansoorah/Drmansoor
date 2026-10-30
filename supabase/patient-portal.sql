-- Patient portal access: phone OTP + Patient ID + date of birth.
-- Run AFTER doctor-portal.sql in Supabase SQL Editor.

alter table public.patients add column if not exists date_of_birth date;
alter table public.patients add column if not exists patient_code text;

update public.patients
set patient_code = 'PT-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10))
where patient_code is null or trim(patient_code) = '';

alter table public.patients
  alter column patient_code set default ('PT-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10)));
alter table public.patients alter column patient_code set not null;

create unique index if not exists patients_patient_code_unique
on public.patients (patient_code);

-- A verified phone OTP is mandatory. Patient ID and DOB are checked together
-- inside this SECURITY DEFINER function; base tables remain protected by RLS.
create or replace function public.patient_portal_lookup(
  p_patient_code text,
  p_date_of_birth date
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_phone text;
  v_patient public.patients%rowtype;
  v_prescriptions jsonb;
begin
  if auth.uid() is null then
    raise exception 'Please verify your mobile number first';
  end if;

  v_phone := right(regexp_replace(coalesce(auth.jwt() ->> 'phone', ''), '[^0-9]', '', 'g'), 10);
  if length(coalesce(v_phone, '')) <> 10 then
    raise exception 'Verified mobile number is not available in this session';
  end if;

  select p.* into v_patient
  from public.patients p
  where upper(p.patient_code) = upper(trim(p_patient_code))
    and p.date_of_birth = p_date_of_birth
    and right(regexp_replace(coalesce(p.phone, ''), '[^0-9]', '', 'g'), 10) = v_phone
  limit 1;

  if not found then
    return jsonb_build_object(
      'patient', null,
      'prescriptions', '[]'::jsonb,
      'message', 'No matching patient record found. Check the Patient ID and date of birth, or contact the clinic.'
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

revoke all on function public.patient_portal_lookup(text, date) from public;
grant execute on function public.patient_portal_lookup(text, date) to authenticated;
