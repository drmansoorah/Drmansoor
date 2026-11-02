-- Clinic handoff, arrival, daily close-out and doctor remittance.
-- Run AFTER supabase/clinic-frontdesk-workspace.sql.
-- Doctor inbox receives booking/payment handoff only; no treatment details.

alter table public.appointments
  add column if not exists payment_skipped boolean not null default false,
  add column if not exists payment_skip_reason text,
  add column if not exists doctor_handoff_note text,
  add column if not exists visit_status text not null default 'scheduled',
  add column if not exists arrived_at timestamptz;

alter table public.appointments
  drop constraint if exists appointments_payment_status_check,
  add constraint appointments_payment_status_check
    check (payment_status in ('unpaid','partial','paid','skipped','not_required')),
  drop constraint if exists appointments_visit_status_check,
  add constraint appointments_visit_status_check
    check (visit_status in ('scheduled','arrived','completed','no_show'));

alter table public.clinic_appointment_payments
  add column if not exists narration text;

create table if not exists public.clinic_doctor_remittances (
  id uuid primary key default gen_random_uuid(),
  clinic_key text not null check (clinic_key in ('mansoor-private','gmc-anantnag','south-kashmir')),
  remittance_date date not null default (now() at time zone 'Asia/Kolkata')::date,
  amount numeric(10,2) not null check (amount > 0),
  transfer_method text not null check (transfer_method in ('cash','bank_transfer','other')),
  narration text not null,
  transferred_at timestamptz not null default now(),
  transferred_by uuid references auth.users(id)
);
create index if not exists clinic_doctor_remittances_day_idx
  on public.clinic_doctor_remittances(clinic_key,remittance_date,transferred_at desc);

alter table public.clinic_doctor_remittances enable row level security;
drop policy if exists "Clinic admins read their doctor remittances" on public.clinic_doctor_remittances;
create policy "Clinic admins read their doctor remittances"
on public.clinic_doctor_remittances for select to authenticated
using (
  (auth.jwt()->'app_metadata'->>'role') = 'admin'
  and (
    coalesce(nullif(auth.jwt()->'app_metadata'->>'clinic_key',''), '*') = '*'
    or clinic_key = auth.jwt()->'app_metadata'->>'clinic_key'
  )
);
grant select on public.clinic_doctor_remittances to authenticated;
revoke insert, update, delete on public.clinic_doctor_remittances from public, anon, authenticated;

