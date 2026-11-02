-- Clinic-wise Doctor Workspace: store clinic association on patient records.
-- Run AFTER clinic-routing.sql and permanent-patient-access.sql.
-- Existing appointment and prescription history is retained.

alter table public.patients
  add column if not exists clinic_key text;

-- Backfill each existing patient from their most recent appointment, matching phone.
update public.patients p
set clinic_key = matched.clinic_key
from lateral (
  select a.clinic_key
  from public.appointments a
  where regexp_replace(coalesce(a.phone,''),'[^0-9]','','g')
      = regexp_replace(coalesce(p.phone,''),'[^0-9]','','g')
    and a.clinic_key is not null
  order by a.created_at desc
  limit 1
) as matched
where p.clinic_key is null
  and regexp_replace(coalesce(p.phone,''),'[^0-9]','','g') <> '';

create index if not exists patients_clinic_created_idx
  on public.patients(clinic_key, created_at desc);

create index if not exists patients_clinic_phone_idx
  on public.patients(clinic_key, phone);

-- New clinic-approved patients are assigned to the clinic that handled their booking.
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
      doctor_id,clinic_key,full_name,phone,patient_code,access_code_hash,
      access_code_ciphertext,portal_access_enabled,allergies,updated_at
    ) values (
      v_doctor_id,new.clinic_key,new.patient_name,new.phone,new.patient_code,new.portal_access_hash,
      new.portal_access_ciphertext,true,'',now()
    )
    on conflict(doctor_id,phone) do update set
      clinic_key = coalesce(excluded.clinic_key,public.patients.clinic_key),
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

-- Preserve the existing doctor/admin RLS rules; add no public access.
grant select, insert, update on public.patients to authenticated;
