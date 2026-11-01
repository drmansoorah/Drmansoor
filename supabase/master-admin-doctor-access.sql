-- Allow only the unscoped Master Admin to use the Doctor Workspace.
-- Run AFTER clinic-routing.sql and permanent-patient-access.sql.
-- Clinic-scoped admin accounts remain excluded from patient and prescription records.

create policy "Master admin reads all patients"
on public.patients
for select
to authenticated
using (
  (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin'
  and coalesce(nullif(auth.jwt() -> 'app_metadata' ->> 'clinic_key', ''), '*') = '*'
);

create policy "Master admin creates own patients"
on public.patients
for insert
to authenticated
with check (
  (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin'
  and coalesce(nullif(auth.jwt() -> 'app_metadata' ->> 'clinic_key', ''), '*') = '*'
  and doctor_id = auth.uid()
);

create policy "Master admin updates all patients"
on public.patients
for update
to authenticated
using (
  (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin'
  and coalesce(nullif(auth.jwt() -> 'app_metadata' ->> 'clinic_key', ''), '*') = '*'
)
with check (
  (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin'
  and coalesce(nullif(auth.jwt() -> 'app_metadata' ->> 'clinic_key', ''), '*') = '*'
);

create policy "Master admin reads all prescriptions"
on public.prescriptions
for select
to authenticated
using (
  (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin'
  and coalesce(nullif(auth.jwt() -> 'app_metadata' ->> 'clinic_key', ''), '*') = '*'
);

create policy "Master admin creates prescriptions"
on public.prescriptions
for insert
to authenticated
with check (
  (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin'
  and coalesce(nullif(auth.jwt() -> 'app_metadata' ->> 'clinic_key', ''), '*') = '*'
  and exists (
    select 1 from public.patients pt
    where pt.id = patient_id
      and pt.doctor_id = prescriptions.doctor_id
  )
  and (
    appointment_id is null
    or exists (
      select 1 from public.appointments a
      where a.id = appointment_id and a.status = 'approved'
    )
  )
);

create policy "Master admin updates all prescriptions"
on public.prescriptions
for update
to authenticated
using (
  (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin'
  and coalesce(nullif(auth.jwt() -> 'app_metadata' ->> 'clinic_key', ''), '*') = '*'
)
with check (
  (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin'
  and coalesce(nullif(auth.jwt() -> 'app_metadata' ->> 'clinic_key', ''), '*') = '*'
  and exists (
    select 1 from public.patients pt
    where pt.id = patient_id
      and pt.doctor_id = prescriptions.doctor_id
  )
);

-- Master Admin may issue/view a permanent code for any patient in the clinical workspace.
-- Clinic-scoped admins are deliberately not permitted here.
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

revoke all on function public.doctor_initialize_patient_portal_code(uuid) from public;
grant execute on function public.doctor_initialize_patient_portal_code(uuid) to authenticated;
