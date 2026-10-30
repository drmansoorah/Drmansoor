-- Patient Portal: sequential DRMAD IDs + 7-character MindCare access codes.
-- No date of birth and no SMS OTP.
-- Run AFTER supabase/doctor-portal.sql in Supabase SQL Editor.

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

alter table public.appointments add column if not exists patient_code text;
alter table public.appointments add column if not exists portal_access_hash text;
alter table public.appointments add column if not exists portal_access_enabled boolean not null default false;
alter table public.appointments add column if not exists portal_access_issued_at timestamptz;

alter table public.patients add column if not exists patient_code text;
alter table public.patients add column if not exists access_code_hash text;
alter table public.patients add column if not exists portal_access_enabled boolean not null default false;
alter table public.patients add column if not exists portal_access_updated_at timestamptz;

-- Sequential patient ID generator. Example: DRMAD001, DRMAD002, DRMAD003...
create sequence if not exists public.patient_portal_id_seq start with 1;
do $$
declare
 v_max bigint;
begin
 select greatest(
   coalesce((select max(substring(patient_code from '^DRMAD([0-9]+)$')::bigint)
             from public.patients where patient_code ~ '^DRMAD[0-9]+$'),0),
   coalesce((select max(substring(patient_code from '^DRMAD([0-9]+)$')::bigint)
             from public.appointments where patient_code ~ '^DRMAD[0-9]+$'),0)
 ) into v_max;
 if v_max > 0 then
   perform setval('public.patient_portal_id_seq',v_max,true);
 else
   perform setval('public.patient_portal_id_seq',1,false);
 end if;
end $$;

-- Central ID generator: DRMAD001 ... DRMAD999, then DRMAD1000 and onward.
create or replace function public.generate_patient_portal_id()
returns text
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare v_id bigint;
begin
 v_id:=nextval('public.patient_portal_id_seq');
 return 'DRMAD' || case when v_id<1000 then lpad(v_id::text,3,'0') else v_id::text end;
end;
$$;
revoke all on function public.generate_patient_portal_id() from public;
grant execute on function public.generate_patient_portal_id() to authenticated;

-- Migrate existing PT-... IDs to the new DRMAD### format.
with ids as (
 select id, public.generate_patient_portal_id() as new_code
 from public.patients
 where patient_code is null or patient_code !~ '^DRMAD[0-9]+$'
)
update public.patients p set patient_code=ids.new_code
from ids where p.id=ids.id;

with ids as (
 select id, public.generate_patient_portal_id() as new_code
 from public.appointments
 where patient_code is null or patient_code !~ '^DRMAD[0-9]+$'
)
update public.appointments a set patient_code=ids.new_code
from ids where a.id=ids.id;

-- Walk-in patients added from Doctor Dashboard use the same DRMAD sequence.
alter table public.patients alter column patient_code
set default public.generate_patient_portal_id();

create unique index if not exists patients_patient_code_unique on public.patients(patient_code);
create unique index if not exists appointments_patient_code_unique
on public.appointments(patient_code) where patient_code is not null;

-- Track failed lookups per Patient ID. Five wrong attempts lock that ID for 15 minutes.
create table if not exists public.patient_portal_access_attempts (
 patient_code text primary key,
 window_started_at timestamptz not null default now(),
 attempt_count integer not null default 0,
 locked_until timestamptz
);
alter table public.patient_portal_access_attempts enable row level security;
revoke all on public.patient_portal_access_attempts from public, anon, authenticated;

drop function if exists public.patient_portal_lookup(text, date);
drop function if exists public.patient_portal_lookup(text, date, text);
drop function if exists public.patient_portal_lookup(text, text);

-- Creates a pending appointment and returns the Patient ID + 7-character code once.
-- Only a bcrypt hash of the code is stored in the database.
create or replace function public.request_patient_appointment(
 p_patient_name text,p_phone text,p_clinic text,p_concern text,
 p_appointment_date date,p_slot text,p_communication_consent boolean
)
returns jsonb language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare
 v_patient_code text;
 v_access_code text := '';
 v_alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
 v_random bytea;
 v_hash text;
 v_appointment_id uuid;
 v_i integer;
