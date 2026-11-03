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
-- Name: appointment_request_update
-- Language: English (en)
-- Body should use exactly four BODY placeholders matching Meta:
-- Hello *{{1}}*,
--
-- Your appointment request at *{{2}}* on *{{3}}* during *{{4}}*
-- could not be approved.
--
-- We regret the inconvenience. Please contact the clinic desk to discuss
-- another available date or time.
--
-- Thank you.
--
-- Variables: {{1}} patient name; {{2}} clinic name; {{3}} appointment date;
-- {{4}} appointment time slot. Rejection reason is not sent in this template.
-- The patient booking form requires appointment-related communication consent.
