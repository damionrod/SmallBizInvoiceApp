// Public browser configuration. The Supabase publishable key is intentionally safe to ship to browsers.
window.APP_CONFIG = {
  appName: 'Frindly',
  version: 'v62.19',
  supabaseUrl: 'https://oxsbzytwbphagcbilxud.supabase.co',
  supabaseKey: 'sb_publishable_cwPJV4Skg8cjgC6UzKM3xg_O1q5dztU',
  defaultTrialDays: 14,
  stripeEnabled: true,
  googleOAuthEnabled: false,
  features: {
    expenseWorkflowV6203: true,
    expenseDuplicateWorkflowV6204: true,
    groupedBankReconciliationV6203: true,
    financialImportV2: false
  }
};
