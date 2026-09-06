# v53 - My Expenses focused UI fixes

This version makes only two requested changes to My Expenses:

1. Payment Status is editable when editing an expense. Marking an unpaid expense as Paid creates a payment record for the remaining balance. Existing payment history is preserved and cannot be silently erased by switching back to Unpaid/Draft.
2. Receipt / Bill Capture is simplified to Take Photo + Upload File. Attachments remain optional, so users can simply complete the form and save without choosing a file. Upload File accepts images, PDFs and other file types up to the existing 10 MB limit.

No database migration or Edge Function redeployment is required. Deploy the ZIP to Netlify.
