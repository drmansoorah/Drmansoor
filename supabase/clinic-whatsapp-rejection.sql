-- Idempotency log for patient WhatsApp rejection notifications.
-- Run this once in Supabase SQL Editor before deploying clinic-patient-whatsapp-rejection.

create table if not exists public.clinic_whatsapp_rejection_log (
  id uuid primary key default gen_random_uuid(),
  appointment_id uuid not null unique
    references public.appointments(id) on delete restrict,
  clinic_key text not null,
  recipient_last4 text not null check (recipient_last4 ~ '^[0-9]{4}$'),
  template_name text not null,
  status text not null default 'pending'
    check (status in ('pending','sent','failed')),
  provider_message_id text,
  error_message text,
  sent_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists clinic_whatsapp_rejection_log_clinic_time_idx
  on public.clinic_whatsapp_rejection_log(clinic_key,created_at desc);

alter table public.clinic_whatsapp_rejection_log enable row level security;
revoke all on public.clinic_whatsapp_rejection_log from public, anon, authenticated;
grant all on public.clinic_whatsapp_rejection_log to service_role;

-- In Meta WhatsApp Manager, create and get APPROVED Utility template:
-- Name: appointment_rejection_with_reason
-- Language: English (en)
-- Body:
-- Hello *{{1}}*,
--
-- We are sorry, but your appointment request at *{{2}}* for *{{3}}* could not be accepted.
--
-- Reason: *{{4}}*
--
-- For assistance or to request another appointment, please contact the clinic desk at *{{5}}*.
--
-- Thank you.
--
-- Variables: {{1}} patient name; {{2}} clinic name; {{3}} appointment date;
-- {{4}} rejection reason; {{5}} clinic desk phone number.
-- The patient booking form requires appointment-related communication consent.
