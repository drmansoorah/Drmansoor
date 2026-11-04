import { createClient } from "npm:@supabase/supabase-js@2";

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

async function sha512(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-512", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let different = 0;
  for (let i = 0; i < a.length; i++) different |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return different === 0;
}

function escapeHtml(value: unknown): string {
  return String(value ?? "").replace(/[&<>"']/g, (ch) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  }[ch] || ch));
}

function htmlPage(title: string, message: string, details = "", tone = "teal"): Response {
  const palette = tone === "green"
    ? "border-emerald-200 bg-emerald-50 text-emerald-950"
    : tone === "red"
      ? "border-rose-200 bg-rose-50 text-rose-950"
      : "border-amber-200 bg-amber-50 text-amber-950";
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${escapeHtml(title)}</title><style>
    *{box-sizing:border-box}body{margin:0;padding:24px;background:#f8fafc;color:#0f172a;font:16px system-ui,-apple-system,Segoe UI,sans-serif}
    main{max-width:620px;margin:7vh auto;background:white;border:1px solid #e2e8f0;border-radius:22px;padding:28px;box-shadow:0 16px 40px rgba(15,23,42,.08)}
    h1{font-size:25px;margin:0 0 12px}p{line-height:1.55}.panel{border:1px solid;border-radius:14px;padding:16px;margin:18px 0}
    .details{font-size:14px;line-height:1.8}.code{font-family:ui-monospace,monospace;font-weight:800;letter-spacing:.08em}
    a{display:inline-block;margin-top:14px;padding:12px 18px;border-radius:11px;background:#0f766e;color:#fff;text-decoration:none;font-weight:700}
    small{color:#64748b}
  </style></head><body><main><h1>${escapeHtml(title)}</h1><div class="panel ${palette}"><p>${escapeHtml(message)}</p></div>${details}<a href="https://drmansoor.vercel.app/">Return to clinic website</a><p><small>Payment does not itself approve an appointment. The clinic team will review paid requests.</small></p></main></body></html>`;
  return new Response(html, {
    status: 200,
    headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" },
  });
}

function paymentMethod(mode: string): string {
  const value = String(mode || "").toUpperCase();
  if (value.includes("UPI")) return "upi";
  if (value === "CC" || value === "DC" || value.includes("CARD")) return "card";
  if (value === "NB" || value.includes("NET")) return "bank_transfer";
  return "other";
}

async function verifyWithPayU(
  txnid: string,
  merchantKey: string,
  merchantSalt: string,
  environment: string,
) {
  const hash = await sha512(merchantKey + "|verify_payment|" + txnid + "|" + merchantSalt);
  const body = new URLSearchParams({
    key: merchantKey,
    command: "verify_payment",
    var1: txnid,
    hash,
  });
  const endpoint = environment === "production"
    ? "https://info.payu.in/merchant/postservice.php?form=2"
    : "https://test.payu.in/merchant/postservice?form=2";
  const response = await fetch(endpoint, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
  });
  const data = await response.json().catch(() => null);
  if (!response.ok || !data) throw new Error("PayU Verify Payment API could not be reached.");
  const details = data?.transaction_details?.[txnid];
  if (Number(data?.status) !== 1 || !details) {
    throw new Error("PayU has not returned a verified transaction record yet.");
  }
  return details;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return new Response("Method not allowed.", { status: 405 });

  const source = new URL(req.url).searchParams.get("source") || "return";
  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ||
      Deno.env.get("SUPABASE_SECRET_KEY") ||
      keyFromCollection("SUPABASE_SECRET_KEYS");
    const merchantKey = Deno.env.get("PAYU_MERCHANT_KEY") || "";
    const merchantSalt = Deno.env.get("PAYU_MERCHANT_SALT") || "";
    const environment = (Deno.env.get("PAYU_ENV") || "test").toLowerCase();

    if (!supabaseUrl || !serviceRoleKey || !merchantKey || !merchantSalt) {
      if (source === "webhook") return Response.json({ error: "PayU callback is not configured." }, { status: 503 });
      return htmlPage("Payment verification unavailable", "The clinic payment service is not configured. Please contact the clinic desk.", "", "red");
    }

    const form = await req.formData();
    const value = (name: string) => String(form.get(name) ?? "");
    const txnid = value("txnid");
    const status = value("status").toLowerCase();
    const responseHash = value("hash");
    const responseKey = value("key");
    const amount = value("amount");
    const udf1 = value("udf1");
    const udf2 = value("udf2");
    const udf3 = value("udf3");
    const udf4 = value("udf4");
    const udf5 = value("udf5");
    const email = value("email");
    const firstname = value("firstname");
    const productinfo = value("productinfo");
    const payuPaymentId = value("mihpayid");

    if (!txnid || !responseHash || responseKey !== merchantKey) {
      if (source === "webhook") return Response.json({ error: "PayU response is missing required identifiers." }, { status: 400 });
      return htmlPage("Payment could not be verified", "The PayU response was incomplete. No appointment request has been created.", "", "red");
    }

    const admin = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: order, error: orderError } = await admin
      .from("appointment_payment_orders")
      .select("gateway_txn_id,gateway_payment_id,clinic_key,clinic_name,patient_name,phone,email,appointment_date,amount_paise,currency,status,result")
      .eq("gateway_txn_id", txnid)
      .maybeSingle();

    if (orderError) throw new Error("Could not load the clinic payment reference.");
    if (!order) {
      if (source === "webhook") return Response.json({ error: "Payment order not found." }, { status: 404 });
      return htmlPage("Payment reference not found", "We could not match this PayU transaction to a clinic booking. Please contact the clinic desk with transaction ID " + txnid + ".", "", "red");
    }

    const expectedHashBase =
      merchantSalt + "|" + status + "||||||" +
      [udf5, udf4, udf3, udf2, udf1, email, firstname, productinfo, amount, txnid, responseKey].join("|");
    const additionalCharges = value("additionalCharges") || value("additional_charges");
    const expectedHash = await sha512(
      additionalCharges
        ? additionalCharges + "|" + expectedHashBase
        : expectedHashBase,
    );

    if (!safeEqual(expectedHash, responseHash)) {
      if (source === "webhook") return Response.json({ error: "PayU response hash validation failed." }, { status: 400 });
      return htmlPage("Payment response could not be verified", "The security check did not pass. No appointment request has been created. Please contact the clinic desk; do not retry payment until the transaction is checked.", "<p>Reference: <span class=\"code\">" + escapeHtml(txnid) + "</span></p>", "red");
    }

    if (Math.round(Number(amount) * 100) !== Number(order.amount_paise) ||
        String(order.email).toLowerCase() !== email.toLowerCase() ||
        udf1 !== order.clinic_key ||
        udf2 !== String(order.appointment_date)) {
      if (source === "webhook") return Response.json({ error: "PayU response details do not match the saved booking." }, { status: 409 });
      return htmlPage("Payment details did not match", "The amount or booking details returned by PayU did not match the saved clinic booking. No appointment request has been created. Contact the clinic desk with this reference.", "<p>Reference: <span class=\"code\">" + escapeHtml(txnid) + "</span></p>", "red");
    }

    if (order.status === "paid" && order.result) {
      const details = order.result;
      if (source === "webhook") {
        return Response.json({ ok: true, already_finalized: true, appointment_id: details.appointment_id }, { status: 200 });
      }
      const patientDetails = `<div class="details"><b>Clinic:</b> ${escapeHtml(details.clinic_name)}<br><b>Preferred date:</b> ${escapeHtml(details.appointment_date)}<br><b>Amount paid:</b> ₹${escapeHtml(details.consultation_fee)}<br><b>Patient ID:</b> <span class="code">${escapeHtml(details.patient_code)}</span><br><b>MindCare Access Code:</b> <span class="code">${escapeHtml(details.portal_access_code || "Use your existing code")}</span><br><b>Payment reference:</b> <span class="code">${escapeHtml(txnid)}</span></div>`;
      return htmlPage("Payment received — request sent", "Your payment was already verified and the appointment request is in the clinic's Pending queue. The appointment is not confirmed until clinic approval.", patientDetails, "green");
    }

    if (status === "failure") {
      await admin.from("appointment_payment_orders")
        .update({ status: "failed", updated_at: new Date().toISOString() })
        .eq("gateway_txn_id", txnid)
        .eq("status", "pending");
      if (source === "webhook") return Response.json({ ok: true, payment_status: "failed", appointment_created: false }, { status: 200 });
      return htmlPage("Payment was not successful", "PayU did not complete this payment. No appointment request has been sent to the clinic. You may return to the clinic website and try again.", "<p>Reference: <span class=\"code\">" + escapeHtml(txnid) + "</span></p>", "red");
    }

    if (status !== "success" || (value("unmappedstatus") && value("unmappedstatus").toLowerCase() !== "captured")) {
      if (source === "webhook") return Response.json({ ok: true, payment_status: "pending", appointment_created: false }, { status: 200 });
      return htmlPage("Payment is still processing", "PayU has not yet confirmed a captured payment. No appointment request has been sent to the clinic yet. Please do not pay again; contact the clinic desk if this message remains.", "<p>Reference: <span class=\"code\">" + escapeHtml(txnid) + "</span></p>", "amber");
    }

    // A signed PayU callback is necessary but not sufficient. Reconcile against
    // PayU's server-side Verify Payment API before creating any appointment.
    let verified: Record<string, unknown>;
    try {
      verified = await verifyWithPayU(txnid, merchantKey, merchantSalt, environment);
    } catch (error) {
      if (source === "webhook") return Response.json({ error: error instanceof Error ? error.message : "PayU verification is pending." }, { status: 503 });
      return htmlPage("Payment verification is pending", "PayU returned a successful callback, but its Verify Payment API is not available yet. No appointment has been created. Please do not pay again; contact the clinic desk with this reference.", "<p>Reference: <span class=\"code\">" + escapeHtml(txnid) + "</span></p>", "amber");
    }

    const verifiedStatus = String(verified.status || "").toLowerCase();
    const verifiedUnmapped = String(verified.unmappedstatus || "").toLowerCase();
    const verifiedAmount = Number(verified.amt ?? verified.transaction_amount ?? verified.amount);
    const verifiedPayuId = String(verified.mihpayid || verified.mihpayupid || payuPaymentId);
    if (verifiedStatus !== "success" ||
        (verifiedUnmapped && verifiedUnmapped !== "captured") ||
        Math.round(verifiedAmount * 100) !== Number(order.amount_paise) ||
        !verifiedPayuId ||
        (payuPaymentId && verifiedPayuId !== payuPaymentId)) {
      if (source === "webhook") return Response.json({ error: "PayU Verify Payment API did not confirm a matching captured transaction." }, { status: 409 });
      return htmlPage("Payment is awaiting confirmation", "PayU's transaction verification did not yet confirm a captured payment for the exact clinic fee. No appointment request has been created. Please do not pay again; contact the clinic desk.", "<p>Reference: <span class=\"code\">" + escapeHtml(txnid) + "</span></p>", "amber");
    }

    const { data: finalized, error: finalizeError } = await admin.rpc("finalize_paid_appointment", {
      p_gateway_txn_id: txnid,
      p_gateway_payment_id: verifiedPayuId,
      p_payment_method: paymentMethod(value("mode")),
      p_verified_amount_paise: Math.round(verifiedAmount * 100),
    });
    if (finalizeError || !finalized?.appointment_id) {
      const detail = finalizeError?.message || "No appointment ID was returned.";
      if (source === "webhook") return Response.json({ error: "PayU payment was captured but booking finalization needs retry: " + detail }, { status: 503 });
      return htmlPage("Payment received — booking is being reconciled", "PayU payment was verified, but the booking record could not yet be finalized. Please do not pay again. Contact the clinic desk and quote this reference.", "<p>Reference: <span class=\"code\">" + escapeHtml(txnid) + "</span></p>", "amber");
    }

    if (source === "webhook") {
      return Response.json({ ok: true, appointment_id: finalized.appointment_id, payment_status: "paid" }, { status: 200 });
    }

    const patientDetails = `<div class="details"><b>Clinic:</b> ${escapeHtml(finalized.clinic_name)}<br><b>Preferred date:</b> ${escapeHtml(finalized.appointment_date)}<br><b>Amount paid:</b> ₹${escapeHtml(finalized.consultation_fee)}<br><b>Patient ID:</b> <span class="code">${escapeHtml(finalized.patient_code)}</span><br><b>MindCare Access Code:</b> <span class="code">${escapeHtml(finalized.portal_access_code || "Use your existing code")}</span><br><b>Payment reference:</b> <span class="code">${escapeHtml(txnid)}</span></div>`;
    return htmlPage("Payment received — request sent", "Your payment is verified and your appointment request has been sent to the clinic. The request is Pending; payment does not itself approve the appointment.", patientDetails, "green");
  } catch (error) {
    if (source === "webhook") {
      return Response.json({ error: error instanceof Error ? error.message : "PayU webhook processing failed." }, { status: 500 });
    }
    return htmlPage("Payment processing error", "The payment callback could not be processed safely. No new appointment confirmation is displayed. Please contact the clinic desk and provide the transaction reference if visible.", "", "red");
  }
});
