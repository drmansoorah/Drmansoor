-- Patient WhatsApp confirmation after clinic sends an approved appointment to Doctor.
-- Run this migration in Supabase SQL Editor before deploying the Edge Function.
-- The Edge Function uses service-role access only; clinic users cannot read or edit this log.

create table if not exists public.clinic_whatsapp_handoff_log (
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

create index if not exists clinic_whatsapp_handoff_log_clinic_time_idx
  on public.clinic_whatsapp_handoff_log(clinic_key,created_at desc);

alter table public.clinic_whatsapp_handoff_log enable row level security;
revoke all on public.clinic_whatsapp_handoff_log from public, anon, authenticated;
grant all on public.clinic_whatsapp_handoff_log to service_role;

-- In Meta WhatsApp Manager, create and get APPROVED utility template:
-- Name: appointment_forwarded_to_doctor
-- Language: English (en)
-- Category: Utility
-- Body (8 positional variables):
-- Hello {{1}},
-- Your appointment at {{2}} on {{3}} ({{4}}) has been approved and forwarded to Dr. Mansoor.
-- Consultation fee: {{5}}
-- Amount received: {{6}}
-- Payment mode: {{7}}
-- Payment status: {{8}}
-- For queries, please contact your clinic desk.
-- Clinic Team
--
-- The website booking form already requires appointment-related SMS/WhatsApp consent.
-- The clinic handoff screen also asks staff to confirm consent before sending.
