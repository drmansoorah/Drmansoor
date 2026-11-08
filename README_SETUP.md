# Clinic appointment system (Supabase + admin approval + SMS + WhatsApp)

This package updates the existing single-file clinic website and adds a separate admin dashboard. It is **not connected to a live Supabase project yet**; configure your own project and provider credentials before publishing.

## Files
- `index.html` — existing clinic website with appointment requests saved to Supabase.
- `config.js` — browser-safe Supabase project URL and anon key placeholders only.
- `admin.html` — password login, pending/approved/rejected lists, approval/rejection actions.
- `supabase/schema.sql` — table, indexes and row-level security policies.
- `supabase/functions/appointment-decision/index.ts` — protected Edge Function; admin-only decisions and notification dispatch.
- `.env.example` — server-side secrets checklist.

## 1) Create Supabase project
1. Create a project at https://supabase.com/.
2. In Project Settings → API, copy the Project URL and anon/public key.
3. Edit `config.js` and replace `YOUR_PROJECT_ID` and `YOUR_SUPABASE_ANON_KEY`.
4. Open SQL Editor and run `supabase/schema.sql`.
5. In Authentication settings, enable Email/Password. Create the clinic admin user in Authentication → Users.
6. Grant admin role to that user using SQL Editor (replace the email):

```sql
UPDATE auth.users
SET raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb) || '{"role":"admin"}'::jsonb
WHERE email = 'admin@example.com';
```

Sign out and sign in again after granting the role so the new JWT contains `app_metadata.role = admin`. Do not grant this role to patient accounts.

## 2) Configure and deploy the Edge Function
Install the Supabase CLI and log in, then from this package directory:

```bash
supabase login
supabase link --project-ref YOUR_PROJECT_REF
supabase secrets set ALLOWED_ORIGIN=https://YOUR_PUBLIC_SITE_DOMAIN
supabase functions deploy appointment-decision
```

Supabase injects its project URL and default API keys into Edge Functions. Set only your application/provider secrets through the CLI or Supabase Dashboard. **Never put the service-role/secret key or messaging provider tokens in `config.js`, HTML, Git, or any public folder.** Keep the Edge Function JWT verification enabled; it additionally checks the signed user's server-managed app metadata role.

## 3) SMS setup (MSG91)
1. Configure MSG91 account, sender/route, and DLT registration/templates as required for Indian messaging.
2. Create approved confirmation and rejection Flow templates. Templates should accept the variables `VAR1` patient name, `VAR2` date, `VAR3` slot, `VAR4` clinic, `VAR5` status.
3. Set server-side secrets:

```bash
supabase secrets set MSG91_AUTH_KEY=YOUR_MSG91_AUTH_KEY
supabase secrets set MSG91_TEMPLATE_APPROVED=YOUR_APPROVED_FLOW_TEMPLATE_ID
supabase secrets set MSG91_TEMPLATE_REJECTED=YOUR_REJECTED_FLOW_TEMPLATE_ID
```

Check the MSG91 response/logs and adjust the payload variable names if your particular Flow template uses a different schema. A `sent` response means the provider accepted the request, not guaranteed handset delivery.

## 4) WhatsApp setup (Meta WhatsApp Cloud API)
1. Configure a Meta Business app, WhatsApp Business phone number, and approved message templates.
2. Templates configured below must have four body variables in this order: patient name, date, slot, clinic. Use separate approved template names for approval and rejection. Ensure the patient has opted in.
3. Set secrets:

```bash
supabase secrets set WHATSAPP_ACCESS_TOKEN=YOUR_LONG_LIVED_TOKEN
supabase secrets set WHATSAPP_PHONE_NUMBER_ID=YOUR_PHONE_NUMBER_ID
supabase secrets set WHATSAPP_TEMPLATE_APPROVED=appointment_confirmation
supabase secrets set WHATSAPP_TEMPLATE_REJECTED=appointment_request_update
supabase secrets set WHATSAPP_TEMPLATE_LANGUAGE=en
supabase secrets set WHATSAPP_API_VERSION=v22.0
```

Use a supported Graph API version for your Meta app. WhatsApp business-initiated notifications generally require an approved template and valid opt-in. Provider policy/template approvals are your responsibility.

