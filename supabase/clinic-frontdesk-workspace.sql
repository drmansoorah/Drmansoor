-- Clinic Front Desk Workspace (non-clinical).
-- Apply this migration once in Supabase SQL Editor.
-- Clinic accounts can manage bookings, routing, fees and payments only.
-- Diagnosis, medicines, therapy notes and prescription records remain doctor-only.

alter table public.prescriptions
  add column if not exists clinic_key text;

update public.prescriptions r
set clinic_key = p.clinic_key
from public.patients p
where r.patient_id = p.id and r.clinic_key is null and p.clinic_key is not null;

update public.prescriptions r
set clinic_key = a.clinic_key
from public.appointments a
where r.appointment_id = a.id and r.clinic_key is null and a.clinic_key is not null;

create index if not exists prescriptions_clinic_key_idx on public.prescriptions(clinic_key, created_at desc);

alter table public.appointments
  add column if not exists rejection_reason text,
  add column if not exists doctor_dispatch_status text not null default 'not_sent',
  add column if not exists assigned_doctor_name text,
  add column if not exists sent_to_doctor_at timestamptz,
  add column if not exists consultation_fee numeric(10,2) not null default 0,
  add column if not exists amount_paid numeric(10,2) not null default 0,
  add column if not exists payment_status text not null default 'unpaid',
  add column if not exists transfer_from_clinic_key text,
  add column if not exists transfer_reason text,
  add column if not exists transferred_at timestamptz,
  add column if not exists transferred_by uuid references auth.users(id);

alter table public.appointments
  drop constraint if exists appointments_consultation_fee_nonnegative,
  drop constraint if exists appointments_amount_paid_nonnegative,
  drop constraint if exists appointments_doctor_dispatch_status_check,
  add constraint appointments_doctor_dispatch_status_check
    check (doctor_dispatch_status in ('not_sent','sent')),
  drop constraint if exists appointments_payment_status_check,
  add constraint appointments_payment_status_check
    check (payment_status in ('unpaid','partial','paid'));

alter table public.appointments
  add constraint appointments_consultation_fee_nonnegative
  check (consultation_fee >= 0),
  add constraint appointments_amount_paid_nonnegative
  check (amount_paid >= 0);

create table if not exists public.clinic_settings (
  clinic_key text primary key check (clinic_key in ('mansoor-private','gmc-anantnag','south-kashmir')),
  consultation_fee numeric(10,2) not null default 0 check (consultation_fee >= 0),
  currency text not null default 'INR' check (currency = 'INR'),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id)
);

insert into public.clinic_settings(clinic_key, consultation_fee)
values ('mansoor-private',0),('gmc-anantnag',0),('south-kashmir',0)
on conflict (clinic_key) do nothing;

-- Snapshot the clinic's default doctor fee on every new appointment.
-- Trigger name sorts after the existing route trigger so clinic_key is known.
create or replace function public.set_new_appointment_clinic_fee()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $fee$
begin
  if coalesce(new.consultation_fee,0) = 0 and new.clinic_key is not null then
    select consultation_fee into new.consultation_fee
    from public.clinic_settings
    where clinic_key = new.clinic_key;
    new.consultation_fee := coalesce(new.consultation_fee,0);
  end if;
  return new;
end;
$fee$;

drop trigger if exists trg_set_new_appointment_clinic_fee on public.appointments;
create trigger trg_set_new_appointment_clinic_fee
before insert on public.appointments
for each row execute function public.set_new_appointment_clinic_fee();

create table if not exists public.clinic_appointment_payments (
  id uuid primary key default gen_random_uuid(),
  appointment_id uuid not null references public.appointments(id) on delete restrict,
  clinic_key text not null check (clinic_key in ('mansoor-private','gmc-anantnag','south-kashmir')),
  amount numeric(10,2) not null check (amount > 0),
  payment_method text not null check (payment_method in ('cash','upi','card','bank_transfer','other')),
  reference text,
  collected_at timestamptz not null default now(),
  collected_by uuid references auth.users(id)
);
create index if not exists clinic_appointment_payments_clinic_time_idx
  on public.clinic_appointment_payments(clinic_key, collected_at desc);
create index if not exists clinic_appointment_payments_appointment_idx
  on public.clinic_appointment_payments(appointment_id, collected_at desc);

create table if not exists public.clinic_transfer_events (
  id uuid primary key default gen_random_uuid(),
  appointment_id uuid not null references public.appointments(id) on delete restrict,
  from_clinic_key text not null,
  to_clinic_key text not null,
  reason text not null,
  transferred_at timestamptz not null default now(),
  transferred_by uuid references auth.users(id)
);
create index if not exists clinic_transfer_events_appointment_idx
  on public.clinic_transfer_events(appointment_id, transferred_at desc);

