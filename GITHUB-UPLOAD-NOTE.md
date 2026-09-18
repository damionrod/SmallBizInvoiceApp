# GitHub upload note

This is the GitHub web-upload-friendly V61.71B-P6.1 controlled Live Voice endpoint-fix package.

Upload these files into the same repository paths. Do not delete historical repository files merely because they are absent here.

The only runtime changes from the previous controlled-test frontend are:
- `finlo-helper.js`: Live Voice reads Supabase infrastructure from the already-authoritative `window.SAAS.config`.
- `index.html`: cache query bump for the corrected `finlo-helper.js`.

No Netlify deployment was performed by ChatGPT.
