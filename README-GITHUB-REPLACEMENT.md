# Frindly v61.90T — complete 100-file GitHub package

25 September 2026. This release fixes the new pay run's usual-payday choice, while retaining the complete Frindly application within GitHub's 100-file upload limit. Extract the ZIP and upload the contents to the repository root, retaining folder paths. Uploading the ZIP itself does not extract it in GitHub. Compare your repository for files newer than this package before replacing it. A GitHub push may trigger a Netlify deploy if your site is linked.

## v61.90T payroll payday transition

- Existing pay runs keep their saved pay dates, regardless of later Payroll Settings changes. For a new weekly or fortnightly run whose previous payday weekday differs from the saved usual payday, Pay Run Details requires a clear choice: enter the first date on the new usual weekday or keep the old weekday for this run. The next new run checks Settings again. The work-period dates are not automatically changed as a side effect of choosing a payday.
- Changing Pay Date on a calculated run immediately recalculates the loaded employee tax and statutory results using the chosen date; manually added items are retained. Changing the work period or frequency requires Load / Calculate before the run can be saved, preserving manual entries on recalculation. Finalised runs remain locked.
- No migration, database records, Supabase functions, unrelated modules, or live production settings were changed. Four focused payroll checks passed, alongside the complete Node suite. Live browser and authenticated database checks were not available; review the weekday choice and a draft with actual employees before finalising or filing payroll.
- This 100-file package adds `tests/v6190t-payroll-payday.test.js` and omits one more historical non-runtime document, `docs/V61.86-SUBSCRIPTION-SYNC-FIX.md`. The three historical guidance files excluded in v61.90S remain excluded. The historical release notes below describe their original packages.

# Frindly v61.90S — 100-file GitHub upload package

25 September 2026. This is the **complete v61.90S application** within the 100-file browser upload limit. Extract the ZIP and place its contents at the repository root, retaining folder paths. Uploading the ZIP itself does not unpack it on GitHub. If your repository has any of the three omitted documents from an older version, remove them separately if you want its file list to match this package exactly.

The only omitted files are historical, non-runtime guidance: `LOCAL-RUN-INSTRUCTIONS.txt` (obsolete local Finlo launch instructions), `docs/BINGO-ONLY-ACCESS-VERIFICATION.md` (historical preview verification), and `docs/V61.85-STRIPE-CONNECT-REVISIT-FIX.md` (historical Stripe fix notes). No application code, migration, Edge Function, configuration, test, or required purchase-review SQL file was removed. The manifest is regenerated for this 100-file package. The previous v61.90S release notes follow.

# Frindly v61.90S — complete compact GitHub replacement

25 September 2026. The original v61.90S package had 103 files. Extract it and preserve its `public/`, `supabase/`, `docs/` and `tests/` paths at the repository root. It builds on the supplied reviewed v61.89 compact package and carries forward the existing modules. It is **not** a clone of any files added to GitHub after that package: compare your current repository before replacing or deleting anything. Saving to GitHub alone does not run database SQL or deploy the updated Supabase function. If your GitHub branch is connected to Netlify, pushing it may automatically deploy the frontend.

## v61.90S organized Create Invoice form

- The Create Invoice panel now follows a consistent full-width sequence: short invoice number and date fields in one row, customer details grouped in two rows on wide desktops, then invoice items and visible totals. Tablet uses three customer rows; mobile uses stacked, touch-sized fields and maintains readable date widths. Long addresses remain scrollable and editable. Discount, payment and recurring settings live in a collapsed More invoice options section. It automatically opens when editing a draft with any of those settings, and the customer message stays visible alongside the totals.
- The Australian GST field is hidden with a stronger selector than the form label display rule and an inline important display guard; only an AU business configured in AUD can show the field. NZ and unsupported configurations keep it hidden, with existing validation for AU non-AUD accounts. This repairs the issue visible in the supplied v61.90R screenshot.
- All earlier invoice IDs remain in the page. Calculation, payload and save functions are identical to v61.90R. The full automated suite passed 39/39, including new and edited draft option checks and NZ/AU GST checks. Cloud browser security prevented opening the local file, so desktop and mobile visual layouts remain unverified in a live browser; review the extracted package on your computer before deployment. No migration or production change occurred.

## v61.90R compact Create Invoice layout

