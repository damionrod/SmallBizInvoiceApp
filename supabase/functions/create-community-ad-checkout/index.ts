import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getStripeConfig, randomIntegrationSuffix, stripeHeaders } from "../_shared/payment-config.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const out = (x: any, status = 200) =>
  new Response(JSON.stringify(x), { status, headers: { ...cors, "Content-Type": "application/json" } });

function escText(value: any, max = 2000) {
  return String(value ?? "").trim().slice(0, max);
}

function validUrl(raw: any) {
  const value = escText(raw, 400);
  if (!value) return null;
  const u = new URL(value);
  if (!["https:", "http:"].includes(u.protocol)) throw new Error("Banner link must start with http:// or https://");
  return u.toString();
}

function validateReturnUrl(raw: any, req: Request) {
  const value = escText(raw, 600);
  if (!value) throw new Error("Missing return URL");
  const target = new URL(value);
  if (!["https:", "http:"].includes(target.protocol)) throw new Error("Return URL must use HTTP or HTTPS");
  const origin = req.headers.get("origin");
  if (origin && new URL(origin).origin !== target.origin) throw new Error("Return URL origin does not match the app origin");
  return target.toString();
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return out({ error: "Method not allowed" }, 405);
  let stage = "initialising";
  try {
    const url = Deno.env.get("SUPABASE_URL")!;
    const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
    const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const auth = req.headers.get("Authorization") || "";
    const client = createClient(url, anon, { global: { headers: { Authorization: auth } } });
    const admin = createClient(url, service);

    stage = "authenticating";
    const { data: { user } } = await client.auth.getUser();
    if (!user) return out({ error: "Not authenticated" }, 401);

    stage = "loading Stripe";
    const { secretKey: stripe } = await getStripeConfig(admin, true);

    stage = "reading request";
    const body = await req.json().catch(() => ({}));
    const packageId = escText(body.packageId, 80);
    const returnUrl = validateReturnUrl(body.returnUrl, req);
    const title = escText(body.title, 140);
    const message = escText(body.message, 500);
    const sponsorName = escText(body.sponsorName, 120);
    const destinationUrl = validUrl(body.destinationUrl);
    if (!packageId || !title || !sponsorName || !destinationUrl) {
      return out({ error: "Choose a package and enter sponsor name, title and website link." }, 400);
    }

    stage = "resolving active business";
    const { data: businessId, error: businessError } = await client.rpc("current_business_id");
    if (businessError || !businessId) return out({ error: "No active business context found." }, 403);

    stage = "checking package";
    const { data: pkg, error: pkgError } = await admin.from("community_ad_packages")
      .select("*").eq("id", packageId).eq("active", true).maybeSingle();
    if (pkgError) throw pkgError;
    if (!pkg) return out({ error: "This banner package is no longer available." }, 404);
    const amount = Math.round(Number(pkg.price || 0) * 100);
    if (!Number.isInteger(amount) || amount <= 0) return out({ error: "This package price is not valid for Stripe checkout." }, 400);
    const currency = String(pkg.currency || "NZD").toLowerCase();
    const startsAt = new Date().toISOString();
    const endsAt = new Date(Date.now() + Number(pkg.duration_days || 30) * 86400000).toISOString();

    stage = "creating banner booking";
    const { data: campaign, error: campaignError } = await admin.from("community_ad_campaigns").insert({
      package_id: pkg.id,
      sponsor_type: "frindly_user",
      sponsor_business_id: businessId,
      sponsor_name: sponsorName,
      title,
      body: message,
      destination_url: destinationUrl,
      placement: pkg.placement,
      target_region: escText(body.targetRegion, 80) || null,
      target_industry: escText(body.targetIndustry, 80) || null,
      price_charged: Number(pkg.price || 0),
      currency: String(pkg.currency || "NZD").toUpperCase(),
      payment_status: "pending",
      status: "pending_payment",
      starts_at: startsAt,
      ends_at: endsAt,
      created_by: user.id,
    }).select("*").single();
    if (campaignError) throw campaignError;

    stage = "creating checkout";
    const f = new URLSearchParams();
    f.set("mode", "payment");
    f.set("line_items[0][price_data][currency]", currency);
    f.set("line_items[0][price_data][unit_amount]", String(amount));
    f.set("line_items[0][price_data][product_data][name]", String(pkg.name || "Frindly Community banner"));
    f.set("line_items[0][price_data][product_data][description]", `${pkg.duration_days} day ${pkg.placement} Community banner`);
    f.set("line_items[0][quantity]", "1");
    f.set("success_url", `${returnUrl}${returnUrl.includes("?") ? "&" : "?"}community_ad=success`);
    f.set("cancel_url", `${returnUrl}${returnUrl.includes("?") ? "&" : "?"}community_ad=cancel`);
    f.set("client_reference_id", campaign.id);
    f.set("metadata[community_ad_campaign_id]", campaign.id);
    f.set("metadata[business_id]", String(businessId));
    f.set("metadata[package_id]", String(pkg.id));
    f.set("payment_intent_data[metadata][community_ad_campaign_id]", campaign.id);
    f.set("integration_identifier", `frindly_community_ads_${randomIntegrationSuffix()}`);

    const r = await fetch("https://api.stripe.com/v1/checkout/sessions", {
      method: "POST",
      headers: stripeHeaders(stripe, true),
      body: f,
    });
    const d = await r.json();
    if (!r.ok) throw new Error(d?.error?.message || "Unable to open Community banner checkout");

    await admin.from("community_ad_campaigns").update({
      stripe_checkout_session_id: String(d.id || ""),
      updated_at: new Date().toISOString(),
    }).eq("id", campaign.id);

    return out({ url: d.url, campaignId: campaign.id });
  } catch (e) {
    return out({ error: e instanceof Error ? e.message : "Community banner checkout failed", stage }, 400);
  }
});
