(() => {
  'use strict';
  const config = window.APP_CONFIG || {};
  const origin = 'https://smvvevrtjqkflyqkyape.supabase.co';
  if (config.environment !== 'market' || config.supabaseUrl !== origin ||
      config.projectRef !== 'smvvevrtjqkflyqkyape' || config.outboundServicesEnabled !== false ||
      config.stripeEnabled !== false || !String(config.supabaseKey || '').startsWith('sb_publishable_')) {
    throw new Error('Frindly Market is not configured for the isolated test database.');
  }
  if (!window.supabase || typeof window.supabase.createClient !== 'function') {
    throw new Error('Frindly Market could not load its database client.');
  }
  const createClient = window.supabase.createClient.bind(window.supabase);
  window.supabase.createClient = (url, key, options = {}) => {
    if (url !== origin || key !== config.supabaseKey) {
      throw new Error('This test environment cannot connect to another database.');
    }
    return createClient(url, key, {
      ...options,
      auth: {
        ...options.auth,
        storageKey: 'frindly-market-smvvevrtjqkflyqkyape-auth-token'
      }
    });
  };
  document.addEventListener('DOMContentLoaded', () => {
    const banner = document.createElement('div');
    banner.className = 'market-environment-banner';
    banner.setAttribute('role', 'status');
    banner.textContent = 'Frindly Market · Isolated test environment · Email, payments and bank connections disabled';
    document.body.prepend(banner);
  }, { once: true });
})();