alter table public.clinic_settings enable row level security;
alter table public.clinic_appointment_payments enable row level security;
alter table public.clinic_transfer_events enable row level security;

drop policy if exists "Clinic users read their own settings" on public.clinic_settings;
create policy "Clinic users read their own settings"
on public.clinic_settings for select to authenticated
using (
  (auth.jwt()->'app_metadata'->>'role') = 'admin'
  and (
    coalesce(nullif(auth.jwt()->'app_metadata'->>'clinic_key',''), '*') = '*'
    or clinic_key = auth.jwt()->'app_metadata'->>'clinic_key'
  )
);

drop policy if exists "Clinic users read payment records in scope" on public.clinic_appointment_payments;
create policy "Clinic users read payment records in scope"
on public.clinic_appointment_payments for select to authenticated
using (
  (auth.jwt()->'app_metadata'->>'role') = 'admin'
  and (
    coalesce(nullif(auth.jwt()->'app_metadata'->>'clinic_key',''), '*') = '*'
    or clinic_key = auth.jwt()->'app_metadata'->>'clinic_key'
  )
);

drop policy if exists "Clinic users read transfer records in scope" on public.clinic_transfer_events;
create policy "Clinic users read transfer records in scope"
on public.clinic_transfer_events for select to authenticated
using (
  (auth.jwt()->'app_metadata'->>'role') = 'admin'
  and (
    coalesce(nullif(auth.jwt()->'app_metadata'->>'clinic_key',''), '*') = '*'
    or from_clinic_key = auth.jwt()->'app_metadata'->>'clinic_key'
    or to_clinic_key = auth.jwt()->'app_metadata'->>'clinic_key'
  )
);

revoke select on public.clinic_settings, public.clinic_appointment_payments, public.clinic_transfer_events from public, anon, authenticated;
grant select (clinic_key,consultation_fee,currency,updated_at) on public.clinic_settings to authenticated;
grant select (id,appointment_id,clinic_key,amount,payment_method,reference,narration,collected_at) on public.clinic_appointment_payments to authenticated;
grant select (id,appointment_id,from_clinic_key,to_clinic_key,reason,transferred_at) on public.clinic_transfer_events to authenticated;
revoke insert, update, delete on public.clinic_settings, public.clinic_appointment_payments, public.clinic_transfer_events from anon, authenticated;

-- Restore strict clinical privacy even if the earlier experimental clinic-clinician
-- workspace migration was applied. Clinic admins must never read treatment records.
drop policy if exists "Clinic clinicians read assigned patients" on public.patients;
drop policy if exists "Clinic clinicians create assigned patients" on public.patients;
drop policy if exists "Clinic clinicians update assigned patients" on public.patients;
drop policy if exists "Clinic clinicians read assigned prescriptions" on public.prescriptions;
drop policy if exists "Clinic clinicians create assigned prescriptions" on public.prescriptions;
drop policy if exists "Clinic clinicians update assigned prescriptions" on public.prescriptions;

-- Prevent direct row reads of free-text clinical concern and portal secrets by all
-- authenticated front-desk accounts. The doctor portal uses only the operational
-- appointment fields listed below; all patient access-code operations use RPCs.
revoke select on public.appointments from public, anon, authenticated;
grant select (
  id, patient_name, phone, clinic, clinic_key, appointment_date, slot, status,
  created_at, decision_at, notification_status,
  rejection_reason, doctor_dispatch_status, assigned_doctor_name, sent_to_doctor_at,
  consultation_fee, amount_paid, payment_status, transfer_from_clinic_key,
  transfer_reason, transferred_at
) on public.appointments to authenticated;

-- Save a rejection explanation before the existing notification function is called.
create or replace function public.clinic_save_rejection_reason(
  p_appointment_id uuid,
  p_reason text
) returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_role text := coalesce(auth.jwt()->'app_metadata'->>'role','');
  v_scope text := coalesce(nullif(auth.jwt()->'app_metadata'->>'clinic_key',''), '*');
begin
  if auth.uid() is null or v_role <> 'admin' then
    raise exception 'Clinic admin access required';
  end if;
  if length(trim(coalesce(p_reason,''))) < 5 then
    raise exception 'Please enter a rejection reason (at least 5 characters)';
  end if;

  update public.appointments
  set rejection_reason = left(trim(p_reason),500)
  where id = p_appointment_id
    and status = 'pending'
    and (v_scope = '*' or clinic_key = v_scope);

  if not found then
    raise exception 'Pending appointment not found in your clinic';
  end if;
  return true;