## 5) Publish the site
Upload `index.html`, `config.js`, and `admin.html` together to a static host (Netlify, Vercel, etc.). The admin URL will be `https://YOUR_DOMAIN/admin.html`. Keep all files in the same site root so the relative `config.js` path works. HTTPS is required for production.

## How it behaves
- A patient request is inserted with `status = pending` and can only be inserted as pending through the public browser key.
- Patients cannot read existing records. Admin reads are protected by RLS and the `app_metadata.role = admin` claim.
- The admin decision Edge Function verifies the signed-in user and admin role on the server. It changes the status once, then attempts SMS and WhatsApp messages.
- If a provider is unconfigured or fails, the appointment status still changes but the dashboard shows notification status so staff can follow up manually.
- The form does not save free-text medical history. It stores the selected concern category; avoid collecting unnecessary sensitive health data.

## Before going live
- Verify doctor identity, clinic details, actual schedules, helpline numbers, and permission to publish this website.
- Test a dummy request, admin login, approval, rejection, SMS and WhatsApp with your own test number first.
- Add CAPTCHA/rate limiting before broad public launch; the public insert policy is intentionally limited by RLS but is not an anti-spam system.
- Review applicable Indian privacy/data-protection requirements and provider terms. Do not describe this as HIPAA compliant.
- The UI says `Pending` after submission; it must not promise an appointment is confirmed until a staff member approves it.

## Clinic front-desk workflow and doctor confidentiality

Clinic accounts use `admin.html` only. They manage appointments, approval/rejection reasons, clinic consultation fees, payment collection, transfers between clinics, patient arrival, daily collection summaries and remittance to the doctor. Clinic accounts do **not** receive patient diagnoses, clinical concerns, medication lists, therapy notes, prescription history or portal access codes.

After the earlier `clinic-routing.sql` and `doctor-clinic-workspace.sql` migrations have been applied, run these two SQL files in order from Supabase SQL Editor:

1. `supabase/clinic-frontdesk-workspace.sql`
2. `supabase/clinic-handoff-day-end.sql`

Do not run the deprecated `supabase/clinic-clinician-workspace.sql` migration. It is retained only as a compatibility cleanup for an earlier experimental version and does not grant clinical chart access.

### Appointment handoff

A clinic admin approves a pending appointment. The dashboard then opens the handoff form. Before sending it to the doctor, the clinic records the amount collected, payment method, optional reference/narration and a non-clinical note for the doctor. If payment is waived, the clinic must select a reason such as doctor recommendation, known patient, emergency or fee exemption. A red `PAYMENT SKIPPED` notice appears in the Doctor Workspace.

### Daily close-out

Mark a sent appointment as `Arrived` when the patient presents. The daily close-out panel counts arrivals and payments collected on the selected India-local date. The clinic can record an amount transferred to the doctor by cash, bank transfer or other method with a narration. The database prevents recording a transfer greater than that day's unremitted collections. The Doctor Workspace displays the remittance records.

The daily report and payment/remittance ledger are operational records; they are not a receipt gateway or bank reconciliation. Actual receipt, transfer and bank settlement must still be verified by the clinic.

### Patient WhatsApp message when an appointment is rejected

When an admin rejects an appointment, the dashboard may save the rejection reason for the clinic's internal record. If the existing `appointment-decision` notification response does not report a WhatsApp send as successful, the dashboard invokes `clinic-patient-whatsapp-rejection`. The rejection function checks that the appointment is rejected, the patient has `communication_consent = true`, and the admin is assigned to the clinic. The WhatsApp template does not include the rejection reason; sending it does not depend on a saved reason.

1. Run `supabase/clinic-whatsapp-rejection.sql` in Supabase SQL Editor once.
2. In Meta WhatsApp Manager, use the approved **Utility** template named `appointment_request_update`, language `English (en)`, with four BODY variables matching the approved template shown in WhatsApp Manager:

```text
Hello *{{1}}*,

Your appointment request at *{{2}}* on *{{3}}* during *{{4}}* could not be approved.

We regret the inconvenience. Please contact the clinic desk to discuss another available date or time.

Thank you.
```

Variables: `{{1}}` patient name; `{{2}}` clinic name; `{{3}}` appointment date; `{{4}}` appointment time slot. The rejection reason is not inserted into this template and is not required for the WhatsApp send.

