// This branch is reserved for the isolated Frindly Market environment.
window.APP_CONFIG = Object.freeze({
  appName: 'Frindly Market',
  version: 'v62.25-market-atomic-import-review',
  environment: 'market',
  projectRef: 'smvvevrtjqkflyqkyape',
  supabaseUrl: 'https://smvvevrtjqkflyqkyape.supabase.co',
  supabaseKey: 'sb_publishable_S2bA1UlzgrY3sDOpcao_9A_aWAh0fXR',
  defaultTrialDays: 14,
  stripeEnabled: false,
  googleOAuthEnabled: false,
  outboundServicesEnabled: false,
  features: Object.freeze({
    expenseWorkflowV6203: true,
    expenseDuplicateWorkflowV6204: true,
    groupedBankReconciliationV6203: true,
    financialImportV2: false
  })
});
