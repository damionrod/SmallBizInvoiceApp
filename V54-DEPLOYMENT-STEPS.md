# v54 — Simplified My Expenses navigation and reporting

This release is a frontend-only update on top of v53.

## What changed
- Removed the Expenses Dashboard sub-tab.
- Moved expense dashboard/reporting content into Reports > Expense Report.
- Removed Categories from the Expenses sub-tabs.
- Added a Create Category button in Add Expense that opens the category manager.
- Simplified Bills & Expenses with three summary cards, period/date controls, search, and Download CSV.
- Simplified the Bills & Expenses table and retained secondary actions under More.
- Preserved mobile card behaviour.

## Deployment
1. Deploy the v54 ZIP to Netlify.
2. No Supabase SQL migration is required.
3. No Edge Function redeployment is required.
4. Refresh/sign in and test My Expenses > Bills & Expenses, Add Expense > Create Category, and Reports > Expense Report.
