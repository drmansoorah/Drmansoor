-- DEPRECATED: do not run this migration.
-- Clinic accounts are front-desk only. They must not read patient charts,
-- diagnoses, prescriptions, medication lists, therapy notes or patient portal codes.
-- Use clinic-frontdesk-workspace.sql followed by clinic-handoff-day-end.sql.
-- This compatibility script only removes policies from an earlier experimental
-- build that allowed clinic-scoped admins to access clinical records.

drop policy if exists "Clinic clinicians read assigned patients" on public.patients;
drop policy if exists "Clinic clinicians create assigned patients" on public.patients;
drop policy if exists "Clinic clinicians update assigned patients" on public.patients;
drop policy if exists "Clinic clinicians read assigned prescriptions" on public.prescriptions;
drop policy if exists "Clinic clinicians create assigned prescriptions" on public.prescriptions;
drop policy if exists "Clinic clinicians update assigned prescriptions" on public.prescriptions;

-- Patient portal credential RPCs must be callable only by their own function
-- checks for Doctor or unscoped Master Admin. Never grant clinic-specific chart access.
revoke all on function public.doctor_initialize_patient_portal_code(uuid) from public, anon;
revoke all on function public.staff_get_patient_portal_credentials(text) from public, anon;
grant execute on function public.doctor_initialize_patient_portal_code(uuid) to authenticated;
grant execute on function public.staff_get_patient_portal_credentials(text) to authenticated;
