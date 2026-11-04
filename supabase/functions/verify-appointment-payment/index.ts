import { createClient } from "npm:@supabase/supabase-js@2";

const allowedOrigin = Deno.env.get("ALLOWED_ORIGIN") || "*";
const corsHeaders = {
  "Access-Control-Allow-Origin": allowedOrigin,
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
  "Vary": "Origin",
};

function respond(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), { status, headers: corsHeaders });
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

function isAllowedOrigin(req: Request): boolean {
  const origin = req.headers.get("Origin");
  return allowedOrigin === "*" || !origin || origin === allowedOrigin;
}

async function hmacHex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message));
  return Array.from(new Uint8Array(signature)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

async function razorpayRequest(url: string, method: string, keyId: string, keySecret: string, body?: unknown) {
  const response = await fetch(url, {
    method,
    headers: {
      Authorization: "Basic " + btoa(keyId + ":" + keySecret),
      ...(body ? { "Content-Type": "application/json" } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  const data = await response.json().catch(() => ({}));
  return { ok: response.ok, status: response.status, data };
}

function paymentMethod(value: unknown): string {
  const method = String(value || "").toLowerCase();
  if (method === "upi") return "upi";
  if (method === "card") return "card";
  if (method === "netbanking") return "bank_transfer";
  return "other";
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return respond(405, { error: "Method not allowed." });
  if (!isAllowedOrigin(req)) return respond(403, { error: "This website origin is not allowed." });

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ||
      Deno.env.get("SUPABASE_SECRET_KEY") ||
      keyFromCollection("SUPABASE_SECRET_KEYS");
    const keyId = Deno.env.get("RAZORPAY_KEY_ID") || "";
    const keySecret = Deno.env.get("RAZORPAY_KEY_SECRET") || "";

    if (!supabaseUrl || !serviceRoleKey || !keyId || !keySecret) {
      return respond(503, { error: "Payment verification is not configured on the server." });
    }

    const body = await req.json().catch(() => ({}));
    const orderId = String(body.razorpay_order_id || "");
    const paymentId = String(body.razorpay_payment_id || "");
    const signature = String(body.razorpay_signature || "");
    if (!orderId || !paymentId || !/^[a-f0-9]{64}$/i.test(signature)) {
      return respond(400, { error: "Razorpay payment response is incomplete." });
    }

    const admin = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: order, error: orderError } = await admin
      .from("appointment_payment_orders")
      .select("razorpay_order_id,razorpay_payment_id,amount_paise,currency,status,result")
      .eq("razorpay_order_id", orderId)
      .maybeSingle();

    if (orderError) throw new Error("Could not load the payment order: " + orderError.message);
    if (!order) return respond(404, { error: "The appointment payment order was not found." });

    if (order.status === "paid" && order.result) {
      if (order.razorpay_payment_id !== paymentId) {
        return respond(409, { error: "This payment order was already finalized with another payment." });
      }
      return respond(200, { ok: true, ...order.result });
    }
    if (order.status !== "pending") {
      return respond(409, { error: "This appointment payment order is no longer pending." });
    }

    const expectedSignature = await hmacHex(keySecret, orderId + "|" + paymentId);
    if (!safeEqual(expectedSignature.toLowerCase(), signature.toLowerCase())) {
      return respond(400, { error: "Razorpay payment signature is invalid. No appointment was created." });
    }

    let paymentResult = await razorpayRequest(
      "https://api.razorpay.com/v1/payments/" + encodeURIComponent(paymentId),
      "GET",
      keyId,
      keySecret,
    );
    if (!paymentResult.ok) {
      const detail = paymentResult.data?.error?.description || "Could not verify payment with Razorpay.";
      return respond(502, { error: String(detail).slice(0, 500) });
    }
    let payment = paymentResult.data;

    if (payment.order_id !== orderId ||
        Number(payment.amount) !== Number(order.amount_paise) ||
        String(payment.currency || "") !== String(order.currency || "INR")) {
      return respond(409, { error: "Razorpay payment details do not match the saved booking order." });
    }

    if (payment.status === "authorized") {
      const captureResult = await razorpayRequest(
        "https://api.razorpay.com/v1/payments/" + encodeURIComponent(paymentId) + "/capture",
        "POST",
        keyId,
        keySecret,
        { amount: Number(order.amount_paise), currency: String(order.currency || "INR") },
      );
      if (captureResult.ok) {
        payment = captureResult.data;
      } else {
        // The payment may have been captured by the automatic-capture setting
        // between the fetch and capture request. Re-fetch before failing.
        paymentResult = await razorpayRequest(
          "https://api.razorpay.com/v1/payments/" + encodeURIComponent(paymentId),
          "GET",
          keyId,
          keySecret,
        );
        if (paymentResult.ok) payment = paymentResult.data;
      }
    }

    if (payment.status !== "captured") {
      return respond(409, {
        error: "Razorpay has not confirmed a captured payment yet. No appointment request has been sent to the clinic.",
      });
    }

    const method = paymentMethod(payment.method);
    const { data: finalized, error: finalizeError } = await admin.rpc("finalize_paid_appointment", {
      p_razorpay_order_id: orderId,
      p_razorpay_payment_id: paymentId,
      p_payment_method: method,
      p_verified_amount_paise: Number(payment.amount),
    });
    if (finalizeError) throw new Error("Payment was captured, but appointment finalization needs a retry: " + finalizeError.message);
    if (!finalized?.appointment_id) throw new Error("Payment was captured, but the appointment record was not returned. Retry verification.");

    return respond(200, { ok: true, ...finalized });
  } catch (error) {
    return respond(500, {
      error: error instanceof Error ? error.message : "Could not verify payment.",
    });
  }
});
