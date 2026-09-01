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
- Automatic invoice date and unique invoice number
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