3. Set the Supabase Edge Function secret `WHATSAPP_TEMPLATE_REJECTED=appointment_request_update`. The existing Meta access token, phone number ID, language and API version are reused.
4. Deploy both functions:

```bash
supabase functions deploy clinic-patient-whatsapp-rejection --project-ref zzxehneqvnmprlwcohkv
supabase functions deploy clinic-patient-whatsapp --project-ref zzxehneqvnmprlwcohkv
```

The rejection function does not send if the patient has not consented to appointment-related messages. It stores a per-appointment send log so a successfully accepted rejection message is not sent twice. Meta acceptance is not a delivery receipt; check WhatsApp Manager for final delivery status.

### Patient WhatsApp message when sent to Doctor

After the clinic submits `Collect Fee & Send to Doctor`, the handoff form has a separate checkbox to confirm the patient's appointment-related WhatsApp consent. Tick it only after confirming the patient agreed to these updates. The appointment is still sent to Doctor if the box is left unticked; no WhatsApp message is sent in that case.

1. Run `supabase/clinic-whatsapp-handoff.sql` in Supabase SQL Editor after `clinic-handoff-day-end.sql`.
2. In Meta WhatsApp Manager, create and obtain approval for a **Utility** template named `appointment_confirmation`, language `English (en)`, with this exact body and four positional variables:

```text
Hello *{{1}}*,

Your appointment at *{{2}}* on (*{{3}}*) has been approved by *Prof. (Dr.) Mansoor Ahmad*.

*Please note:* This appointment is subject to payment of the applicable doctor's consultation fee. Kindly contact the clinic desk (*{{4}}*) for fee details before your visit.

Thank you.
```

Variables: `{{1}}` patient name; `{{2}}` clinic name; `{{3}}` appointment date; `{{4}}` clinic desk phone. Appointment timing is intentionally not included in this version of the template.

3. Add server-side Supabase Edge Function secrets (never put the Meta token in `config.js`, HTML, or Git):

```bash
supabase secrets set --project-ref zzxehneqvnmprlwcohkv \
  WHATSAPP_ACCESS_TOKEN=YOUR_LONG_LIVED_META_TOKEN \
  WHATSAPP_PHONE_NUMBER_ID=YOUR_META_PHONE_NUMBER_ID \
  WHATSAPP_TEMPLATE_HANDOFF=appointment_confirmation \
  WHATSAPP_TEMPLATE_LANGUAGE=en \
  WHATSAPP_API_VERSION=v26.0 \
  CLINIC_PHONE_MANSOOR_PRIVATE="+91 9906927006" \
  ALLOWED_ORIGIN=https://drmansoor.vercel.app
```

For GMC Anantnag and South Kashmir, also configure `CLINIC_PHONE_GMC_ANANTNAG` and `CLINIC_PHONE_SOUTH_KASHMIR` with their verified clinic desk numbers. Those contact numbers are not currently configured, so the Edge Function will stop before sending for those clinics until their real numbers are supplied.

Supabase injects `SUPABASE_URL` and its default API keys into Edge Functions automatically. The WhatsApp function supports both the legacy `SUPABASE_ANON_KEY` / `SUPABASE_SERVICE_ROLE_KEY` variables and the newer `SUPABASE_PUBLISHABLE_KEYS` / `SUPABASE_SECRET_KEYS` JSON collections. Do not try to add custom secrets whose names start with `SUPABASE_`; keep all secret/service keys server-side.

4. Deploy the Edge Function from the repository root:

```bash
supabase functions deploy clinic-patient-whatsapp --project-ref zzxehneqvnmprlwcohkv
```

The function verifies the signed-in clinic-admin JWT and clinic scope, reads only the patient's name, clinic, appointment date and clinic desk phone, and sends the approved Meta template to the patient's WhatsApp number. It does not send concern, diagnosis, medicines, fee amounts, or prescription details. A unique per-appointment send log prevents duplicate successful messages. Failed sends can be retried after correcting the Meta configuration.

The dashboard reports whether Meta accepted the template request. Provider acceptance is **not** proof of handset delivery; check WhatsApp Manager/webhook delivery status for final delivery. Template approval, valid patient opt-in, Meta business verification and messaging limits remain provider-side requirements.