begin
 if coalesce(length(trim(p_patient_name)),0)<2 or length(trim(p_patient_name))>100 then
  raise exception 'Please enter a valid patient name';
 end if;
 if coalesce(length(trim(p_phone)),0)<10 or length(trim(p_phone))>25
    or length(regexp_replace(p_phone,'[^0-9]','','g'))<10 then
  raise exception 'Please enter a valid contact number';
 end if;
 if coalesce(length(trim(p_clinic)),0)<3 or coalesce(length(trim(p_concern)),0)<3
    or coalesce(length(trim(p_slot)),0)<3 then
  raise exception 'Please complete all appointment fields';
 end if;
 if p_appointment_date is null or p_appointment_date<current_date then
  raise exception 'Please select today or a future appointment date';
 end if;
 if p_communication_consent is distinct from true then
  raise exception 'Appointment communication consent is required';
 end if;

 v_random:=gen_random_bytes(7);
 for v_i in 0..6 loop
  v_access_code:=v_access_code||substr(v_alphabet,(get_byte(v_random,v_i)%length(v_alphabet))+1,1);
 end loop;
 v_patient_code:=public.generate_patient_portal_id();
 v_hash:=crypt(v_access_code,gen_salt('bf'));

 insert into public.appointments(
  patient_name,phone,clinic,concern,appointment_date,slot,
  communication_consent,status,patient_code,portal_access_hash,
  portal_access_enabled,portal_access_issued_at
 ) values (
  trim(p_patient_name),trim(p_phone),trim(p_clinic),trim(p_concern),p_appointment_date,trim(p_slot),
  true,'pending',v_patient_code,v_hash,false,now()
 ) returning id into v_appointment_id;

 return jsonb_build_object(
  'appointment_id',v_appointment_id,
  'patient_code',v_patient_code,
  'portal_access_code',v_access_code,
  'status','pending',
  'portal_access_enabled',false
 );
end;
$$;

revoke all on function public.request_patient_appointment(text,text,text,text,date,text,boolean) from public;
grant execute on function public.request_patient_appointment(text,text,text,text,date,text,boolean) to anon,authenticated;

-- Only clinician approval activates the issued credentials and creates the patient row.
create or replace function public.activate_patient_portal_after_approval()
returns trigger language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare v_doctor_id uuid;
begin
 if new.status='approved' and old.status is distinct from new.status
    and new.patient_code is not null and new.portal_access_hash is not null then
  select u.id into v_doctor_id from auth.users u
  where u.raw_app_meta_data->>'role'='doctor'
  order by u.created_at asc limit 1;
  if v_doctor_id is null then raise exception 'Doctor account with doctor role was not found'; end if;

  insert into public.patients(
   doctor_id,full_name,phone,patient_code,access_code_hash,portal_access_enabled,allergies,updated_at
  ) values (
   v_doctor_id,new.patient_name,new.phone,new.patient_code,new.portal_access_hash,true,'',now()
  )
  on conflict(doctor_id,phone) do update set
   full_name=excluded.full_name,patient_code=excluded.patient_code,
   access_code_hash=excluded.access_code_hash,portal_access_enabled=true,
   portal_access_updated_at=now(),updated_at=now();

  update public.appointments set portal_access_enabled=true where id=new.id;
 end if;
 return new;
end;
$$;

drop trigger if exists trg_activate_patient_portal_after_approval on public.appointments;
create trigger trg_activate_patient_portal_after_approval
after update of status on public.appointments
for each row execute function public.activate_patient_portal_after_approval();

-- Doctors can issue/reset a 7-character MindCare code for walk-in patients.
create or replace function public.doctor_set_patient_portal_code(p_patient_id uuid,p_access_code text)
returns boolean language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
begin
 if auth.uid() is null or (auth.jwt()->'app_metadata'->>'role')<>'doctor' then
  raise exception 'Doctor access required';
 end if;
 if p_access_code is null or p_access_code !~ '^[A-Z0-9]{7}$' then
  raise exception 'MindCare access code must be exactly 7 uppercase letters or numbers';
 end if;
 update public.patients set access_code_hash=crypt(p_access_code,gen_salt('bf')),
  portal_access_enabled=true,portal_access_updated_at=now(),updated_at=now()
 where id=p_patient_id and doctor_id=auth.uid();
 if not found then raise exception 'Patient record not found for this doctor'; end if;
 return true;