- Desktop now places the invoice number in a short field, keeps invoice and due dates side by side, and arranges customer details in three balanced rows. The form and optional sections use less padding; mobile retains 44px controls, shows dates at usable widths and stacks narrower screens without horizontal scrolling. The billing address stays editable for long text.
- Changes are confined to Create Invoice CSS and its stylesheet cache reference. All existing invoice field IDs, controls, data, saving, totals, Australian/NZ GST logic and other modules remain intact. The HTML structure and invoice JavaScript were compared byte for byte with v61.90Q before changing the stylesheet reference.
- The existing 36 automated tests passed. A visual browser run at desktop and phone widths was unavailable in this workspace, so check the extracted copy locally before replacing the desktop folder or deploying. No database or production change was made.

## v61.90Q Australian GST field stays hidden by default

- The Australian GST treatment field is now hidden directly in the invoice HTML, even before CSS and JavaScript load. The invoice form shows it only when the active business is configured for Australia and AUD. For NZ and all other configurations it remains hidden. An AU business configured for another currency still cannot save until its currency is corrected.
- The supplied screenshot shows `C:/Users/.../Desktop/new Ui ready/public/index.html` loaded as a local file. Replacing a GitHub repo or downloading a ZIP will not update that desktop folder. Extract this package and open its `public/index.html` if testing locally. Confirm the browser's address bar points to the newly extracted directory.
- The invoice calculation function and its tax formulas are unchanged. The full automated suite passed 36/36, including visibility and NZ/AU GST totals. No production deployment, migration or live database change was made. A live browser visual check was unavailable in this workspace.

## v61.90P Australian GST field on Create Invoice

- The Australian GST treatment selector is now actually hidden by CSS for non-Australian businesses, including NZ businesses. It had a `hidden` attribute, but the generic form label styling could override its display state.
- Australian tax configuration runs only when the business is set to AU and its currency is AUD. An AU business set to another currency shows a configuration error and cannot save an invoice until Account Settings are corrected. NZ invoices continue using their existing GST configuration. The calculation function, GST formula, and existing invoice records were not changed.
- Five focused checks cover NZ visibility and GST, AU/AUD visibility and GST lookup, mismatched AU currency rejection, and unchanged invoice totals source. The complete Node suite passed 36/36. No live browser or connected database tax lookup was available for this release; no deployment or database migration occurred.

## v61.90O compact Add/Edit Customer form

- Add and Edit Customer now place type and category together, name and a compact address together, and show the primary contact immediately. Additional contacts open as added; each contact retains its own optional date of birth and selectable billing designation. Custom information appears under collapsed More details. At phone widths the fields stack and Save remains within reach.
- Existing customer-level dates of birth are retained in hidden form data when editing, including records created before contact DOB was available. A blank primary contact on a newly created customer is not saved unless filled in. The customer database structure, invoice, expense and other modules are unchanged.
- Four focused add/edit checks covered individual and business records, no contact, one contact, two contacts, both contact DOBs, custom fields, selected billing contact and retained legacy customer DOB. The complete Node suite passed 31/31. Browser visual testing and a connected customer database save were not available in this workspace. No migration or production deployment was performed.

## v61.90N simpler Payroll Settings

- The pay schedule stays visible. Less-used defaults, read-only current payroll rules, leave types and document types open on demand. Pay items show a compact summary row and reveal editing fields and statutory classifications when selected. Classifications needing confirmation remain visibly flagged. All existing payroll field IDs and values remain available to Save even while their sections are collapsed.
- Save now checks errors returned by every pay-item, leave-type and document-type update before reporting success. An incomplete save keeps the form open and reports that some earlier updates may have completed. Unsaved edits trigger a discard confirmation when leaving Settings or adding/archiving a setting. No statutory rates, calculation formulas, payroll schemas or data were changed.
- Verified field presence in the revised HTML, a mocked full-settings save and failed pay-item update, JavaScript syntax, and 27/27 existing tests. No live browser or database workflow was run, and no frontend deployment occurred.

## v61.90M NZ payroll bank account format

- For NZ payroll businesses, an employee bank account with 15 or 16 digits is displayed and saved as `38-9026-0613543-00` or `38-9026-0613543-000`. Pasted spaces and hyphens are normalized when the total digit count matches. A partial, unusual or incorrectly sized value can still be saved without validation blocking it. Other countries' bank fields are unaffected.
- Focused checks covered both suffix lengths, pasted separators, invalid/partial entries and non-NZ settings. The existing 27/27 tests passed. No database or Edge Function changes were made, and no frontend deployment was performed.

