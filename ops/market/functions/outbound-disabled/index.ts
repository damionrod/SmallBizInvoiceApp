// Isolated Frindly Market only. Does not read request bodies or provider secrets.
Deno.serve((req: Request) => {
  const headers = {
    "Access-Control-Allow-Origin": "https://frindly-market.netlify.app",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
    "Content-Type": "application/json",
    "Cache-Control": "no-store"
  };
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers });
  return new Response(JSON.stringify({
    error: "External email, payment, bank and AI services are disabled in Frindly Market.",
    code: "MARKET_OUTBOUND_DISABLED",
    environment: "market"
  }), { status: 503, headers });
});
