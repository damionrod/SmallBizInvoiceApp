# CareClean Invoice Manager

A mobile-friendly invoicing app for CareClean / Care New Zealand Limited.

## CareClean defaults already included
- Company: Care New Zealand Limited
- Trading name: CareClean
- Address: 120 Melksham Drive, Churton Park, Wellington 6037
- Phone: 027 499 4445
- Email: info@careclean.co.nz
- Bank account: 02-0506-0400503-000
- Default payment terms: due 3 days after invoice date
- Payment instruction: customers are told to use the invoice number as the bank payment reference

## Settings page
The Settings page lets you manage:
- Company name, trading name, address, phone, email and GST number
- Default number of days until payment is due
- One or multiple bank accounts, with one selected as the default
- Products/services and default prices excluding GST
- Invoice template selection: Classic, Minimal or Modern
- Colour themes plus custom primary/accent colours
- Custom logo upload, with an option to restore the original CareClean logo
- Supabase database credentials

Changing a product default price affects new invoice line items, but you can still override the price on any individual invoice.

## Invoice features
- Automatic invoice date and sequential invoice number (for example `CC-0001`, `CC-0002`, `CC-0003`)
- Due date automatically set from the default payment term (currently 3 days) but editable on every invoice
- Service dropdown + custom description, quantity and multiple line items
- Automatic 15% GST calculation with subtotal, GST and total shown separately
- PDF download
- Bank account and invoice-number payment reference displayed on the PDF
- Invoice database/history, customer/address/date display
- Monthly filtering and monthly totals
- CSV export for accounting
- View, edit and delete invoices
- Supabase cloud storage support
- Email PDF support using Supabase Edge Function + Resend, sent as `info@careclean.co.nz`
- LocalStorage demo mode if Supabase is not yet configured

## Still required
Enter your CareClean GST number in Settings once you have it.

## Supabase setup
1. Create a Supabase project.
2. In SQL Editor, run `schema.sql`.
3. Paste the Project URL and anon key into Settings in the app.
4. The included SQL policy is intentionally simple for a single-owner starter deployment. Before public use, add Supabase Auth and owner-specific RLS policies.

## Email setup
1. Create/verify `careclean.co.nz` in Resend (or adapt the function to another provider).
2. In Supabase, set the secret `RESEND_API_KEY`.
3. Deploy `supabase/functions/send-invoice` as `send-invoice`.
4. The sender is configured as `CareClean <info@careclean.co.nz>`.
5. Your email provider must authorize that sender/domain.

## Deploying to Netlify
This is a static app. Drag the app folder into Netlify or deploy from Git. There is no build command; publish the project root.

## Recommended production hardening
- Add login/authentication before public deployment.
- Replace the starter RLS policy with authenticated owner-only access.
- Add invoice status such as Draft / Sent / Paid / Overdue if required later.


## Latest workflow updates
- Saving an invoice now creates/saves that record, refreshes the invoice history, then automatically clears the form and generates a fresh invoice number for the next invoice.
- Invoice history is ordered newest-first so multiple invoices appear as separate rows.
- Service descriptions are now typeable text fields with saved products/services shown as autocomplete suggestions.
- Settings includes a live invoice design preview that updates while changing template, theme, colours, company details, GST number, and logo.

## Invoice wording (v4)
The Settings page now includes an **Invoice wording** section. You can edit the invoice title, Bill To heading, invoice/date/due labels, item-table headings, subtotal/GST/total labels, payment labels, payment instruction, and the default customer note/footer. The live invoice preview updates while you type. Saved wording is snapshotted into each invoice so older invoices keep the wording they were created with.

The default customer note supports `{dueDays}` and `{tradingName}` placeholders, for example: `Thank you for choosing {tradingName}. Please pay within {dueDays} days.`

## Version 6 updates
- GST rate is now configurable in **Settings** instead of being fixed at 15%.
- An optional second percentage charge can be enabled for an **additional tax or service fee**. Its label and percentage are configurable and it is shown separately on the invoice when enabled.
- Customer address and customer email are optional. An invoice can be saved without either. If **Save & Email PDF** is used without a customer email, the invoice is saved normally and no email is sent.
- The Invoices page now includes a **PDF** button on every saved invoice row for direct download.
- Invoice numbers are shorter: `CC-YYMMDD-1234` rather than including the four-digit year.
- A new **Reports** module includes custom date ranges plus Last Month, Last 3 Months, Last 6 Months and Last 12 Months shortcuts.
- Reports show sales excluding tax/fees, GST, invoice count and total invoiced, plus a month-on-month bar chart with the sales value displayed above every bar.
- Report CSV exports include the optional additional fee/tax amount.

## v7 changes

- GST is now calculated **after** the optional service fee/tax, so the service fee is included in the GST taxable base.
- The GST label is cleaned automatically so a saved label such as `GST (15%)` does not display the percentage twice.
- Create Invoice includes an optional discount as either a percentage or fixed dollar amount. The discount is applied before the service fee and GST.
- Create Invoice includes optional Amount Paid and automatically calculates Balance Due.
- Create Invoice includes a recurring-invoice checkbox with weekly, fortnightly, and monthly frequencies. When the app is opened, any recurring invoices that have become due are generated automatically. This browser-based starter does not run while the app is completely closed; fully unattended recurrence requires a server-side scheduler/cron job.
- My Invoices includes an email box and Send button on each invoice row, as well as View, PDF, Edit and Delete.
- Company Settings now includes Website, which is shown on the invoice and live preview.
- Buttons now have visible press/click feedback.
- Invoice numbers are shorter, for example `CC-260901-123`.

### Important Supabase upgrade

If you already ran an earlier `schema.sql`, run the v7 `schema.sql` again in the Supabase SQL editor. It contains safe `ADD COLUMN IF NOT EXISTS` statements for discount, service fee, amount paid, balance due, and recurrence fields, plus the new `recurring_rules` table.


## v11 - My Customers CRM
Adds individual/business customer profiles, categories, multiple contacts with one billing contact, birthday highlighting, custom fields, customer invoice history, Create Invoice customer lookup/auto-create, CSV import/export, and customer-ID invoice linking. If using Supabase, run the updated `schema.sql` once to create the `customers` table and add customer-link columns to invoices. Existing invoices remain valid; new invoices link by `customer_id`.


## v12 sequential invoice numbering
- New invoices now receive automatic sequential invoice numbers: `CC-0001`, `CC-0002`, `CC-0003` and so on.
- The next number is determined from saved invoice history, including when a new invoice form is prepared after saving.
- Recurring invoices use the same sequence.
- Existing invoice numbers are preserved and are not renumbered.