## v61.90L employee field suggestions

- Job Title / Role, Department and Manager show suggestions taken from employee records already loaded for the current business. Values are deduplicated and refresh whenever the employee form opens. The inputs remain editable, so new values can be entered and saved in the same fields. No new table or shared list is introduced.
- A focused check covered duplicate values, free text and clearing suggestions when no employees are loaded; the existing 27/27 regression tests passed. No database change or frontend deployment was performed.

## v61.90K PAYG employee save correction

- The PAYG evidence save path referenced undeclared values after a new employee was written, preventing the employee modal from completing a PAYG save. It now initializes the selected eligibility route, evidence date and confirmation normally. Check the employee list before trying again: the previous failed attempt could already have created the employee without saving its PAYG evidence.
- Fixed-term-only fields are hidden for the irregular/intermittent PAYG route. The new-employee start-date default from v61.90J remains in place.
- Focused checks covered irregular/intermittent and fixed-term evidence saves, missing confirmation, and standard annual leave; all 27 existing tests passed. No live employee was modified, no database or Edge Function change was made, and no Netlify deployment occurred.

## v61.90J new employee evidence date

- When creating an employee, changing Start Date also fills Evidence effective from with that date. Once the evidence date is edited independently, later start-date edits leave it alone. Opening a different new employee resets the default; existing employee evidence dates are unchanged.
- Only the payroll frontend and cache references changed. A focused check covered the default, independent edit and existing employee, and the 27 existing tests passed. No database or Edge Function changes were made; no frontend deployment was performed.

## v61.90I invoice PDF quality

- The PDF-only logo layout keeps the uploaded logo's proportions within its existing space. PDF page rendering uses a slightly higher resolution and lossless PNG instead of JPEG to keep text and graphics clearer. The invoice content, saved data and on-screen design are unchanged. A source logo uploaded at low resolution cannot gain detail from PDF rendering alone.
- The invoice PDF test and existing regression suite passed 27/27 tests. No new SQL, Edge Function or Netlify deployment was performed. PDFs may be larger because the page images are lossless.

## v61.90H invoice billing address

- If a saved customer is selected and the address is edited while creating or editing an invoice, saving the invoice keeps the address entered on the invoice. The customer's saved contact address is not changed. Invoice preview, PDF and recurring rule use the saved invoice address.
- Only `public/app.js`, its cache references in `public/saas.js` and `public/index.html`, and this documentation changed from v61.90G. A focused test was added. The regression suite passed 26/26 tests. No new database migration or Edge Function change is required. The frontend has not been deployed as part of this fix.

## v61.90C scanner correction

- Expenses accepts multiple ordered bill photos or files, or a multipage PDF. The existing AI scanner reads all pages together. The saved bill remains the source of its original totals and GST.
- **Review items** lives beside recorded bills in Expenses and works when Stock & Equipment is off. The user can correct suggested Uses, categories and tax figures on compact rows and confirm the entire invoice to the cent. Earlier Stock reviews are copied into the shared review history by the migration.
- When the optional module is enabled, confirming also updates its operational register. The estimated Financials Summary uses confirmed ordinary expense rows, while the posted accounting reports and original GST and payment records remain intact. The Accountant Pack includes an item review schedule.

## v61.90D Financials purchase allocation

- Financials Summary shows the latest confirmed purchase allocation by Use, including when Stock & Equipment is disabled; unreviewed bills retain their original estimated expense treatment. The bill retains its GST and payment records.
- If confirmed item reviews cannot be read, Financials hides the estimated Summary instead of showing misleading original-bill figures. The posted accounting reports are unchanged.
- See `docs/V61.90D-CORE-PURCHASE-ALLOCATION.md` for behaviour, verification and the remaining journal, depreciation and stock valuation work. This frontend-only addition needs no new SQL migration or Edge deployment.

## v61.90G: same-invoice discounts and credits