end;
$fn$;

-- Server-side appointment decision fallback. The browser first attempts the
-- configured notification Edge Function; if it is unavailable, this RPC still
-- records the approval/rejection and runs the existing database approval trigger.
create or replace function public.clinic_decide_appointment(
  p_appointment_id uuid,
  p_action text,
  p_reason text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_role text := coalesce(auth.jwt()->'app_metadata'->>'role','');
  v_scope text := coalesce(nullif(auth.jwt()->'app_metadata'->>'clinic_key',''), '*');
  v_row public.appointments%rowtype;
  v_target text;
begin
  if auth.uid() is null or v_role <> 'admin' then
    raise exception 'Clinic admin access required';
  end if;
  if p_action not in ('approve','reject') then
    raise exception 'Unsupported appointment decision';
  end if;
  if p_action = 'reject' and length(trim(coalesce(p_reason,''))) < 5 then
    raise exception 'A rejection reason of at least 5 characters is required';
  end if;

  select * into v_row
  from public.appointments a
  where a.id = p_appointment_id
    and (v_scope = '*' or a.clinic_key = v_scope)
  for update;

  if not found then
    raise exception 'Appointment not found in your clinic';
  end if;

  v_target := case when p_action = 'approve' then 'approved' else 'rejected' end;

  if v_row.status = v_target then
    return jsonb_build_object('appointment_id',v_row.id,'status',v_row.status,'already_decided',true);
  end if;
  if v_row.status <> 'pending' then
    raise exception 'Only pending appointments can be approved or rejected';
  end if;

  if p_action = 'approve' then
    update public.appointments a
    set status = 'approved',
        decision_at = now(),
        consultation_fee = case
          when coalesce(a.consultation_fee,0) = 0
            then coalesce((select cs.consultation_fee from public.clinic_settings cs where cs.clinic_key = a.clinic_key),0)
          else a.consultation_fee
        end
    where a.id = p_appointment_id;
  else
    update public.appointments
    set status = 'rejected',
        decision_at = now(),
        rejection_reason = left(trim(p_reason),500)
    where id = p_appointment_id;
  end if;

  return jsonb_build_object('appointment_id',p_appointment_id,'status',v_target,'already_decided',false);
end;
$fn$;

-- Assign an approved appointment to the psychiatrist's work queue.
create or replace function public.clinic_dispatch_appointment(
  p_appointment_id uuid,
  p_doctor_name text default 'Prof. (Dr.) Mansoor Ahmad'
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_role text := coalesce(auth.jwt()->'app_metadata'->>'role','');
  v_scope text := coalesce(nullif(auth.jwt()->'app_metadata'->>'clinic_key',''), '*');
  v_row public.appointments%rowtype;
begin
  if auth.uid() is null or v_role <> 'admin' then
    raise exception 'Clinic admin access required';
  end if;
  if length(trim(coalesce(p_doctor_name,''))) < 3 or length(p_doctor_name) > 120 then
    raise exception 'Enter a valid doctor name';
  end if;

  update public.appointments a
  set doctor_dispatch_status = 'sent',
      assigned_doctor_name = trim(p_doctor_name),
      sent_to_doctor_at = now(),
      consultation_fee = case
        when coalesce(a.consultation_fee,0) = 0
          then coalesce((select s.consultation_fee from public.clinic_settings s where s.clinic_key = a.clinic_key),0)
        else a.consultation_fee
      end
  where a.id = p_appointment_id
    and a.status = 'approved'
    and (v_scope = '*' or a.clinic_key = v_scope)
  returning a.* into v_row;

  if not found then
    raise exception 'Approved appointment not found in your clinic';
  end if;

  return jsonb_build_object(
    'appointment_id',v_row.id,
    'doctor_dispatch_status',v_row.doctor_dispatch_status,
    'assigned_doctor_name',v_row.assigned_doctor_name,
    'consultation_fee',v_row.consultation_fee
  );
end;
$fn$;

-- Set the default doctor consultation fee for one clinic (not a staff salary).
create or replace function public.clinic_set_default_fee(
  p_clinic_key text,
  p_fee numeric
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_role text := coalesce(auth.jwt()->'app_metadata'->>'role','');
  v_scope text := coalesce(nullif(auth.jwt()->'app_metadata'->>'clinic_key',''), '*');
  v_row public.clinic_settings%rowtype;
begin
  if auth.uid() is null or v_role <> 'admin' then
    raise exception 'Clinic admin access required';
  end if;
  if p_clinic_key not in ('mansoor-private','gmc-anantnag','south-kashmir')
     or (v_scope <> '*' and p_clinic_key <> v_scope) then
    raise exception 'You can manage fees only for your assigned clinic';
  end if;
  if p_fee is null or p_fee < 0 or p_fee > 1000000 then
    raise exception 'Enter a valid fee between 0 and 1000000';
  end if;

  insert into public.clinic_settings(clinic_key,consultation_fee,updated_at,updated_by)
  values(p_clinic_key,p_fee,now(),auth.uid())
  on conflict(clinic_key) do update
    set consultation_fee = excluded.consultation_fee,
        updated_at = now(),
        updated_by = auth.uid()
  returning * into v_row;

  return jsonb_build_object('clinic_key',v_row.clinic_key,'consultation_fee',v_row.consultation_fee,'currency',v_row.currency);
end;
$fn$;

-- Record a payment in an append-only ledger and keep the appointment balance in sync.
create or replace function public.clinic_record_payment(
  p_appointment_id uuid,
  p_amount numeric,
  p_method text,
  p_reference text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_role text := coalesce(auth.jwt()->'app_metadata'->>'role','');
  v_scope text := coalesce(nullif(auth.jwt()->'app_metadata'->>'clinic_key',''), '*');
  v_row public.appointments%rowtype;
  v_new_paid numeric(10,2);
  v_new_status text;
begin
  if auth.uid() is null or v_role <> 'admin' then
    raise exception 'Clinic admin access required';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'Payment amount must be greater than zero';
  end if;
  if p_method not in ('cash','upi','card','bank_transfer','other') then
    raise exception 'Select a valid payment method';
  end if;

  select * into v_row
  from public.appointments a
  where a.id = p_appointment_id
    and a.status <> 'rejected'
    and (v_scope = '*' or a.clinic_key = v_scope)
  for update;

  if not found then
    raise exception 'Appointment not found in your clinic or already rejected';
  end if;

  if coalesce(v_row.consultation_fee,0) = 0 then
    update public.appointments a
    set consultation_fee = coalesce((select s.consultation_fee from public.clinic_settings s where s.clinic_key = a.clinic_key),0)
    where a.id = p_appointment_id
    returning * into v_row;
  end if;

  if coalesce(v_row.consultation_fee,0) <= 0 then
    raise exception 'Set the doctor consultation fee before recording payment';
  end if;

  v_new_paid := coalesce(v_row.amount_paid,0) + p_amount;
  if v_new_paid > v_row.consultation_fee then
    raise exception 'Payment exceeds the remaining balance';
  end if;
  v_new_status := case
    when v_new_paid >= v_row.consultation_fee then 'paid'
    when v_new_paid > 0 then 'partial'
    else 'unpaid'
  end;

  insert into public.clinic_appointment_payments(
    appointment_id,clinic_key,amount,payment_method,reference,collected_by
  ) values (
    p_appointment_id,v_row.clinic_key,p_amount,p_method,nullif(trim(coalesce(p_reference,'')),''),
    auth.uid()
  );

  update public.appointments
  set amount_paid = v_new_paid,
      payment_status = v_new_status
  where id = p_appointment_id;

  return jsonb_build_object(
    'appointment_id',p_appointment_id,
    'consultation_fee',v_row.consultation_fee,
    'amount_paid',v_new_paid,
    'balance',v_row.consultation_fee-v_new_paid,
    'payment_status',v_new_status
  );
end;
$fn$;

-- Transfer the booking to another clinic; keep a reason and immutable audit row.
-- The receiving clinic inherits only booking, fee and payment information.
create or replace function public.clinic_transfer_appointment(
  p_appointment_id uuid,
  p_target_clinic_key text,
  p_reason text
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_role text := coalesce(auth.jwt()->'app_metadata'->>'role','');
  v_scope text := coalesce(nullif(auth.jwt()->'app_metadata'->>'clinic_key',''), '*');
  v_from text;
  v_name text;
begin
  if auth.uid() is null or v_role <> 'admin' then
    raise exception 'Clinic admin access required';
  end if;
  if p_target_clinic_key not in ('mansoor-private','gmc-anantnag','south-kashmir') then
    raise exception 'Select a valid receiving clinic';
  end if;
  if length(trim(coalesce(p_reason,''))) < 5 then
    raise exception 'Please enter a transfer reason (at least 5 characters)';
  end if;

  select clinic_key into v_from
  from public.appointments
  where id = p_appointment_id
    and (v_scope = '*' or clinic_key = v_scope)
  for update;

  if not found then
    raise exception 'Appointment not found in your clinic';
  end if;
  if v_from = p_target_clinic_key then
    raise exception 'Select a different clinic for transfer';
  end if;

  select case p_target_clinic_key
    when 'mansoor-private' then 'Mansoor Psychiatry & MindCare Clinic'
    when 'gmc-anantnag' then 'GMC Anantnag Associated Hospital'
    else 'South Kashmir Mental Wellness Centre'
  end into v_name;

  insert into public.clinic_transfer_events(appointment_id,from_clinic_key,to_clinic_key,reason,transferred_by)
  values(p_appointment_id,v_from,p_target_clinic_key,left(trim(p_reason),500),auth.uid());

  update public.appointments
  set clinic_key = p_target_clinic_key,
      clinic = p_target_clinic_key || '::' || v_name,
      consultation_fee = case
        when coalesce(amount_paid,0) = 0
          then coalesce((select s.consultation_fee from public.clinic_settings s where s.clinic_key = p_target_clinic_key),consultation_fee)
        else consultation_fee
      end,
      transfer_from_clinic_key = v_from,
      transfer_reason = left(trim(p_reason),500),
      transferred_at = now(),
      transferred_by = auth.uid(),
      doctor_dispatch_status = 'not_sent',
      assigned_doctor_name = null,
      sent_to_doctor_at = null
  where id = p_appointment_id;

  return jsonb_build_object(
    'appointment_id',p_appointment_id,
    'from_clinic_key',v_from,
    'to_clinic_key',p_target_clinic_key
  );
end;
$fn$;

-- Restore patient portal credential RPCs to Doctor / unscoped Master Admin only.
-- Clinic-scoped administrators must not reveal or issue patient access codes.
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
  ) then
    raise exception 'Doctor or Master Admin access required';
  end if;

  select * into v_patient
  from public.patients
  where id = p_patient_id
    and (
      (v_role = 'doctor' and doctor_id = auth.uid())
      or (v_role = 'admin' and v_clinic_key = '*')
    )
  for update;

  if not found then
    raise exception 'Patient record not found or access denied';
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

create or replace function public.staff_get_patient_portal_credentials(p_patient_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $staff$
declare
  v_role text;
  v_admin_clinic text;
  v_cipher bytea;
  v_code text := upper(trim(coalesce(p_patient_code,'')));
  v_key text;
  v_name text;
  v_phone text;
begin
  v_role := coalesce(auth.jwt()->'app_metadata'->>'role','');
  v_admin_clinic := coalesce(nullif(auth.jwt()->'app_metadata'->>'clinic_key',''), '*');

  if auth.uid() is null or not (
    v_role = 'doctor'
    or (v_role = 'admin' and v_admin_clinic = '*')
  ) then
    raise exception 'Doctor or Master Admin access required';
  end if;

  if v_role = 'doctor' then
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
    return jsonb_build_object('patient_code',v_code,'access_code',null,'message','Patient record not found.');
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

revoke all on function public.doctor_initialize_patient_portal_code(uuid) from public, anon;
revoke all on function public.staff_get_patient_portal_credentials(text) from public, anon;
grant execute on function public.doctor_initialize_patient_portal_code(uuid) to authenticated;
grant execute on function public.staff_get_patient_portal_credentials(text) to authenticated;

revoke all on function public.clinic_save_rejection_reason(uuid,text) from public, anon;
revoke all on function public.clinic_decide_appointment(uuid,text,text) from public, anon;
revoke all on function public.clinic_dispatch_appointment(uuid,text) from public, anon;
revoke all on function public.clinic_set_default_fee(text,numeric) from public, anon;
revoke all on function public.clinic_record_payment(uuid,numeric,text,text) from public, anon;
revoke all on function public.clinic_transfer_appointment(uuid,text,text) from public, anon;
grant execute on function public.clinic_save_rejection_reason(uuid,text) to authenticated;
grant execute on function public.clinic_decide_appointment(uuid,text,text) to authenticated;
grant execute on function public.clinic_dispatch_appointment(uuid,text) to authenticated;
grant execute on function public.clinic_set_default_fee(text,numeric) to authenticated;
grant execute on function public.clinic_record_payment(uuid,numeric,text,text) to authenticated;
grant execute on function public.clinic_transfer_appointment(uuid,text,text) to authenticated;
