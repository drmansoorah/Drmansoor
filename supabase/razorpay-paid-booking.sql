-- Razorpay-backed patient booking flow.
-- Apply AFTER clinic-frontdesk-workspace.sql, clinic-handoff-day-end.sql,
-- clinic-routing.sql and patient-portal.sql.
-- No appointment row is created until Razorpay payment is verified server-side.

create table if not exists public.appointment_payment_orders (
  id uuid primary key default gen_random_uuid(),
  razorpay_order_id text not null unique,
  razorpay_payment_id text unique,
  clinic_key text not null check (clinic_key in ('mansoor-private','gmc-anantnag','south-kashmir')),
  clinic_name text not null,
  patient_name text not null check (char_length(trim(patient_name)) between 2 and 100),
  phone text not null check (char_length(trim(phone)) between 10 and 25),
  appointment_date date not null,
  communication_consent boolean not null check (communication_consent = true),
  amount_paise integer not null check (amount_paise > 0),
  currency text not null default 'INR' check (currency = 'INR'),
  status text not null default 'pending' check (status in ('pending','paid','failed','expired')),
  payment_method text check (payment_method in ('upi','card','bank_transfer','other')),
  appointment_id uuid unique references public.appointments(id) on delete restrict,
  result jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  paid_at timestamptz
);

create index if not exists appointment_payment_orders_status_created_idx
  on public.appointment_payment_orders(status,created_at desc);

alter table public.appointment_payment_orders enable row level security;
revoke all on public.appointment_payment_orders from public, anon, authenticated;
grant all on public.appointment_payment_orders to service_role;

-- The old public RPC created appointments immediately, without payment.
-- Only trusted server-side Edge Functions may call it after payment verification.
revoke all on function public.request_patient_appointment(text,text,text,text,date,text,boolean)
  from public, anon, authenticated;
grant execute on function public.request_patient_appointment(text,text,text,text,date,text,boolean)
  to service_role;

create or replace function public.finalize_paid_appointment(
  p_razorpay_order_id text,
  p_razorpay_payment_id text,
  p_payment_method text,
  p_verified_amount_paise integer
) returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $finalize$
declare
  v_order public.appointment_payment_orders%rowtype;
  v_created jsonb;
  v_result jsonb;
  v_appointment_id uuid;
  v_amount numeric(10,2);
  v_method text;
begin
  if coalesce(auth.jwt()->>'role','') <> 'service_role' then
    raise exception 'Server-side verified payment is required';
  end if;
  if coalesce(trim(p_razorpay_order_id),'') = ''
     or coalesce(trim(p_razorpay_payment_id),'') = '' then
    raise exception 'Razorpay order and payment IDs are required';
  end if;
  if p_payment_method not in ('upi','card','bank_transfer','other') then
    raise exception 'Unsupported online payment method';
  end if;

  select * into v_order
  from public.appointment_payment_orders
  where razorpay_order_id = p_razorpay_order_id
  for update;

  if not found then
    raise exception 'Payment order was not found';
  end if;

  if v_order.status = 'paid' and v_order.result is not null then
    if v_order.razorpay_payment_id = p_razorpay_payment_id then
      return v_order.result;
    end if;
    raise exception 'This payment order has already been finalized with another payment';
  end if;
  if v_order.status <> 'pending' then
    raise exception 'This payment order is no longer pending';
  end if;
  if p_verified_amount_paise is null or p_verified_amount_paise <> v_order.amount_paise then
    raise exception 'Verified payment amount does not match the clinic fee';
  end if;

  v_amount := (v_order.amount_paise::numeric / 100)::numeric(10,2);
  v_method := p_payment_method;

  -- Concern is deliberately not collected. A clinic team member coordinates
  -- the consultation time after reviewing the paid booking.
  v_created := public.request_patient_appointment(
    v_order.patient_name,
    v_order.phone,
    v_order.clinic_key || '::' || v_order.clinic_name,
    'Not provided',
    v_order.appointment_date,
    'To be scheduled by clinic',
    true
  );
  v_appointment_id := (v_created->>'appointment_id')::uuid;

  update public.appointments
  set consultation_fee = v_amount,
      amount_paid = v_amount,
      payment_status = 'paid'
  where id = v_appointment_id;

  insert into public.clinic_appointment_payments(
    appointment_id, clinic_key, amount, payment_method, reference, narration
  ) values (
    v_appointment_id,
    v_order.clinic_key,
    v_amount,
    v_method,
    p_razorpay_payment_id,
    'Online payment captured via Razorpay'
  );

  v_result := v_created || jsonb_build_object(
    'status','pending',
    'payment_status','paid',
    'appointment_id',v_appointment_id,
    'clinic_key',v_order.clinic_key,
    'clinic_name',v_order.clinic_name,
    'appointment_date',v_order.appointment_date,
    'consultation_fee',v_amount,
    'amount_paid',v_amount,
    'currency','INR'
  );

  update public.appointment_payment_orders
  set status = 'paid',
      razorpay_payment_id = p_razorpay_payment_id,
      payment_method = v_method,
      appointment_id = v_appointment_id,
      result = v_result,
      paid_at = now(),
      updated_at = now()
  where id = v_order.id;

  return v_result;
end;
$finalize$;

revoke all on function public.finalize_paid_appointment(text,text,text,integer)
  from public, anon, authenticated;
grant execute on function public.finalize_paid_appointment(text,text,text,integer)
  to service_role;