end;
$$;

-- Patient lookup: Patient ID + 7-character code. Five failed attempts per ID
-- are allowed in a 15-minute window; further attempts are paused for 15 minutes.
create or replace function public.patient_portal_lookup(p_patient_code text,p_access_code text)
returns jsonb language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare
 v_patient public.patients%rowtype;
 v_prescriptions jsonb;
 v_key text;
 v_attempt public.patient_portal_access_attempts%rowtype;
 v_new_count integer;
begin
 v_key:=upper(trim(coalesce(p_patient_code,'')));
 if v_key='' or p_access_code is null or p_access_code !~ '^[A-Z0-9]{7}$' then
  return jsonb_build_object('patient',null,'prescriptions','[]'::jsonb,
   'message','Patient ID or 7-character MindCare code is incorrect, or the appointment is awaiting clinician approval.');
 end if;

 insert into public.patient_portal_access_attempts(patient_code)
 values(v_key) on conflict(patient_code) do nothing;

 select * into v_attempt from public.patient_portal_access_attempts
 where patient_code=v_key for update;

 if v_attempt.locked_until is not null and v_attempt.locked_until>now() then
  return jsonb_build_object('patient',null,'prescriptions','[]'::jsonb,
   'message','Too many incorrect attempts. Please try again after 15 minutes or contact the clinic.');
 end if;

 select p.* into v_patient from public.patients p
 where upper(p.patient_code)=v_key and p.portal_access_enabled=true
  and p.access_code_hash is not null
 limit 1;

 if not found or crypt(p_access_code,coalesce(v_patient.access_code_hash,'!'))<>coalesce(v_patient.access_code_hash,'!') then
  if v_attempt.window_started_at < now()-interval '15 minutes' then
   v_new_count:=1;
   update public.patient_portal_access_attempts
    set window_started_at=now(),attempt_count=1,locked_until=null
    where patient_code=v_key;
  else
   v_new_count:=v_attempt.attempt_count+1;
   update public.patient_portal_access_attempts
    set attempt_count=v_new_count,
        locked_until=case when v_new_count>=5 then now()+interval '15 minutes' else null end
    where patient_code=v_key;
  end if;
  return jsonb_build_object('patient',null,'prescriptions','[]'::jsonb,
   'message','Patient ID or MindCare code did not match, or the appointment is awaiting clinician approval.');
 end if;

 update public.patient_portal_access_attempts set attempt_count=0,locked_until=null,window_started_at=now()
 where patient_code=v_key;

 select coalesce(jsonb_agg(jsonb_build_object(
  'id',r.id,'diagnosis',r.diagnosis,'complaints',r.complaints,'medicines',r.medicines,
  'medication_items',r.medication_items,'advice',r.advice,'clinical_notes',r.clinical_notes,
  'vitals',r.vitals,'follow_up_date',r.follow_up_date,'created_at',r.created_at
 ) order by r.created_at desc),'[]'::jsonb)
 into v_prescriptions from public.prescriptions r
 where r.patient_id=v_patient.id and r.doctor_id=v_patient.doctor_id;

 return jsonb_build_object('patient',jsonb_build_object(
  'patient_code',v_patient.patient_code,'full_name',v_patient.full_name,'phone',v_patient.phone,
  'age',v_patient.age,'gender',v_patient.gender,'allergies',v_patient.allergies
 ),'prescriptions',v_prescriptions);
end;
$$;

revoke all on function public.activate_patient_portal_after_approval() from public;
revoke all on function public.doctor_set_patient_portal_code(uuid,text) from public;
grant execute on function public.doctor_set_patient_portal_code(uuid,text) to authenticated;
revoke all on function public.patient_portal_lookup(text,text) from public;
grant execute on function public.patient_portal_lookup(text,text) to anon,authenticated;