- The existing phone scan now asks the AI to retain printed discounts/credits as negative item amounts; Review Items recognises positive printed `credit` amounts too. The Use column shows **Discount / credit**, and the compact Qty column links each credit to an earlier charge. If an invoice has mixed Uses, the customer must choose the charge. The original scan proposal and bill stay unaltered. A separately issued supplier credit remains in the existing Supplier Credits workflow.
- The signed item rows must match the recorded bill ex GST **and** GST exactly. Mixed GST without item-level evidence is left for review. The new `v6190f_invoice_discounts` migration validates discount target, category, kind, positive net cost and bill totals atomically; when optional Stock & Equipment is on, its register receives the net cost of linked items. No duplicate credit, payable, bank match or GST mutation is created.
- The estimated Financials Summary deducts discounts from the linked Use and category; the Accountant Pack includes each signed discount with its linked item number. Posted financial statements are unchanged.
- **Deployment status:** The new SQL migration was applied to the existing main Supabase project on 25 September 2026, and its `scan-expense-document` Edge Function is active at version 13. Do not rerun the SQL on main. Deploy only this frontend through the usual GitHub/Netlify flow when ready. Old saved scans with blank credit amounts need one **Rescan pages** in Expenses → Review Items after the frontend update. A standalone future credit note remains separate.
- Verified on an isolated current-schema Supabase project (netting Mercury's three credits, exact net ex GST/GST, and rejecting excess credits); `node --test tests/*.test.js` and JS syntax checks. No live browser walkthrough or real-account bill mutation was performed. The main SQL and Edge Function are deployed; the frontend is not. No production bill or review data was edited.

## v61.90F inline invoice review and register views

- Opening Expenses → Review Items shows each recorded bill total and its saved phone scan item suggestions immediately. Unreviewed bills start expanded with one compact desktop row per item; phones show each item on one line with edit controls opened only if needed. Reviewed bills remain visible and collapse after the entire invoice is saved.
- Each row displays a proposed Use, original expense category, quantity, ex GST, GST and inclusive total. The scanner's explicit item tax evidence and the bill's authoritative totals drive suggestions. Unclear mixed tax, missing lines or a mismatch require correction before saving; the original bill and its GST are not silently rewritten.
- Stock & Equipment now shows Stock for sale, Materials & supplies, Equipment and Small tools as separate operational views. Purchase review is exclusively in Expenses. No new SQL or Edge Function deployment is included in this frontend change.
- Verification: `node --test tests/*.test.js`; JS syntax checks. No live database, mobile browser or Netlify deployment was performed in this change. The optional register and Financials still only incorporate item allocations when a customer confirms the whole bill. Depreciation and posted accounts remain outside this review workflow.

## v61.90E optional Review Items page

- Expenses has a separate **Review Items** tab. Bills & Expenses no longer displays a review button on each bill. Saving a bill still returns to Bills & Expenses without requiring item review.
- On the new page, search recorded bills by supplier or reference, see its prefilled item rows, inspect pages and edit individual items. A bill with the right single category can be left unreviewed. Stock & Equipment no longer contains a purchase review link.
- The original bill, GST, payment and bank reconciliation records remain in Expenses. Financials changes only when the customer confirms the full item review; the optional register still uses that same confirmation. Posted accounting statements remain posted-only.
- Frontend code only: no SQL migration, Edge deployment, entitlement change or production deployment was performed. Verified by `node --test tests/*.test.js` (23 passing) and JavaScript syntax checks. A real browser walkthrough was unavailable in this workspace. Refresh the browser after a frontend deploy to load the new page assets.

## Deployment status and next step

The purchase-review SQL migration **was applied to the main Supabase project** on 24 September 2026 after checking its prerequisites. The main `scan-expense-document` Edge Function was upgraded to version 12 and verified to accept an ordered `documents` array. Those main backend steps are complete; do **not** run the migration again on main. No Netlify frontend deployment or module entitlement change was performed here.

Deploy the updated frontend when you want the automatic two-photo scan, readable failure messages, null-safe amounts and automatic saved-bill rescan. If GitHub main automatically deploys to Netlify, uploading the extracted package may consume a deploy. Refresh the browser after deploying. See `docs/V61.90C-TWO-PAGE-SCANNER-FORENSICS.md` for the root causes, verification and practical limits.

**Accounting scope:** The review does not post inventory balances, cost of sales, depreciation, low-value deductions or journal reclassifications. The Financials Summary is an estimate and must not be used as a filed tax calculation. The posted Profit & Loss and Balance Sheet still use their posted ledger. Further accountant-reviewed posting integration is required for complete NZ accounting treatment.
