export const PRODUCT_KNOWLEDGE_VERSION = '2026-11-07-workflow-catalogue';
export const PRODUCT_GUIDANCE_RULES = "You are Frindly Helper, the product assistant for Frindly. The supplied product knowledge is authoritative for navigation and workflows. Use the exact current labels; Finlo is an obsolete name, not a separate product. Screen context says where the user is, not which features you may explain. Explain the relevant steps directly, in plain language. Do not invent a button, integration, automatic posting, filing, bank transfer or background task. Distinguish setting up a record, recording an actual transaction, posting accounting, matching a bank statement and filing externally. Product availability is not business entitlement: use supplied access evidence; if absent, do not claim enabled access. Respect role permissions and tenant isolation. If a workflow is not established here, say what is unknown and point to the existing screen/support instead of guessing. Give NZ guidance only for an NZ business; do not substitute NZ rules for another jurisdiction. Do not decide uncertain tax/legal/payroll/accounting treatment or create/change/send/file/delete records. Preserve filed snapshots and audit trails, prefer linked source records and avoid duplicates. No background or delayed-work capability: answer now from supplied information or state the limitation. Never expose private identifiers or invent business figures. Do not add disclaimers to ordinary navigation answers.";
export const PRODUCT_KNOWLEDGE = [
  {
    "id": "overview.features",
    "module": "dashboard",
    "moduleSlug": "invoice_manager",
    "title": "Find Frindly features",
    "keywords": [
      "what can frindly do",
      "all features",
      "workflows",
      "modules",
      "features overview"
    ],
    "navigation": "Top menu and account Settings",
    "facts": [
      "Main areas are Dashboard, Schedule, Job Costing, Invoices, Expenses, Stock, Payroll, Banking, Financials, Reports and Community. Settings is in the account menu.",
      "Optional areas depend on the business subscription and role permissions. A product feature existing does not establish that this business can access it.",
      "The helper explains workflows; it does not execute transactions, browse records on demand, send messages or work in the background."
    ],
    "procedure": [
      "Choose the area matching the task.",
      "Use the relevant tab or action described in the selected knowledge."
    ]
  },
  {
    "id": "dashboard.attention",
    "module": "dashboard",
    "moduleSlug": "invoice_manager",
    "title": "Dashboard and reminders",
    "keywords": [
      "dashboard",
      "needs attention",
      "payday reminder",
      "money to set aside",
      "bank balances",
      "cash movement"
    ],
    "navigation": "Dashboard",
    "facts": [
      "Needs attention includes overdue invoices, bank items, unscheduled jobs, urgent compliance reminders and upcoming paydays; payroll reminders open Payroll.",
      "The reminder engine also feeds Schedule. An IRD reminder clears when its pay run is marked filed in Frindly; downloading a file is not filing.",
      "Bank balances and Cash movement use posted ledger movements. Money to set aside includes unpaid liabilities and planning estimates; a loan balance is not automatically a bulk-payment reserve.",
      "Invoice/expense operational totals, profit, cash movement, tax obligations and bank balances measure different things. State the period and do not invent tenant figures."
    ],
    "procedure": [
      "Open Dashboard.",
      "Read the widget label and period.",
      "Select a Needs attention row to open its existing workflow."
    ]
  },
  {
    "id": "onboarding.nz",
    "module": "onboarding",
    "moduleSlug": "invoice_manager",
    "title": "Quick setup and business setup",
    "keywords": [
      "quick setup",
      "getting started",
      "onboarding",
      "start business"
    ],
    "navigation": "Quick setup; Settings → Business Setup",
    "facts": [
      "Quick setup covers business information, GST, modules and starting fresh versus existing records using authoritative business settings.",
      "Existing businesses can use Plan & Data for migration. Choose unsure/review when GST registration or tax treatment is unknown."
    ],
    "procedure": [
      "Complete Quick setup.",
      "Review Business Setup and Tax & Accounting.",
      "Configure bank accounts and opening balances before recording bank movements."
    ]
  },
  {
    "id": "invoices.create",
    "module": "invoices",
    "moduleSlug": "invoice_manager",
    "title": "Create, save and send invoices",
    "keywords": [
      "create invoice",
      "send invoice",
      "save draft",
      "invoice items",
      "download invoice",
      "invoice pdf"
    ],
    "navigation": "Invoices → Create Invoice",
    "facts": [
      "Invoices tabs are Create Invoice, Invoices, Customers and Settings. Use Customer / business name, invoice dates and Invoice items.",
      "Save Draft retains a draft. Send Invoice requires a customer email and follows existing issue/send protections. Drafts are excluded from posted financial reports.",
      "Issued invoices are protected; use the supported credit/void/correction workflow instead of deleting or silently overwriting posted amounts. PDF and email actions are available from invoice details/actions."
    ],
    "procedure": [
      "Choose a customer and dates.",
      "Add invoice items and review GST/totals.",
      "Save Draft or supply the email and use Send Invoice."
    ]
  },
  {
    "id": "invoices.payments",
    "module": "invoices",
    "moduleSlug": "invoice_manager",
    "title": "Record invoice receipts",
    "keywords": [
      "record payment",
      "invoice paid",
      "receiving bank",
      "customer payment",
      "partial payment"
    ],
    "navigation": "Invoices → invoice → Record Payment",
    "facts": [
      "Record Payment is for issued invoices with a balance due. Enter amount received, actual payment date, Receiving bank account, optional reference and notes.",
      "Choose an active bank linked to a ledger. The payment updates the invoice and posts through the existing accounting engine; bank reconciliation is not required.",
      "Match an existing recorded payment later in Banking; do not create the receipt again. A paid invoice does not mean the money was sent by Frindly."
    ],
    "procedure": [
      "Open the invoice.",
      "Choose Record Payment.",
      "Check amount/date and receiving bank.",
      "Record once and review the invoice balance."
    ]
  },
  {
    "id": "invoices.corrections",
    "module": "invoices",
    "moduleSlug": "invoice_manager",
    "title": "Invoice credits, voids and reminders",
    "keywords": [
      "credit note",
      "void invoice",
      "invoice reminder",
      "invoice correction",
      "overdue reminder"
    ],
    "navigation": "Invoices → invoice details/actions",
    "facts": [
      "Use the invoice actions for credit notes and supported void/correction controls. Preserve issued invoice history and do not replace a credit with an unrelated negative sale.",
      "Invoice reminders use configured reminder controls/templates; check the invoice email and reminder status. Paid/partial/unpaid balances reflect existing payments and credits.",
      "A refund pays money back; a credit note corrects the sale. They are related but not interchangeable."
    ],
    "procedure": [
      "Open the original invoice.",
      "Use its existing reminder or correction action.",
      "Review linked payments/credits before confirming any change."
    ]
  },
  {
    "id": "customers.add",
    "module": "customers",
    "moduleSlug": "invoice_manager",
    "title": "Manage customers",
    "keywords": [
      "add customer",
      "customer details",
      "customer list",
      "create customer"
    ],
    "navigation": "Invoices → Customers",
    "facts": [
      "Use the Customers tab and its add/edit controls. Customer selection is reused by invoices, quotes, jobs and scheduling.",
      "A customer contact change does not authorise changing an already issued document snapshot."
    ],
    "procedure": [
      "Open Invoices → Customers.",
      "Add or edit the customer and save."
    ]
  },
  {
    "id": "quotes.create",
    "module": "quotes",
    "moduleSlug": "job_costing",
    "title": "Create and send quotes",
    "keywords": [
      "create quote",
      "send quote",
      "quotation",
      "quote pdf",
      "quote status"
    ],
    "navigation": "Job Costing → Quotes",
    "facts": [
      "Quotes has + Create Quote. Enter customer, dates, quote items and terms; review GST and any advance requirement.",
      "Saved quotes offer PDF, email and status actions. Eligible quote statuses feed the existing schedule workflow; scheduling does not duplicate the quote."
    ],
    "procedure": [
      "Open Quotes.",
      "Choose + Create Quote.",
      "Review items and terms, save, then use the available send/PDF action."
    ]
  },
  {
    "id": "quotes.progress",
    "module": "quotes",
    "moduleSlug": "job_costing",
    "title": "Advance and progress invoices",
    "keywords": [
      "progress invoice",
      "advance invoice",
      "deposit invoice",
      "quote to invoice",
      "remaining quote balance"
    ],
    "navigation": "Job Costing → Quotes → Create Invoice",
    "facts": [
      "Create Invoice from the quote offers supported full/advance/progress billing options. Check previously invoiced and remaining amounts.",
      "Quote billing links preserve the original quote and invoice history. Do not create another full invoice for the same already billed amount."
    ],
    "procedure": [
      "Open the quote.",
      "Choose Create Invoice and the supported billing option.",
      "Review the amount already billed and proposed invoice before issuing."
    ]
  },
  {
    "id": "jobcosting.new",
    "module": "jobcosting",
    "moduleSlug": "job_costing",
    "title": "Cost a job",
    "keywords": [
      "new job",
      "job costing",
      "labour cost",
      "direct costs",
      "overhead allocation",
      "job duration",
      "margin contingency"
    ],
    "navigation": "Job Costing → New Job; Cost Settings",
    "facts": [
      "New Job uses customer/job details, labour, variable/direct costs, fixed overhead allocation and margin/contingency inputs.",
      "Cost Settings manages roles/rates, variable cost rates, overheads and presets. Job Duration and total billable labour hours are distinct allocation bases.",
      "A saved costing can support a quote; estimated costs are not automatically a supplier payment or posted expense."
    ],
    "procedure": [
      "Review Cost Settings.",
      "Enter the job and costing inputs.",
      "Save the costing, then create a quote if required."
    ]
  },
  {
    "id": "schedule.current",
    "module": "schedule",
    "moduleSlug": "schedule",
    "title": "Schedule jobs and navigate dates",
    "keywords": [
      "schedule job",
      "unscheduled",
      "month navigation",
      "date picker",
      "calendar week",
      "schedule filters",
      "drag drop"
    ],
    "navigation": "Schedule",
    "facts": [
      "Day/Week remain available. Select the month/year control to jump to a month or date; arrows move the selected day/week, and Today returns to today.",
      "Unscheduled cards show customer, job and duration where known. Find a job searches customer/title. On phones, Unscheduled opens a bottom drawer; selecting a card opens the existing job editor.",
      "Desktop drag-and-drop schedules or moves jobs; filters cover employee, status and customer. Eligible quotes can be scheduled through the same editor."
    ],
    "procedure": [
      "Choose Day or Week and the date.",
      "Search/open an unscheduled card or choose + Schedule job.",
      "Set date, time, duration and employees, then Save job."
    ]
  },
  {
    "id": "schedule.recurrence",
    "module": "schedule",
    "moduleSlug": "schedule",
    "title": "Recurring jobs and payroll time",
    "keywords": [
      "recurring job",
      "repeat job",
      "schedule timesheet",
      "break minutes",
      "employee assignment"
    ],
    "navigation": "Schedule → job editor",
    "facts": [
      "The editor supports recurring jobs with the displayed daily, alternate-day, weekly, fortnightly, monthly or selected-date options and optional end date.",
      "Employee assignments and optional draft payroll timesheets use existing schedule links. Break minutes must be shorter than the job duration.",
      "A scheduled job is not a finalised pay run. Review/approve payroll time separately; editing one occurrence is distinct from creating a series."
    ],
    "procedure": [
      "Open the job editor.",
      "Choose employees, duration and supported repeat settings.",
      "Check the draft timesheet option and break, then Save job."
    ]
  },
  {
    "id": "expenses.record",
    "module": "expenses",
    "moduleSlug": "expenses",
    "title": "Record expenses and supplier bills",
    "keywords": [
      "add expense",
      "supplier bill",
      "record expense",
      "save expense",
      "save as draft"
    ],
    "navigation": "Expenses → Add Expense",
    "facts": [
      "Tabs include Bills & Expenses, Add Expense, Review Items, Suppliers, Payments and Supplier Credits. Purchase Orders is available through its existing workflow when enabled.",
      "Enter supplier invoice/reference, dates, category, optional job, amount/GST, payment status and funding source. Save Expense records it; Save as Draft allows incomplete work.",
      "Drafts are not posted expenses. Saved posted records use protected edit/void/correction paths and closed-period review."
    ],
    "procedure": [
      "Open Add Expense.",
      "Enter/check document details, totals and payment status.",
      "Save Expense or Save as Draft."
    ]
  },
  {
    "id": "expenses.scan",
    "module": "expenses",
    "moduleSlug": "expenses",
    "title": "Scan a multipage invoice",
    "keywords": [
      "scan invoice",
      "upload receipt",
      "multiple pages",
      "take photo",
      "camera",
      "scan receipt"
    ],
    "navigation": "Expenses → Add Expense → Scan Receipt or Invoice",
    "facts": [
      "Take Photo and Upload File collect supporting invoice pages. Add all pages in order, remove incorrect pages and use the scan action once the full invoice is ready.",
      "Images and multipage PDFs are supported by the displayed uploader. Take Photo requests the rear camera; device/browser permissions and hardware still control availability.",
      "AI extraction is a draft suggestion: review supplier, line items, totals, GST and business use before saving. Do not scan each page as a separate invoice."
    ],
    "procedure": [
      "Add all invoice pages through Take Photo or Upload File.",
      "Review/remove pages as needed.",
      "Scan the complete invoice and verify the extracted fields."
    ]
  },
  {
    "id": "expenses.businessuse",
    "module": "expenses",
    "moduleSlug": "expenses",
    "title": "Part business and private use",
    "keywords": [
      "business use amount",
      "business percentage",
      "private portion",
      "allocation basis",
      "split expense",
      "business gst"
    ],
    "navigation": "Expenses → Add Expense → Amount & GST → Business use",
    "facts": [
      "Choose Part business / part private where applicable. Use Percentage or Business amount and review the business/private summary, allocation basis and note.",
      "The original bill total and business portion are distinct. Business GST and expense allocations follow the saved split; do not reduce the supplier payment to only the deductible portion.",
      "Split Expense is for allocating supported categories/lines; verify the totals reconcile. Business-use draft fields should remain when reopening a saved draft."
    ],
    "procedure": [
      "Enter the full invoice.",
      "Set business use by percentage or amount.",
      "Check business/private/GST totals and save."
    ]
  },
  {
    "id": "expenses.payment",
    "module": "expenses",
    "moduleSlug": "expenses",
    "title": "Pay supplier bills",
    "keywords": [
      "supplier payment",
      "mark bill paid",
      "record expense payment",
      "unpaid bill",
      "batch payment"
    ],
    "navigation": "Expenses → Bills & Expenses → Record payment; Payments",
    "facts": [
      "Record payment uses the actual date, amount and business bank or supported owner-personal funding source. A recorded payment posts without needing Banking access.",
      "A paid bill is excluded from unpaid supplier totals based on its remaining balance; reconciliation is a later confirmation, not a prerequisite.",
      "Payments/batch history use existing links. Preparing a payment file or draft batch is not proof the bank payment has occurred."
    ],
    "procedure": [
      "Open the supplier bill.",
      "Record payment with actual date, amount and funding bank.",
      "Review the remaining balance; match the same payment later if using Banking."
    ]
  },
  {
    "id": "expenses.corrections",
    "module": "expenses",
    "moduleSlug": "expenses",
    "title": "Expense corrections, credits and refunds",
    "keywords": [
      "supplier credit",
      "supplier refund",
      "void expense",
      "expense correction",
      "duplicate expense",
      "late transaction"
    ],
    "navigation": "Expenses → bill actions; Supplier Credits; Review Items",
    "facts": [
      "Use linked supplier credits/refunds for supplier corrections and money returned. Review allocation to the original bill and remaining credit.",
      "Duplicate checks and protected edit/void workflows preserve history. Posted or closed-period corrections may require review rather than direct rewriting.",
      "A late-period transaction review does not authorise rewriting a filed GST snapshot."
    ],
    "procedure": [
      "Open the original bill or Supplier Credits.",
      "Choose its supported correction/refund action.",
      "Review original document, allocations and affected period before confirming."
    ]
  },
  {
    "id": "suppliers.add",
    "module": "expenses",
    "moduleSlug": "expenses",
    "title": "Suppliers and categories",
    "keywords": [
      "supplier setup",
      "add supplier",
      "expense category",
      "archive category"
    ],
    "navigation": "Expenses → Suppliers; expense category controls",
    "facts": [
      "Supplier details are reused by bills/payments. Active supplier/category controls allow supported add/edit/archive actions.",
      "Archiving a used category does not erase historical postings. Category accounting changes use existing mappings/reclassification safeguards."
    ],
    "procedure": [
      "Open Suppliers to add/edit a supplier.",
      "Use the category controls on the expense workflow for available category actions."
    ]
  },
  {
    "id": "expenses.review_items",
    "module": "expenses",
    "moduleSlug": "expenses",
    "title": "Review purchase line items",
    "keywords": [
      "review items",
      "purchase review",
      "classify purchase",
      "confirm purchase lines",
      "stock purchase"
    ],
    "navigation": "Expenses → Review Items",
    "facts": [
      "Review Items works from the existing expense and its documents. Review line descriptions, quantities, ex-GST/GST/inclusive amounts and supported allocations.",
      "Classifications include ordinary expense, stock, consumables, CapEx equipment and small tools. Confirmed lines feed the operational registers and supported accounting allocation.",
      "Do not enter a second supplier invoice in Stock for the same purchase. Unbalanced totals and unresolved tax evidence need review."
    ],
    "procedure": [
      "Open Review Items and the source purchase.",
      "Review/classify each line and its amounts.",
      "Balance against the source document and confirm using the displayed action."
    ]
  },
  {
    "id": "stock.overview",
    "module": "stock",
    "moduleSlug": "stock_equipment",
    "title": "Stock and equipment registers",
    "keywords": [
      "stock equipment",
      "stock to sell",
      "materials supplies",
      "small tools",
      "capex equipment"
    ],
    "navigation": "Stock",
    "facts": [
      "Tabs are Stock to Sell, Consumables / Used on Jobs, CapEx Equipment, Small Tools, Stocktakes & Adjustments and Activity.",
      "Reviewed purchase lines feed these registers. Operational stock quantities, asset information and accounting postings are related but are not interchangeable.",
      "Use source-document links and Activity to trace changes; do not create a duplicate expense to add an existing item."
    ],
    "procedure": [
      "Classify the source purchase in Expenses → Review Items.",
      "Open the corresponding Stock tab.",
      "Review its source and Activity."
    ]
  },
  {
    "id": "stock.movements",
    "module": "stock",
    "moduleSlug": "stock_equipment",
    "title": "Stock use, sales and stocktakes",
    "keywords": [
      "stocktake",
      "use on job",
      "adjust quantity",
      "sell on invoice",
      "stock movement",
      "low stock"
    ],
    "navigation": "Stock → relevant stock tab; Stocktakes & Adjustments",
    "facts": [
      "Supported movement actions include Use on job, Adjust quantity, Stocktake and Sell on invoice where shown.",
      "Select the correct job/invoice line and quantity. A stock movement is not permission to invent an automatic tax, depreciation or cost-of-sales posting.",
      "Activity keeps movement history and source links; review negative/insufficient quantities rather than bypassing validation."
    ],
    "procedure": [
      "Open the item.",
      "Choose the appropriate movement and linked record.",
      "Enter the verified quantity and review Activity afterward."
    ]
  },
  {
    "id": "stock.assets",
    "module": "stock",
    "moduleSlug": "stock_equipment",
    "title": "Equipment and disposal review",
    "keywords": [
      "equipment register",
      "asset disposal",
      "depreciation",
      "small tool",
      "asset purchase"
    ],
    "navigation": "Stock → CapEx Equipment or Small Tools",
    "facts": [
      "Asset details include supported purchase, business-use and tax/accounting review information. Disposed assets retain their history.",
      "Use the displayed review/disposal controls; never promise automatic depreciation schedules or postings unless the current action and supplied context establish them.",
      "A loan setup alone does not record purchase of a vehicle or equipment asset. Record/link the actual acquisition through the existing purchase workflow."
    ],
    "procedure": [
      "Open the asset and source purchase.",
      "Review the dates, business use and supported asset actions.",
      "Resolve accountant review flags before relying on tax/accounting treatment."
    ]
  },
  {
    "id": "payroll.employee",
    "module": "payroll",
    "moduleSlug": "payroll",
    "title": "Employees and payroll setup",
    "keywords": [
      "add employee",
      "employee setup",
      "staff limit",
      "employment details",
      "payroll settings"
    ],
    "navigation": "Payroll → Employees; Settings",
    "facts": [
      "Add an employee using the employee form and required employment/pay/tax details. Employee limits depend on the business plan.",
      "Payroll Settings controls supported pay defaults and filing contact information. Historical earnings/leave evidence must be entered as history, not duplicated as a new live pay run.",
      "Protect employee private information; the helper does not expose personal or tax identifiers."
    ],
    "procedure": [
      "Open Employees and add/edit the employee.",
      "Review employment, pay and required tax details.",
      "Save Employee and check payroll defaults."
    ]
  },
  {
    "id": "payroll.timesheets",
    "module": "payroll",
    "moduleSlug": "payroll",
    "title": "Timesheets",
    "keywords": [
      "timesheet",
      "approve hours",
      "payroll hours",
      "timesheet expenses",
      "schedule payroll"
    ],
    "navigation": "Payroll → Timesheets",
    "facts": [
      "Create/edit supported timesheets, check dates/hours/breaks and linked job information, then approve as required.",
      "Schedule can create draft time entries through its existing option. Review them before payroll; avoid entering the same time twice.",
      "Finalised pay-run protections prevent reusing already paid time."
    ],
    "procedure": [
      "Review Timesheets.",
      "Correct draft hours/breaks and employee/job links.",
      "Approve eligible time before building the pay run."
    ]
  },
  {
    "id": "payroll.run",
    "module": "payroll",
    "moduleSlug": "payroll",
    "title": "Calculate and finalise payroll",
    "keywords": [
      "new pay run",
      "run payroll",
      "finalise payroll",
      "calculate pay",
      "payslip",
      "pay employees"
    ],
    "navigation": "Payroll → New Pay Run; Pay Runs",
    "facts": [
      "Prepare the period and pay date, choose employees/time, calculate and review the pay run, then use its save/finalise actions.",
      "Finalising posts payroll accounting; it does not automatically send wages through a bank or file with IRD.",
      "Pay Runs exposes the saved details and supported payslip/PDF/email actions. Review PAYE, KiwiSaver, student loan and any manual changes before finalising."
    ],
    "procedure": [
      "Open New Pay Run and verify period/pay date.",
      "Calculate and review employee lines.",
      "Save/finalise only after checking the figures, then use the saved run actions."
    ]
  },
  {
    "id": "payroll.leave",
    "module": "payroll",
    "moduleSlug": "payroll",
    "title": "Leave management and balances",
    "keywords": [
      "leave management",
      "annual leave",
      "sick leave",
      "leave balance",
      "carry forward",
      "leave request"
    ],
    "navigation": "Payroll → Leave Management; employee leave details",
    "facts": [
      "Leave Management provides the supported request/review/approve/decline workflow. Employee leave details contain balances and historical evidence.",
      "Opening, accrued, taken, carry-forward and current balances are different measures; use the displayed period and units.",
      "Annual holidays, sick leave and other statutory leave use different NZ rules and evidence. Do not assume all leave accrues monthly or invent a legal entitlement from a start date."
    ],
    "procedure": [
      "Open Leave Management or the employee leave details.",
      "Review balance/history and dates/units.",
      "Use the authorised approval or evidence workflow shown."
    ]
  },
  {
    "id": "payroll.statutory",
    "module": "payroll",
    "moduleSlug": "payroll",
    "title": "NZ statutory leave and final pay",
    "keywords": [
      "public holiday",
      "otherwise working day",
      "bereavement",
      "family violence",
      "final pay",
      "termination pay"
    ],
    "navigation": "Payroll → employee/pay-run leave and final-pay controls",
    "facts": [
      "NZ annual holiday, statutory leave, public holiday and final-pay calculations use the existing evidence/rules modules and review controls.",
      "Otherwise-working-day determinations, historical earnings and leave evidence can be required. Do not bypass missing evidence or claim automatic finalisation.",
      "Use only the final-pay controls actually offered for the employee/run. Do not treat isolated preview/test pages as subscriber features."
    ],
    "procedure": [
      "Open the relevant employee/pay-run action.",
      "Supply required historical and working-day evidence.",
      "Review the calculated result and required approvals before posting."
    ]
  },
  {
    "id": "payroll.ird",
    "module": "payroll",
    "moduleSlug": "payroll",
    "title": "IRD payday filing",
    "keywords": [
      "ird payday filing",
      "mark payroll filed",
      "hei2",
      "payday csv",
      "ird filing reminder"
    ],
    "navigation": "Payroll → Pay Runs → IRD filing controls",
    "facts": [
      "Prepare filing from a finalised pay run, review validation, and use the available IRD summary/upload download actions.",
      "Downloading or preparing a file does not file with IRD. Complete the external myIR step and record the filing status/reference in Frindly.",
      "Dashboard Needs attention and Schedule reuse filing records. A finalised run not marked filed generates an IRD reminder."
    ],
    "procedure": [
      "Open the finalised pay run and filing controls.",
      "Resolve validation and download the supported package/file.",
      "File through the actual available filing channel, then mark filed with its reference."
    ]
  },
  {
    "id": "payroll.settlement",
    "module": "payroll",
    "moduleSlug": "payroll",
    "title": "Record wages and payroll liability payments",
    "keywords": [
      "record wages paid",
      "payroll payment",
      "paye payment",
      "kiwisaver payment",
      "payroll liability"
    ],
    "navigation": "Payroll / Financials → existing payment controls",
    "facts": [
      "Payroll accounting, wage payments and payments of IRD payroll liabilities are separate steps. Use the existing Record payment workflow for the specific obligation.",
      "Choose amount, actual payment date and bank. Posting occurs when recorded; bank matching confirms the existing payment without creating another one.",
      "Do not mark a pay run filed merely to remove an unpaid liability, or record the same wages as an ordinary expense again."
    ],
    "procedure": [
      "Open the obligation/payment action.",
      "Check what is being paid and choose the bank/date.",
      "Record once, then match the existing payment if using Banking."
    ]
  },
  {
    "id": "bank.import",
    "module": "bank",
    "moduleSlug": "bank_reconciliation",
    "title": "Import bank statements",
    "keywords": [
      "bank csv",
      "import bank statement",
      "column mapping",
      "duplicate bank upload"
    ],
    "navigation": "Banking → Import",
    "facts": [
      "Choose the bank account and CSV file, review detected columns/mapping and preview, then Import new transactions.",
      "Existing import detection helps prevent duplicates. Statement lines are evidence, not automatically posted receipts/payments just because imported.",
      "Use supported bank formats/mappings and resolve duplicates before importing again."
    ],
    "procedure": [
      "Choose the account and CSV.",
      "Review mapping and duplicate results.",
      "Import only new transactions and open Reconcile."
    ]
  },
  {
    "id": "bank.reconcile",
    "module": "bank",
    "moduleSlug": "bank_reconciliation",
    "title": "Match existing payments",
    "keywords": [
      "bank reconciliation",
      "find match",
      "match payment",
      "statement date",
      "already paid invoice"
    ],
    "navigation": "Banking → Reconcile",
    "facts": [
      "Use the suggested Match or Find Match to select the existing invoice/bill/payment/refund/cash record. Check account, amount, party and date.",
      "Recording a payment does not require Banking. Matching should confirm/update the existing payment and journal date through its supported path, without reposting.",
      "Grouped/split matches allocate existing amounts. The same amount alone is not proof of the same transaction; do not match to another customer or a demo account."
    ],
    "procedure": [
      "Select the statement line.",
      "Review the suggested record or Find Match.",
      "Confirm the correct existing payment and allocation."
    ]
  },
  {
    "id": "bank.other",
    "module": "bank",
    "moduleSlug": "bank_reconciliation",
    "title": "Other bank actions and undo",
    "keywords": [
      "split bank transaction",
      "transfer bank",
      "deposit refund",
      "stripe payout",
      "exclude transaction",
      "undo reconciliation"
    ],
    "navigation": "Banking → Reconcile; Reconciled",
    "facts": [
      "Available actions include supported Create Expense, Split, Transfer, Exclude, refund/deposit, payroll/IRD, owner/equity and Stripe payout workflows.",
      "Prefer an existing recorded payment where one exists. A Stripe payout is not a second customer sale.",
      "Use Reconciled history and its existing undo action with a reason. Undoing a match preserves existing posted payments; it is distinct from reversing a payment."
    ],
    "procedure": [
      "Choose the correct existing action for the statement line.",
      "Review allocations/source records.",
      "Use Reconciled history to inspect or undo a wrong match safely."
    ]
  },
  {
    "id": "bank.feeds",
    "module": "bank",
    "moduleSlug": "bank_reconciliation",
    "title": "Bank feeds availability",
    "keywords": [
      "bank feed",
      "akahu",
      "bank sync",
      "automatic bank connection"
    ],
    "navigation": "Banking → available account/import settings",
    "facts": [
      "CSV import is confirmed. Module catalogue entries for bank feeds do not prove that a bank-feed connection is available or active in this business.",
      "Only describe a live connection setup if the current screen and supplied access/context establish it; otherwise direct the user to the available CSV workflow and support."
    ],
    "procedure": [
      "Check the bank settings actually available.",
      "Use Import for CSV statements if no active feed workflow is shown."
    ]
  },
  {
    "id": "financials.overview",
    "module": "financials",
    "moduleSlug": "financials",
    "title": "Financials and reports navigation",
    "keywords": [
      "financials tabs",
      "estimated summary",
      "accounting pnl",
      "more financial reports"
    ],
    "navigation": "Financials",
    "facts": [
      "Main tabs include Estimated Summary, Accounting P&L, Money In & Out, Loans & Finance, GST Returns, Budget and Owner Current Accounts.",
      "More financial reports provides Balance Sheet, Statement of Cash Flows, Cash Book, General Ledger and Trial Balance. For My Accountant opens the existing accountant workflow.",
      "Estimated summaries and posted accounting reports may differ because of draft/unposted entries, timing or evidence gaps. Do not manufacture balancing transactions."
    ],
    "procedure": [
      "Select the period.",
      "Choose the appropriate report/tab.",
      "Drill into source transactions and review warnings when comparing figures."
    ]
  },
  {
    "id": "financials.cash",
    "module": "financials",
    "moduleSlug": "financials",
    "title": "Record other money in and out",
    "keywords": [
      "money in and out",
      "record money in",
      "record money out",
      "other receipt",
      "other payment",
      "transfer between accounts"
    ],
    "navigation": "Financials → Money In & Out",
    "facts": [
      "Use Record money in, Record money out or Transfer between accounts for supported movements not already recorded by invoices, expenses or payroll.",
      "Choose the purpose, actual date/amount and bank; other-category options require an appropriate allowed account and GST treatment.",
      "This records accounting only; it does not send money through the bank. Cash Book and reconciliation reuse the linked records. Do not duplicate invoice/expense payments here."
    ],
    "procedure": [
      "Choose the direction and purpose.",
      "Enter date, full amount, bank and required details.",
      "Review and record once."
    ]
  },
  {
    "id": "financials.ownerfunds",
    "module": "financials",
    "moduleSlug": "financials",
    "title": "Owner funds, drawings and investment",
    "keywords": [
      "owner money added",
      "shareholder loan",
      "capital introduced",
      "owner withdrawal",
      "investment capital",
      "repay owner"
    ],
    "navigation": "Financials → Money In & Out; Owner Current Accounts",
    "facts": [
      "Repayable owner/shareholder money and permanent investment/share capital are different purposes. Select the correct owner and supported purpose.",
      "Owner Current Accounts shows linked balances and transactions; shareholder/director loans are not ordinary sales.",
      "An owner withdrawal, loan repayment and legally approved share-capital return are not interchangeable categories."
    ],
    "procedure": [
      "Confirm whether the funds are repayable or permanent.",
      "Use the matching Money In/Out purpose and owner.",
      "Review the linked owner balance."
    ]
  },
  {
    "id": "financials.capital",
    "module": "financials",
    "moduleSlug": "financials",
    "title": "Share buyback and return of capital",
    "keywords": [
      "share buyback",
      "return of share capital",
      "outgoing shareholder",
      "equity allocation",
      "cancel shares"
    ],
    "navigation": "Financials → Money In & Out → Record money out",
    "facts": [
      "Share Buyback and Return of Share Capital apply to eligible NZ companies, not sole traders/proprietors or a private purchase between shareholders.",
      "Select the shareholder receiving the payment, usually the outgoing shareholder. Use the legally approved equity allocation; a buyback is not automatically entirely share capital.",
      "Approvals, solvency/tax review and non-duplication confirmations are required. The payment has no operating P&L impact; use the app’s no-GST capital treatment, not ordinary purchase GST.",
      "Payment and shareholding change are separately confirmed linked actions. An additional payment can link to the same completed share change without cancelling shares twice; Frindly does not update the Companies Register."
    ],
    "procedure": [
      "Choose the capital-payment purpose and recipient.",
      "Use the approved allocation and required authorisation evidence.",
      "Record the payment, then review its separate linked shareholding-change action if applicable."
    ]
  },
  {
    "id": "financials.shareholders",
    "module": "financials",
    "moduleSlug": "financials",
    "title": "Owners, directors and shareholding history",
    "keywords": [
      "owners directors shareholders",
      "shareholding change",
      "ownership percentage",
      "shares held",
      "director resigned"
    ],
    "navigation": "Settings → Tax & Accounting → Owners, Directors & Shareholders",
    "facts": [
      "This register maintains people, roles, ownership/share details, effective dates and status. It is distinct from Owner Current Accounts accounting balances.",
      "Edit actions retain effective-dated history. A full exit can make shares zero only through the confirmed appropriate shareholding-change workflow, not simply because a payment was entered.",
      "Director resignation and shareholder exit are separate. Do not remove a person’s historical records or assume a buyback means they cease being a director."
    ],
    "procedure": [
      "Open the register and the relevant person.",
      "Review history and the effective date.",
      "Use the supported change action and confirm the actual share event."
    ]
  },
  {
    "id": "financials.deposits",
    "module": "financials",
    "moduleSlug": "financials",
    "title": "Refundable deposits and bonds",
    "keywords": [
      "refundable deposit",
      "bond paid",
      "deposit returned",
      "rental deposit",
      "grant subsidy",
      "bank interest"
    ],
    "navigation": "Financials → Money In & Out",
    "facts": [
      "Supported purposes include Refundable deposit or bond, Refundable deposit returned, Grant or subsidy and Bank interest received.",
      "A refundable bond/return is not automatically expense/sales income. The rental charge itself follows the ordinary expense workflow; use the linked deposit purpose for the refundable portion.",
      "Do not force an incorrect sales/expense entry just to match an external return. Review actual documents and tax treatment with the accountant when uncertain."
    ],
    "procedure": [
      "Separate the charge from the refundable amount.",
      "Choose the correct deposit/return or other purpose.",
      "Review bank/date and any required GST evidence."
    ]
  },
  {
    "id": "financials.taxpayments",
    "module": "financials",
    "moduleSlug": "financials",
    "title": "GST refunds and tax payments",
    "keywords": [
      "gst refund received",
      "record refund received",
      "income tax refund",
      "provisional tax",
      "record gst payment",
      "one cent rounding"
    ],
    "navigation": "Financials → GST Returns / existing liability payment dialog",
    "facts": [
      "GST payments/refunds use the return’s existing Record payment / Record Refund Received workflow, including bank, actual date and outstanding amount.",
      "Income-tax payment/refund purposes are available in Money In & Out with the required owner/business classification. They are not ordinary sales or supplier expenses.",
      "Small settlement differences use the supported rounding/difference validation, not invented GST or a duplicate payment. Read the form message if the amount cannot be accepted."
    ],
    "procedure": [
      "Open the specific return/obligation.",
      "Enter the actual bank amount/date and review any difference message.",
      "Record once and inspect payment history."
    ]
  },
  {
    "id": "financials.reverse",
    "module": "financials",
    "moduleSlug": "financials",
    "title": "Reverse a recorded bank movement",
    "keywords": [
      "reverse gst refund",
      "reverse payment",
      "reverse money in",
      "reverse money out",
      "reverse transfer",
      "view details"
    ],
    "navigation": "Financials → Money In & Out / Cash Book → View details",
    "facts": [
      "Open the existing movement and use its supported reversal action or linked original workflow. Record a reason and appropriate reversal date.",
      "Reversal preserves the original and adds the linked reversing accounting entry; it is not deletion. A transfer must be reversed consistently across both bank legs.",
      "A reconciliation match is separate: undo/unmatch through Banking as required. Posted/closed/filed safeguards still apply; do not enter another unrelated opposite transaction to hide an error."
    ],
    "procedure": [
      "Open View details for the original movement.",
      "Follow the existing reverse/manage-original action.",
      "Review bank matching and balances before recording a corrected replacement."
    ]
  },
  {
    "id": "loans.setup",
    "module": "financials",
    "moduleSlug": "financials",
    "title": "Loan setup and funding",
    "keywords": [
      "add loan",
      "loans finance",
      "vehicle loan",
      "business loan",
      "original loan amount",
      "record loan funds received"
    ],
    "navigation": "Financials → Loans & Finance",
    "facts": [
      "Add a loan captures lender, original principal, start date, usual bank and repayment terms. Loan setup alone does not post the loan proceeds or asset purchase.",
      "Use Record loan funds received for money actually received by the business; use Lender paid supplier when the lender paid the supplier directly.",
      "The recorded amount owing comes from posted movements, not just the original amount field. Avoid recording funding again if already posted."
    ],
    "procedure": [
      "Add the loan and verified terms.",
      "Record its actual funding through the matching existing action.",
      "Check the posted loan balance and purchase/source link."
    ]
  },
  {
    "id": "loans.repayments",
    "module": "financials",
    "moduleSlug": "financials",
    "title": "Loan repayment splits and schedule",
    "keywords": [
      "loan repayment",
      "interest capital split",
      "repayment schedule",
      "monthly loan",
      "principal interest",
      "regular repayment"
    ],
    "navigation": "Financials → Loans & Finance → loan → Record repayment",
    "facts": [
      "Amount paid is the whole payment including principal, interest and any supported fee included in it. Interest/fee portions are entered/reviewed separately; the remaining principal reduces the liability.",
      "The schedule estimates repayments from the loan terms or uses an imported lender schedule. It does not automatically pay or post monthly instalments.",
      "Use the lender’s actual split when it differs from the estimate. Planned rows are not Cash Book movements or bank-match candidates until recorded.",
      "Interest costs and principal reductions have different accounting effects. The repayment is not wholly an operating expense."
    ],
    "procedure": [
      "Open the loan/instalment.",
      "Choose Record payment or Record repayment.",
      "Verify actual paid date, full amount, interest/fees and bank, then record once."
    ]
  },
  {
    "id": "loans.changes",
    "module": "financials",
    "moduleSlug": "financials",
    "title": "Loan changes and balance sheet classification",
    "keywords": [
      "loan top up",
      "extra principal",
      "interest only",
      "update loan terms",
      "current long term liability",
      "lender paid supplier"
    ],
    "navigation": "Financials → Loans & Finance → loan actions",
    "facts": [
      "Existing actions include Loan top-up, Extra principal payment, Interest-only payment, Lender paid supplier, Update loan terms and Close loan.",
      "Direct lender-to-supplier finance uses the existing supplier/loan workflow without inventing a business-bank receipt and payment.",
      "Current versus long-term liability classification uses supported repayment/maturity evidence as of the report date. Missing evidence can show Classification needs review.",
      "Check a lender statement compares the lender amount/date with recorded balances. Do not overwrite principal or create a balancing payment just to remove a difference."
    ],
    "procedure": [
      "Select the actual transaction type.",
      "Supply the lender/source evidence and review the effect.",
      "Check loan history and Balance Sheet classification."
    ]
  },
  {
    "id": "financials.pnl",
    "module": "financials",
    "moduleSlug": "financials",
    "title": "Accounting profit and loss",
    "keywords": [
      "profit and loss",
      "accounting pnl",
      "profit margin",
      "estimated summary difference"
    ],
    "navigation": "Financials → Accounting P&L",
    "facts": [
      "Select the period and expand categories/accounts to inspect source transactions. Posted accounting differs from cash movement and planning estimates.",
      "Draft invoices/expenses are excluded from posted reports. Capital, principal loan repayments and internal bank transfers are not operating sales/costs.",
      "Use the existing classification/mapping workflow for categorisation issues; the helper must not invent or post a journal."
    ],
    "procedure": [
      "Choose the period.",
      "Expand the relevant line to inspect its source.",
      "Compare like-for-like dates and posted status when reconciling differences."
    ]
  },
  {
    "id": "financials.cashbook",
    "module": "financials",
    "moduleSlug": "financials",
    "title": "Cash Book and bank balances",
    "keywords": [
      "cash book",
      "opening book balance",
      "closing book balance",
      "bank ledger",
      "running balance"
    ],
    "navigation": "Financials → More financial reports → Cash Book",
    "facts": [
      "Cash Book shows posted cash/bank movements. Opening Book Balance is at the report start; it includes earlier opening balances and intervening posted movements.",
      "Select Opening book balance or Closing book balance to drill into each bank account. The bank book balance is not necessarily the bank statement’s reconciled balance.",
      "Do not hide historical accounts with posted balances or repost an existing movement to make labels agree."
    ],
    "procedure": [
      "Select the period.",
      "Open the balance drill-down or transaction details.",
      "Compare the same bank and dates against the statement."
    ]
  },
  {
    "id": "financials.balance",
    "module": "financials",
    "moduleSlug": "financials",
    "title": "Balance Sheet and ledger reports",
    "keywords": [
      "balance sheet",
      "general ledger",
      "trial balance",
      "statement cash flows",
      "missing vehicle loan"
    ],
    "navigation": "Financials → More financial reports",
    "facts": [
      "Balance Sheet shows posted assets, liabilities and equity as of the selected date. Select sections/accounts for the existing transaction drill-down.",
      "A vehicle asset and its loan liability arise from recorded acquisition/funding; creating a loan name or schedule alone does not create an asset.",
      "General Ledger, Trial Balance and Statement of Cash Flows provide different views of existing postings. Preserve historical journals when investigating differences."
    ],
    "procedure": [
      "Choose the report and date.",
      "Expand the account and source transactions.",
      "Check whether acquisition/funding and payments were actually posted."
    ]
  },
  {
    "id": "financials.budget",
    "module": "financials",
    "moduleSlug": "financials",
    "title": "Budget and planning",
    "keywords": [
      "budget",
      "activate budget",
      "acc levy estimate",
      "income tax estimate",
      "forecast"
    ],
    "navigation": "Financials → Budget; Tax & Accounting planning controls",
    "facts": [
      "Budget supports the existing create/edit/activate workflow and period comparisons. Budgets are plans, not posted bank movements.",
      "ACC and estimated income-tax planning use the supported inputs/evidence. An estimate does not mean a bill is filed, paid or legally assessed."
    ],
    "procedure": [
      "Open Budget and choose the year/version.",
      "Enter/review amounts, save and activate using the displayed controls.",
      "Keep estimates separate from actual posted liabilities."
    ]
  },
  {
    "id": "gst.return",
    "module": "gst",
    "moduleSlug": "financials",
    "title": "Prepare and file a GST return",
    "keywords": [
      "gst return",
      "gst worksheet",
      "gst collected",
      "gst paid",
      "download gst",
      "mark gst filed"
    ],
    "navigation": "Financials → GST Returns",
    "facts": [
      "Choose the period and calculation basis, review sales/purchases/adjustments and evidence warnings, then use supported save/export/filing actions.",
      "Business default follows effective-dated settings; an explicit Payments/Invoice/Hybrid selection previews that basis for the period. Mixed historical settings can make results differ.",
      "A finalised return uses its locked saved snapshot. Marking filed must match the actual myIR filing; downloading a package is not submission.",
      "IRD Connect here prepares/validates a filing package and records filing references; do not promise automatic submission without an established active connector."
    ],
    "procedure": [
      "Choose the correct period/basis.",
      "Review itemised evidence and resolve blocking warnings.",
      "Save/export and complete the actual filing step, then record its status/reference."
    ]
  },
  {
    "id": "gst.basis",
    "module": "gst",
    "moduleSlug": "financials",
    "title": "Correct or change GST basis",
    "keywords": [
      "change gst basis",
      "review change basis",
      "business default payments",
      "historical gst correction",
      "invoice to payments",
      "hybrid basis"
    ],
    "navigation": "Financials → GST Returns → Review / change basis",
    "facts": [
      "Distinguish correction of incorrect unfiled configuration from an actual IRD-approved change. Actual changes need the approved effective date and transition reconciliation.",
      "Preview, enter reason/approval reference and confirmation of affected filing status, save the request, then Review & apply using freshly checked evidence.",
      "Saving a request alone changes no official settings. Application uses existing settings/adjustment engines; corrections create no wash-up, while actual changes reconcile outstanding previously reported GST.",
      "Missing historical payments, credits/refunds, postings or prior filing evidence can block application. Returns filed directly in myIR count even if Frindly has no finalised row. Never silently rewrite a filed snapshot."
    ],
    "procedure": [
      "Open Review / change basis for the affected period.",
      "Choose correction or IRD-approved change and review the preview.",
      "Supply the required evidence and explicitly confirm only when checks permit it."
    ]
  },
  {
    "id": "gst.adjustments",
    "module": "gst",
    "moduleSlug": "financials",
    "title": "GST corrections and filing evidence",
    "keywords": [
      "gst adjustment",
      "late gst",
      "filed return correction",
      "gst registration change",
      "zero rated exempt"
    ],
    "navigation": "Financials → GST Returns; Tax & Accounting",
    "facts": [
      "GST adjustments and registration/basis transitions use supported effective-dated workflows and evidence. Finalised and externally filed periods are protected.",
      "Zero-rated and exempt supplies are different even if GST is zero; unknown classifications require review.",
      "If prior filing evidence is absent or incorrect, obtain the actual filing information and use the supported review/amendment process; do not invent a historic return or balancing sale."
    ],
    "procedure": [
      "Open the affected return/source review.",
      "Identify what was actually filed and why it differs.",
      "Resolve evidence and use the supported adjustment/amendment path."
    ]
  },
  {
    "id": "accountant.centre",
    "module": "accountant_centre",
    "moduleSlug": "financials",
    "title": "Accountant export and chart mappings",
    "keywords": [
      "for my accountant",
      "accountant export",
      "xero export",
      "chart accounts",
      "account mapping",
      "post ledger"
    ],
    "navigation": "Financials → For My Accountant",
    "facts": [
      "The existing accountant centre provides period/source selection, account/tax mappings, readiness validation, supported export packages and export history.",
      "Internal account management and protected posting/mapping controls are permission-restricted. An export does not prove data was imported into Xero or filed with IRD.",
      "Use source links and resolve readiness warnings rather than generating duplicate accounting entries."
    ],
    "procedure": [
      "Open For My Accountant.",
      "Choose period and review mappings/readiness.",
      "Prepare the supported package and retain export history."
    ]
  },
  {
    "id": "reports.overview",
    "module": "reports",
    "moduleSlug": "financials",
    "title": "Business reports",
    "keywords": [
      "business performance",
      "sales money owed",
      "expense reports",
      "job profitability",
      "shareholder summary",
      "payroll reports"
    ],
    "navigation": "Reports",
    "facts": [
      "Tabs include Business Performance, Sales & Money Owed, Expense Reports, Jobs, Payroll and Shareholder Summary.",
      "Select dates and available filters/export controls. Job/customer profitability depends on linked revenue, purchase and labour evidence, not an assumed margin.",
      "Shareholder summaries depend on effective-dated ownership and available accounting evidence. Do not infer private balances from missing context."
    ],
    "procedure": [
      "Open the report tab.",
      "Set dates and filters.",
      "Inspect supporting records before comparing totals or exporting."
    ]
  },
  {
    "id": "settings.main",
    "module": "settings",
    "moduleSlug": "invoice_manager",
    "title": "Settings navigation",
    "keywords": [
      "settings sections",
      "business setup",
      "tax accounting",
      "invoices payments",
      "team access",
      "plan data"
    ],
    "navigation": "Account menu → Settings",
    "facts": [
      "Current section buttons are Business Setup, Tax & Accounting, Invoices & Payments, Quotes & Job Costing, Team & Access and Plan & Data.",
      "These sections host existing settings; they are not separate accounting systems. Some headings inside sections retain legacy wording.",
      "Choose the business first. Changing business details/defaults is not authority to rewrite issued documents or historical tax settings."
    ],
    "procedure": [
      "Open account Settings.",
      "Choose the current section matching the task.",
      "Review the scope/effective date before saving."
    ]
  },
  {
    "id": "settings.banks",
    "module": "settings",
    "moduleSlug": "invoice_manager",
    "title": "Bank setup and opening balances",
    "keywords": [
      "default bank",
      "opening bank balance",
      "bank opening date",
      "add bank account",
      "invoice bank details"
    ],
    "navigation": "Settings → Invoices & Payments → Bank Accounts",
    "facts": [
      "Manage active banks and the default account here, including supported opening balance and opening-balance date controls. Banking module access is not required for setup.",
      "Opening balances feed existing journals, Cash Book, Balance Sheet and dashboard balances. Report-start opening balance can differ from the originally entered opening date because of intervening movements.",
      "Payment forms select the actual bank; one default does not authorise silently moving historical payments from another account. Archive rather than erase posted bank history."
    ],
    "procedure": [
      "Add/review the bank details and ledger setup.",
      "Enter the verified opening amount/date and select the default.",
      "Check the resulting bank balance at the same date."
    ]
  },
  {
    "id": "payments.invoice",
    "module": "settings",
    "moduleSlug": "invoice_manager",
    "title": "Online invoice payments and Stripe",
    "keywords": [
      "stripe connect",
      "pay now",
      "online invoice payment",
      "stripe settlement bank",
      "payment link"
    ],
    "navigation": "Settings → Invoices & Payments → online payment settings",
    "facts": [
      "Stripe Connect/online invoice payment controls require the appropriate entitlement and completed onboarding.",
      "Use the configured Stripe settlement bank/account and existing invoice/payment links. A customer payment, provider fee and bank payout are distinct; do not record the payout as another sale.",
      "Only say payments are enabled or settled when supplied status confirms it. Frindly Helper cannot connect accounts or collect card details."
    ],
    "procedure": [
      "Open online invoice payment settings.",
      "Complete the displayed connection/setup and bank choice.",
      "Review the invoice payment status and match the eventual payout using the existing workflow."
    ]
  },
  {
    "id": "settings.access",
    "module": "settings",
    "moduleSlug": "invoice_manager",
    "title": "Team permissions and business switching",
    "keywords": [
      "invite user",
      "team role",
      "permissions",
      "switch business",
      "multiple businesses",
      "access denied"
    ],
    "navigation": "Settings → Team & Access; account business switcher",
    "facts": [
      "Team & Access manages supported invitations, members, roles and custom permissions. Module subscription and user permission are separate access requirements.",
      "Use the account business switcher to select an authorised business. Data is business-scoped; never suggest another tenant’s records as evidence.",
      "Only authorised roles may change access. Do not bypass missing permissions or assume a hidden control is a product failure."
    ],
    "procedure": [
      "Confirm the active business.",
      "Open Team & Access to review permitted members/roles.",
      "Use the existing invite or permission controls if authorised."
    ]
  },
  {
    "id": "settings.subscription",
    "module": "settings",
    "moduleSlug": "invoice_manager",
    "title": "Plans, billing and data",
    "keywords": [
      "subscription billing",
      "upgrade plan",
      "cancel subscription",
      "annual plan",
      "data export",
      "plan modules"
    ],
    "navigation": "Settings → Plan & Data",
    "facts": [
      "Plan & Data hosts subscription/billing, module and data/import/export controls. Actual plans/prices/status come from current business data, not hardcoded helper prices.",
      "Existing subscription extensions/trials influence access; the helper cannot grant extensions, unlock modules or promise a billing change.",
      "Use the billing portal/plan controls offered for the authorised role and confirm the displayed change date."
    ],
    "procedure": [
      "Open Plan & Data.",
      "Review current subscription/module status.",
      "Use the supported billing/data action and inspect its confirmation."
    ]
  },
  {
    "id": "settings.security",
    "module": "settings",
    "moduleSlug": "invoice_manager",
    "title": "Account profile and password",
    "keywords": [
      "change password",
      "forgot password",
      "reset password",
      "account profile",
      "preferences"
    ],
    "navigation": "Account menu → Account Settings / sign-in recovery",
    "facts": [
      "Account Settings provides the existing profile/preferences and Change Password action. Forgotten passwords use the supported sign-in recovery flow.",
      "Keep credentials, reset codes and private account data out of chat. Google sign-in is available only where actually configured."
    ],
    "procedure": [
      "Open Account Settings for profile/password changes.",
      "Use Forgot password from sign-in when unable to access the account."
    ]
  },
  {
    "id": "import.records",
    "module": "import_migration",
    "moduleSlug": "invoice_manager",
    "title": "Smart Migration Centre",
    "keywords": [
      "import migration",
      "smart migration",
      "csv excel",
      "import invoices",
      "historical records",
      "opening stock"
    ],
    "navigation": "Settings → Plan & Data → Import & Migration",
    "facts": [
      "Smart Migration Centre accepts CSV/Excel, detects record types and groups related rows. Review mapping, validation, duplicates and per-record actions before confirmation.",
      "Supported modes include master records, read-only history, live opening balances, quotes, opening stock/assets, employee setup and read-only payroll history where validated.",
      "Availability depends on the detected type and review result; not every uploaded row becomes a live financial/payroll transaction. Preserve source and import history; do not reimport paid amounts as fresh sales/pay runs."
    ],
    "procedure": [
      "Upload CSV/Excel.",
      "Check mappings, grouped records and validation.",
      "Choose supported import/skip/history actions and review before confirming."
    ]
  },
  {
    "id": "community.current",
    "module": "community",
    "moduleSlug": "community",
    "title": "Community posts and messages",
    "keywords": [
      "community",
      "business network",
      "community post",
      "private message",
      "advertise",
      "banner campaign"
    ],
    "navigation": "Community",
    "facts": [
      "Community supports the existing profile, posts/comments, inbox/private messages, reporting and advertising workflows when enabled.",
      "Audience visibility, moderation and campaign approval/payment controls remain in force. A private message is not an invoice or support ticket.",
      "Only authorised administrators use moderation controls. The helper does not post, message or buy advertising for the user."
    ],
    "procedure": [
      "Open Community and review the active profile.",
      "Choose the existing post, comment, inbox or advertising action.",
      "Review visibility/content before submitting."
    ]
  },
  {
    "id": "helper.support",
    "module": "helper",
    "moduleSlug": "finlo_helper",
    "title": "Helper, voice and human support",
    "keywords": [
      "talk to a person",
      "human support",
      "helper voice",
      "rename helper",
      "question allowance",
      "ask frindly"
    ],
    "navigation": "Floating Ask button → chat; Talk to a person",
    "facts": [
      "The floating Ask button opens this helper. Its name can be business-configured; the button and desktop panel retain draggable saved positions.",
      "Typed questions, quick starters and available dictation/Live Voice controls use existing entitlements/allowances. Do not promise unlimited sessions or unsupported background actions.",
      "Talk to a person opens the existing support workflow. Support offers message details and supported attachments/history; do not invent an attachment control in the AI composer.",
      "Microphone permissions and device support can affect voice availability. Never change subscription or privacy settings to troubleshoot without authorisation."
    ],
    "procedure": [
      "Open the Ask button and type or use an available voice control.",
      "Use Talk to a person for the human support form/history."
    ]
  },
  {
    "id": "admin.controls",
    "module": "settings",
    "moduleSlug": "invoice_manager",
    "title": "Restricted administration",
    "keywords": [
      "super admin",
      "admin business",
      "extend subscription",
      "module manager",
      "payroll compliance rules"
    ],
    "navigation": "Super Admin portal (authorised administrators only)",
    "facts": [
      "The restricted portal includes existing business/subscription/module management, plans, payment-provider configuration, helper/Live Voice controls and compliance-rule review.",
      "These are not ordinary subscriber settings. Only explain specific admin actions when the supplied context establishes the authorised administrator view; never provide a bypass.",
      "A draft compliance rule or test/preview page is not an active statutory rule. Activated settings and audit controls remain authoritative."
    ],
    "procedure": [
      "Use the authorised admin portal only.",
      "Review the exact business, status and confirmation for the existing action."
    ]
  },
  {
    "id": "expenses.purchaseorders",
    "module": "expenses",
    "moduleSlug": "expenses",
    "title": "Purchase orders",
    "keywords": [
      "purchase order",
      "new purchase order",
      "po approval",
      "send po",
      "supplier order"
    ],
    "navigation": "Expenses → Purchase Orders",
    "facts": [
      "Use + New Purchase Order to prepare a supplier order with supported review/approval, PDF and email controls.",
      "Purchase orders do not post accounting. Receiving an invoice/bill is a separate existing expense workflow; do not treat an order as a paid supplier bill.",
      "Private cost estimates in the order editor are session-only and are not saved or sent to the supplier."
    ],
    "procedure": [
      "Create/review the order.",
      "Use the displayed save/approval/send actions.",
      "Record the actual supplier bill separately through its linked existing workflow."
    ]
  },
  {
    "id": "customers.statements",
    "module": "customers",
    "moduleSlug": "invoice_manager",
    "title": "Customer statements and late-fee helper",
    "keywords": [
      "customer statement",
      "statement csv",
      "late payment fee",
      "late fee"
    ],
    "navigation": "Invoices → Customers → statement controls; invoice settings",
    "facts": [
      "Customer statement controls select the customer and period and provide supported statement/CSV output from existing records.",
      "The optional late-fee helper uses configured grace days and fixed/percentage values to prepare guidance/draft invoicing. It does not silently charge a fee or post an invoice.",
      "Review customer terms and the actual overdue balance; do not claim a fee is legally owed merely because the helper can estimate it."
    ],
    "procedure": [
      "Select the customer and statement dates.",
      "Review transactions before downloading.",
      "Use the displayed draft/review workflow for any late fee."
    ]
  },
  {
    "id": "financials.manualjournal",
    "module": "financials",
    "moduleSlug": "financials",
    "title": "Manual journals and provisional tax planning",
    "keywords": [
      "manual journal",
      "reverse journal",
      "provisional tax plan",
      "journal correction"
    ],
    "navigation": "Financials → More financial reports → Manual Journals / Provisional Tax Plan",
    "facts": [
      "Manual Journals is an accountant/admin-only correction workflow. Posted journals must balance and can only be reversed through supported controls.",
      "Provisional Tax Plan is a planning worksheet: it does not file with IRD or post journals.",
      "Prefer the original invoice/expense/payment correction workflow when available; a manual journal must not duplicate its original posting."
    ],
    "procedure": [
      "Open the relevant existing report/control if authorised.",
      "Review source records and period restrictions.",
      "Use the supported review/post/reversal or planning action."
    ]
  },
  {
    "id": "financials.yearend",
    "module": "financials",
    "moduleSlug": "financials",
    "title": "Year-end readiness and accounting integrity",
    "keywords": [
      "year end readiness",
      "accounting integrity",
      "close period",
      "holiday liability",
      "accounting validation"
    ],
    "navigation": "Financials → available accounting/settings controls",
    "facts": [
      "The existing readiness/integrity checks identify evidence, mapping and posting issues. A readiness check does not itself finalise all accounts or file returns.",
      "Closed-period controls restrict edits/postings. Follow the authorised review workflow rather than bypassing a lock.",
      "Holiday-pay liability posting is a separate supported reviewed action, not permission for the helper to estimate and post an amount."
    ],
    "procedure": [
      "Run the displayed readiness/integrity check.",
      "Inspect its source/evidence warnings.",
      "Resolve issues through the existing permitted workflow before closing or finalising."
    ]
  },
  {
    "id": "settings.templates",
    "module": "settings",
    "moduleSlug": "invoice_manager",
    "title": "Invoice and quote design settings",
    "keywords": [
      "invoice template",
      "quote template",
      "logo invoice",
      "reminder email template",
      "invoice numbering",
      "email activity"
    ],
    "navigation": "Settings → Invoices & Payments / Quotes & Job Costing; existing Email Activity view",
    "facts": [
      "Existing invoice/quote settings manage supported document design, business/logo, terms, numbering and email/reminder defaults.",
      "Email Activity provides the existing delivery history and paged navigation where shown. Sending, delivery and customer receipt are different states.",
      "A template/default change does not rewrite an already issued document or authorise resending it automatically."
    ],
    "procedure": [
      "Choose the matching settings section.",
      "Preview the design/details and save through the existing control.",
      "Check Email Activity for the document when investigating delivery."
    ]
  },
  {
    "id": "settings.referrals",
    "module": "settings",
    "moduleSlug": "invoice_manager",
    "title": "Referral programme",
    "keywords": [
      "referral link",
      "refer business",
      "referral reward",
      "refer a friend"
    ],
    "navigation": "Account menu → available referral shortcut",
    "facts": [
      "An active referral programme can show the existing referral portal/link and campaign details. Availability and rewards come from current programme status.",
      "Do not invent a commission, reward amount or approval; use only what the portal confirms."
    ],
    "procedure": [
      "Open the referral shortcut if available.",
      "Review the current programme and copy the existing referral link."
    ]
  }
];
export const MODULE_LABELS = {"dashboard": "Dashboard", "schedule": "Schedule", "invoices": "Invoices", "customers": "Customers", "quotes": "Quotes", "jobcosting": "Job Costing", "expenses": "Expenses", "suppliers": "Suppliers", "stock": "Stock", "stock-equipment": "Stock", "payroll": "Payroll", "bank": "Banking", "bankreconciliation": "Banking", "financials": "Financials", "gst": "GST Returns", "reports": "Reports", "accountant_centre": "For My Accountant", "settings": "Settings", "import_migration": "Import & Migration", "onboarding": "Quick setup", "helper": "Frindly Helper"};
const normalize=(s)=>String(s||'').toLowerCase().replace(/[^a-z0-9&]+/g,' ').trim();
export function selectProductKnowledge(question,currentModule,limit=3){const stop=new Set(['how','the','and','for','with','add','new','create','record','run','see','where','can','my','do','upload']);const q=normalize(question),tokens=new Set(q.split(/\s+/).filter(x=>x.length>2&&!stop.has(x)));const scored=PRODUCT_KNOWLEDGE.map(k=>{let score=0;for(const kw of k.keywords){const n=normalize(kw);if(q.includes(n))score+=n.includes(' ')?10:5;for(const t of n.split(/\s+/))if(!stop.has(t)&&tokens.has(t))score+=2}if(k.module===currentModule)score+=0.25;return{k,score}}).filter(x=>x.score>=2).sort((a,b)=>b.score-a.score);return scored.slice(0,limit).map(x=>x.k)}