-- Atomic handoff: capture today's collection/waiver/note and then send the
-- approved booking to the psychiatrist in one database transaction.
drop function if exists public.clinic_dispatch_appointment(uuid,text);
create or replace function public.clinic_dispatch_appointment(
  p_appointment_id uuid,
  p_doctor_name text default 'Prof. (Dr.) Mansoor Ahmad',
  p_collection_amount numeric default 0,
  p_payment_method text default null,
  p_payment_reference text default null,
  p_payment_narration text default null,
  p_skip_payment boolean default false,
  p_skip_reason text default null,
  p_handoff_note text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_role text := coalesce(auth.jwt()->'app_metadata'->>'role','');
  v_scope text := coalesce(nullif(auth.jwt()->'app_metadata'->>'clinic_key',''), '*');
  v_row public.appointments%rowtype;
  v_fee numeric(10,2);
  v_paid numeric(10,2);
  v_amount numeric(10,2) := coalesce(p_collection_amount,0);
  v_status text;
begin
  if auth.uid() is null or v_role <> 'admin' then
    raise exception 'Clinic admin access required';
  end if;
  if length(trim(coalesce(p_doctor_name,''))) < 3 or length(p_doctor_name) > 120 then
    raise exception 'Enter a valid doctor name';
  end if;
  if v_amount < 0 then
    raise exception 'Collection amount cannot be negative';
  end if;

  select * into v_row
  from public.appointments a
  where a.id = p_appointment_id
    and a.status = 'approved'
    and (v_scope = '*' or a.clinic_key = v_scope)
  for update;

  if not found then
    raise exception 'Approved appointment not found in your clinic';
  end if;
  if v_row.doctor_dispatch_status = 'sent' then
    raise exception 'This appointment has already been sent to the doctor';
  end if;

  v_fee := coalesce(nullif(v_row.consultation_fee,0),
    (select cs.consultation_fee from public.clinic_settings cs where cs.clinic_key=v_row.clinic_key),0);
  v_paid := coalesce(v_row.amount_paid,0);

  if p_skip_payment then
    if length(trim(coalesce(p_skip_reason,''))) < 5 then
      raise exception 'Enter why payment is being skipped (doctor recommendation, known patient, etc.)';
    end if;
    if v_amount <> 0 then
      raise exception 'When payment is skipped, current collection must be zero';
    end if;
    v_status := 'skipped';
  else
    if v_amount > 0 then
      if v_fee <= 0 then raise exception 'Set a consultation fee before recording collection'; end if;
      if v_amount > v_fee - v_paid then raise exception 'Collection exceeds remaining doctor fee balance'; end if;
      if p_payment_method not in ('cash','upi','card','bank_transfer','other') then
        raise exception 'Select a valid payment method';
      end if;
      insert into public.clinic_appointment_payments(
        appointment_id,clinic_key,amount,payment_method,reference,narration,collected_by
      ) values (
        p_appointment_id,v_row.clinic_key,v_amount,p_payment_method,
        nullif(trim(coalesce(p_payment_reference,'')),''),
        nullif(trim(coalesce(p_payment_narration,'')),''),
        auth.uid()
      );
      v_paid := v_paid + v_amount;
    elsif v_fee > v_paid then
      raise exception 'Enter amount received or select Payment skipped';
    end if;
    v_status := case
      when v_fee <= 0 then 'not_required'
      when v_paid >= v_fee then 'paid'
      when v_paid > 0 then 'partial'
      else 'unpaid'
    end;
  end if;

  update public.appointments
  set consultation_fee = v_fee,
      amount_paid = v_paid,
      payment_status = v_status,
      payment_skipped = p_skip_payment,
      payment_skip_reason = case when p_skip_payment then left(trim(p_skip_reason),300) else null end,
      doctor_handoff_note = nullif(left(trim(coalesce(p_handoff_note,'')),1000),''),
      doctor_dispatch_status = 'sent',
      assigned_doctor_name = trim(p_doctor_name),
      sent_to_doctor_at = now()
  where id = p_appointment_id;

  return jsonb_build_object(
    'appointment_id',p_appointment_id,
    'doctor_dispatch_status','sent',
    'assigned_doctor_name',trim(p_doctor_name),
    'consultation_fee',v_fee,
    'amount_paid',v_paid,
    'balance',greatest(v_fee-v_paid,0),
    'payment_status',v_status,
    'payment_skipped',p_skip_payment,
    'payment_skip_reason',case when p_skip_payment then left(trim(p_skip_reason),300) else null end
  );
end;
$fn$;

-- Later collection: append-only entry with collection method and narration.
drop function if exists public.clinic_record_payment(uuid,numeric,text,text);
create or replace function public.clinic_record_payment(
  p_appointment_id uuid,
  p_amount numeric,
  p_method text,
  p_reference text default null,
  p_narration text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_role text := coalesce(auth.jwt()->'app_metadata'->>'role','');
  v_scope text := coalesce(nullif(auth.jwt()->'app_metadata'->>'clinic_key',''), '*');
  v_row public.appointments%rowtype;
  v_paid numeric(10,2);
begin
  if auth.uid() is null or v_role <> 'admin' then raise exception 'Clinic admin access required'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Payment amount must be greater than zero'; end if;
  if p_method not in ('cash','upi','card','bank_transfer','other') then raise exception 'Select a valid method'; end if;

  select * into v_row from public.appointments a
  where a.id=p_appointment_id and a.status <> 'rejected'
    and (v_scope='*' or a.clinic_key=v_scope)
  for update;
  if not found then raise exception 'Appointment not found in your clinic'; end if;
  if v_row.payment_skipped then raise exception 'Payment was marked skipped for this appointment; contact the doctor before collecting'; end if;
  if p_amount > greatest(coalesce(v_row.consultation_fee,0)-coalesce(v_row.amount_paid,0),0) then
    raise exception 'Collection exceeds remaining fee balance';
  end if;

  insert into public.clinic_appointment_payments(
    appointment_id,clinic_key,amount,payment_method,reference,narration,collected_by
  ) values (
    p_appointment_id,v_row.clinic_key,p_amount,p_method,
    nullif(trim(coalesce(p_reference,'')),''),
    nullif(trim(coalesce(p_narration,'')),''),
    auth.uid()
  );

  v_paid := coalesce(v_row.amount_paid,0)+p_amount;
  update public.appointments
  set amount_paid=v_paid,
      payment_status=case when v_paid>=consultation_fee then 'paid' else 'partial' end
  where id=p_appointment_id;

  return jsonb_build_object('appointment_id',p_appointment_id,'amount_paid',v_paid,
    'balance',greatest(v_row.consultation_fee-v_paid,0),
    'payment_status',case when v_paid>=v_row.consultation_fee then 'paid' else 'partial' end);
end;
$fn$;

-- Mark an approved appointment as arrived when the patient presents at the clinic.
create or replace function public.clinic_mark_arrived(p_appointment_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_role text := coalesce(auth.jwt()->'app_metadata'->>'role','');
  v_scope text := coalesce(nullif(auth.jwt()->'app_metadata'->>'clinic_key',''), '*');
begin
  if auth.uid() is null or v_role <> 'admin' then raise exception 'Clinic admin access required'; end if;
  update public.appointments
  set visit_status='arrived',arrived_at=now()
  where id=p_appointment_id and status='approved'
    and doctor_dispatch_status='sent'
    and visit_status='scheduled'
    and (v_scope='*' or clinic_key=v_scope);
  if not found then raise exception 'Appointment is not awaiting arrival in your clinic'; end if;
  return true;
end;
$fn$;

-- End-of-day clinic report, using India local dates for payment timestamps.
create or replace function public.clinic_daily_summary(p_date date default (now() at time zone 'Asia/Kolkata')::date)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_role text := coalesce(auth.jwt()->'app_metadata'->>'role','');
  v_scope text := coalesce(nullif(auth.jwt()->'app_metadata'->>'clinic_key',''), '*');
  v_clinic text;
  v_arrived integer;
  v_completed integer;
  v_collected numeric(12,2);
  v_remitted numeric(12,2);
  v_methods jsonb;
begin
  if auth.uid() is null or v_role <> 'admin' then raise exception 'Clinic admin access required'; end if;
  v_clinic := case when v_scope='*' then null else v_scope end;

  select count(*) filter (where visit_status in ('arrived','completed')),
         count(*) filter (where visit_status='completed')
    into v_arrived,v_completed
  from public.appointments
  where appointment_date=p_date and (v_scope='*' or clinic_key=v_scope);

  select coalesce(sum(amount),0),
         coalesce(jsonb_object_agg(method,total), '{}'::jsonb)
  into v_collected,v_methods
  from (
    select payment_method as method,sum(amount)::numeric(12,2) as total
    from public.clinic_appointment_payments
    where (collected_at at time zone 'Asia/Kolkata')::date=p_date
      and (v_scope='*' or clinic_key=v_scope)
    group by payment_method
  ) x;

  select coalesce(sum(amount),0) into v_remitted
  from public.clinic_doctor_remittances
  where remittance_date=p_date and (v_scope='*' or clinic_key=v_scope);

  return jsonb_build_object(
    'date',p_date,'clinic_key',v_clinic,
    'patients_arrived',v_arrived,'patients_completed',v_completed,
    'total_collected',v_collected,'by_method',v_methods,
    'transferred_to_doctor',v_remitted,
    'available_to_transfer',greatest(v_collected-v_remitted,0)
  );
end;
$fn$;

-- Record cash / bank / other transfer to the doctor. Cannot transfer more
-- than this clinic's unremitted collections for the selected date.
create or replace function public.clinic_record_doctor_remittance(
  p_date date,
  p_amount numeric,
  p_method text,
  p_narration text
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_role text := coalesce(auth.jwt()->'app_metadata'->>'role','');
  v_scope text := coalesce(nullif(auth.jwt()->'app_metadata'->>'clinic_key',''), '*');
  v_collected numeric(12,2);
  v_remitted numeric(12,2);
begin
  if auth.uid() is null or v_role <> 'admin' then raise exception 'Clinic admin access required'; end if;
  if p_amount is null or p_amount<=0 then raise exception 'Enter a transfer amount greater than zero'; end if;
  if p_method not in ('cash','bank_transfer','other') then raise exception 'Select cash, bank transfer or other'; end if;
  if length(trim(coalesce(p_narration,'')))<3 then raise exception 'Enter a transfer narration'; end if;
  if v_scope='*' then raise exception 'Select one clinic to transfer that clinic collection'; end if;

  perform pg_advisory_xact_lock(hashtext(v_scope),hashtext(p_date::text));

  select coalesce(sum(amount),0) into v_collected
  from public.clinic_appointment_payments
  where clinic_key=v_scope and (collected_at at time zone 'Asia/Kolkata')::date=p_date;

  select coalesce(sum(amount),0) into v_remitted
  from public.clinic_doctor_remittances
  where clinic_key=v_scope and remittance_date=p_date;

  if p_amount > greatest(v_collected-v_remitted,0) then
    raise exception 'Transfer exceeds available unremitted collection';
  end if;

  insert into public.clinic_doctor_remittances(
    clinic_key,remittance_date,amount,transfer_method,narration,transferred_by
  ) values(v_scope,p_date,p_amount,p_method,left(trim(p_narration),1000),auth.uid());

  return jsonb_build_object('clinic_key',v_scope,'date',p_date,'amount',p_amount,
    'method',p_method,'transferred_to_doctor',v_remitted+p_amount,
    'available_to_transfer',v_collected-v_remitted-p_amount);
end;
$fn$;

-- Doctor-only inbox. This RPC intentionally returns no concern, diagnosis,
-- medicines, clinical notes or prescription content.
create or replace function public.doctor_get_dispatched_appointments()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_role text := coalesce(auth.jwt()->'app_metadata'->>'role','');
  v_scope text := coalesce(nullif(auth.jwt()->'app_metadata'->>'clinic_key',''), '*');
  v_rows jsonb;
begin
  if auth.uid() is null or not (
    v_role='doctor' or (v_role='admin' and v_scope='*')
  ) then raise exception 'Doctor or Master Admin access required'; end if;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id',a.id,'patient_name',a.patient_name,'phone',a.phone,'clinic',a.clinic,
      'clinic_key',a.clinic_key,'appointment_date',a.appointment_date,'slot',a.slot,
      'status',a.status,'patient_code',a.patient_code,'portal_access_enabled',a.portal_access_enabled,
      'created_at',a.created_at,'doctor_dispatch_status',a.doctor_dispatch_status,
      'assigned_doctor_name',a.assigned_doctor_name,'sent_to_doctor_at',a.sent_to_doctor_at,
      'consultation_fee',a.consultation_fee,'amount_paid',a.amount_paid,
      'balance',greatest(a.consultation_fee-a.amount_paid,0),'payment_status',a.payment_status,
      'payment_skipped',a.payment_skipped,'payment_skip_reason',a.payment_skip_reason,
      'doctor_handoff_note',a.doctor_handoff_note,'visit_status',a.visit_status,
      'payment_items',coalesce((
        select jsonb_agg(jsonb_build_object(
          'amount',p.amount,'payment_method',p.payment_method,'reference',p.reference,
          'narration',p.narration,'collected_at',p.collected_at
        ) order by p.collected_at)
        from public.clinic_appointment_payments p where p.appointment_id=a.id
      ),'[]'::jsonb)
    ) order by a.appointment_date desc,a.created_at desc
  ),'[]'::jsonb) into v_rows
  from public.appointments a
  where a.status='approved' and a.doctor_dispatch_status='sent';

  return v_rows;
end;
$fn$;

create or replace function public.doctor_get_clinic_remittances(p_date date default (now() at time zone 'Asia/Kolkata')::date)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_role text := coalesce(auth.jwt()->'app_metadata'->>'role','');
  v_scope text := coalesce(nullif(auth.jwt()->'app_metadata'->>'clinic_key',''), '*');
  v_rows jsonb;
begin
  if auth.uid() is null or not (v_role='doctor' or (v_role='admin' and v_scope='*')) then
    raise exception 'Doctor or Master Admin access required';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'clinic_key',r.clinic_key,'remittance_date',r.remittance_date,
    'amount',r.amount,'transfer_method',r.transfer_method,
    'narration',r.narration,'transferred_at',r.transferred_at
  ) order by r.transferred_at desc),'[]'::jsonb)
  into v_rows
  from public.clinic_doctor_remittances r
  where r.remittance_date=p_date;
  return v_rows;
