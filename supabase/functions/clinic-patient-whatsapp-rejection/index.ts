import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": Deno.env.get("ALLOWED_ORIGIN") || "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

function respond(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), { status, headers: corsHeaders });
}

function normalizePhone(value: string): string {
  let digits = String(value || "").replace(/\D/g, "");
  if (digits.length === 10) digits = "91" + digits;
  else if (digits.length === 11 && digits.startsWith("0")) digits = "91" + digits.slice(1);
  if (digits.length < 10 || digits.length > 15) {
    throw new Error("Patient WhatsApp number is invalid.");
  }
  return digits;
}

function displayClinic(value: unknown): string {
  const raw = String(value || "Clinic");
  return raw.includes("::") ? raw.split("::").slice(1).join("::") : raw;
}

function keyFromCollection(name: string): string {
  const raw = Deno.env.get(name) || "";
  if (!raw) return "";
  try {
    const parsed = JSON.parse(raw);
    return typeof parsed?.default === "string" ? parsed.default : "";
  } catch {
    return "";
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return respond(405, { error: "Method not allowed." });

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ||
      Deno.env.get("SUPABASE_PUBLISHABLE_KEY") ||
      keyFromCollection("SUPABASE_PUBLISHABLE_KEYS");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ||
      Deno.env.get("SUPABASE_SECRET_KEY") ||
      keyFromCollection("SUPABASE_SECRET_KEYS");

    const waToken = Deno.env.get("WHATSAPP_ACCESS_TOKEN") || "";
    const phoneNumberId = Deno.env.get("WHATSAPP_PHONE_NUMBER_ID") || "";
    // Create/approve this template in Meta WhatsApp Manager before sending.
    const templateName = Deno.env.get("WHATSAPP_TEMPLATE_REJECTED") ||
      "appointment_request_update";
    const language = Deno.env.get("WHATSAPP_TEMPLATE_LANGUAGE") || "en";
    const apiVersion = Deno.env.get("WHATSAPP_API_VERSION") || "v26.0";

    if (!supabaseUrl || !anonKey || !serviceRoleKey) {
      return respond(500, { error: "Supabase Edge Function keys are unavailable." });
    }
    if (!waToken || !phoneNumberId) {
      return respond(503, { error: "WhatsApp Cloud API token or Phone Number ID is not configured." });
    }
    if (!/^v\d+\.0$/.test(apiVersion)) {
      return respond(500, { error: "WHATSAPP_API_VERSION must look like v26.0." });
    }

    const authorization = req.headers.get("Authorization") || "";
    if (!authorization.startsWith("Bearer ")) {
      return respond(401, { error: "Sign in to the clinic admin account first." });
    }

    const authClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authorization } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: authData, error: authError } = await authClient.auth.getUser();
    const user = authData?.user;
    if (authError || !user) return respond(401, { error: "Your login session is invalid. Sign in again." });

    const metadata = user.app_metadata || {};
    if (metadata.role !== "admin") {
      return respond(403, { error: "Clinic admin access is required." });
    }
    const clinicScope = String(metadata.clinic_key || "*");

    const body = await req.json().catch(() => ({}));
    const appointmentId = String(body.appointment_id || "");
    if (!appointmentId) return respond(400, { error: "appointment_id is required." });

    const admin = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const { data: appointment, error: appointmentError } = await admin
      .from("appointments")
      .select("id,patient_name,phone,clinic,clinic_key,appointment_date,status,rejection_reason,communication_consent")
      .eq("id", appointmentId)
      .maybeSingle();

    if (appointmentError) throw new Error("Could not load rejected appointment: " + appointmentError.message);
    if (!appointment) return respond(404, { error: "Appointment not found." });
    if (clinicScope !== "*" && appointment.clinic_key !== clinicScope) {
      return respond(403, { error: "This appointment is outside your assigned clinic." });
    }
    if (appointment.status !== "rejected") {
      return respond(409, { error: "The appointment must be rejected before the rejection message is sent." });
    }
    if (appointment.communication_consent !== true) {
      return respond(200, {
        ok: true,
        skipped: true,
        message: "No WhatsApp sent because appointment communication consent is not recorded.",
      });
    }

    const reason = String(appointment.rejection_reason || "").trim();
    if (reason.length < 5) {
      return respond(409, { error: "A saved rejection reason is required before sending WhatsApp." });
    }

    const recipient = normalizePhone(appointment.phone || "");
    const clinicName = displayClinic(appointment.clinic).slice(0, 120);
    const { data: existing, error: existingError } = await admin
      .from("clinic_whatsapp_rejection_log")
      .select("id,status,provider_message_id")
      .eq("appointment_id", appointment.id)
      .maybeSingle();

    if (existingError) {
      throw new Error("WhatsApp rejection log is unavailable. Run clinic-whatsapp-rejection.sql first. " + existingError.message);
    }
    if (existing?.status === "sent") {
      return respond(200, {
        ok: true,
        already_sent: true,
        message: "Rejection WhatsApp was already accepted by Meta.",
      });
    }
    if (existing?.status === "pending") {
      return respond(409, { error: "A rejection WhatsApp send is already in progress. Check the send log before retrying." });
    }

    const values = [
      String(appointment.patient_name || "Patient").slice(0, 100),
      clinicName,
      String(appointment.appointment_date || "To be confirmed"),
      reason.slice(0, 500),
    ];

    let logId: string;
    if (existing?.id) {
      const { data: updated, error: updateError } = await admin
        .from("clinic_whatsapp_rejection_log")
        .update({
          status: "pending",
          error_message: null,
          template_name: templateName,
          recipient_last4: recipient.slice(-4),
          sent_by: user.id,
          updated_at: new Date().toISOString(),
        })
        .eq("id", existing.id)
        .select("id")
        .single();
      if (updateError) throw new Error("Could not retry the failed rejection message: " + updateError.message);
      logId = updated.id;
    } else {
      const { data: inserted, error: insertError } = await admin
        .from("clinic_whatsapp_rejection_log")
        .insert({
          appointment_id: appointment.id,
          clinic_key: appointment.clinic_key,
          recipient_last4: recipient.slice(-4),
          template_name: templateName,
          status: "pending",
          sent_by: user.id,
        })
        .select("id")
        .single();
      if (insertError) {
        if (insertError.code === "23505") {
          return respond(409, { error: "A rejection WhatsApp send is already being processed for this appointment." });
        }
        throw new Error("Could not create rejection WhatsApp send log: " + insertError.message);
      }
      logId = inserted.id;
    }

    const graphResponse = await fetch(
      `https://graph.facebook.com/${apiVersion}/${phoneNumberId}/messages`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${waToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          messaging_product: "whatsapp",
          recipient_type: "individual",
          to: recipient,
          type: "template",
          template: {
            name: templateName,
            language: { code: language },
            components: [{
              type: "body",
              parameters: values.map((value) => ({ type: "text", text: value })),
            }],
          },
        }),
      },
    );

    const providerResult = await graphResponse.json().catch(() => ({}));
    if (!graphResponse.ok) {
      const providerMessage = providerResult?.error?.message || "Meta WhatsApp API rejected the rejection message.";
      await admin.from("clinic_whatsapp_rejection_log").update({
        status: "failed",
        error_message: String(providerMessage).slice(0, 1000),
        updated_at: new Date().toISOString(),
      }).eq("id", logId);
      return respond(502, { error: "Appointment was rejected, but WhatsApp was not accepted by Meta: " + providerMessage });
    }

    const messageId = providerResult?.messages?.[0]?.id || null;
    await admin.from("clinic_whatsapp_rejection_log").update({
      status: "sent",
      provider_message_id: messageId,
      error_message: null,
      updated_at: new Date().toISOString(),
    }).eq("id", logId);

    return respond(200, {
      ok: true,
      accepted_by_provider: true,
      provider_message_id: messageId,
      message: "Rejection WhatsApp accepted by Meta. Final handset delivery may update later.",
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : "Unexpected rejection WhatsApp error.";
    return respond(500, { error: message });
  }
});
