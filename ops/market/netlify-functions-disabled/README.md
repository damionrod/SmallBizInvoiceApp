# No Netlify handlers in Frindly Market

The Market branch explicitly points Netlify Functions to this directory, which
contains no executable handlers. This excludes the legacy scheduled compliance
checks in `netlify/functions`, including when a team environment variable exists.

Keep this directory free of function files. Test database functions remain in the
separate isolated Supabase project and use the outbound-service controls recorded
in `ops/market/README.md`.