end;
$fn$;

-- Permit the clinic UI to see only operational handoff columns, never concern/treatment.
revoke select on public.appointments from public, anon, authenticated;
grant select (
  id,patient_name,phone,clinic,clinic_key,appointment_date,slot,status,
  created_at,decision_at,notification_status,rejection_reason,
  doctor_dispatch_status,assigned_doctor_name,sent_to_doctor_at,
  consultation_fee,amount_paid,payment_status,
  transfer_from_clinic_key,transfer_reason,transferred_at,
  payment_skipped,payment_skip_reason,doctor_handoff_note,visit_status,arrived_at
) on public.appointments to authenticated;

revoke all on function public.clinic_dispatch_appointment(uuid,text,numeric,text,text,text,boolean,text,text) from public,anon;
revoke all on function public.clinic_record_payment(uuid,numeric,text,text,text) from public,anon;
revoke all on function public.clinic_mark_arrived(uuid) from public,anon;
revoke all on function public.clinic_daily_summary(date) from public,anon;
revoke all on function public.clinic_record_doctor_remittance(date,numeric,text,text) from public,anon;
revoke all on function public.doctor_get_dispatched_appointments() from public,anon;
revoke all on function public.doctor_get_clinic_remittances(date) from public,anon;

grant execute on function public.clinic_dispatch_appointment(uuid,text,numeric,text,text,text,boolean,text,text) to authenticated;
grant execute on function public.clinic_record_payment(uuid,numeric,text,text,text) to authenticated;
grant execute on function public.clinic_mark_arrived(uuid) to authenticated;
grant execute on function public.clinic_daily_summary(date) to authenticated;
grant execute on function public.clinic_record_doctor_remittance(date,numeric,text,text) to authenticated;
grant execute on function public.doctor_get_dispatched_appointments() to authenticated;
grant execute on function public.doctor_get_clinic_remittances(date) to authenticated;
