import { defineConfig } from '@playwright/test';

/**
 * Sprint 8 E2E suite. Requires the running system on the classic ports:
 *   - Flask front-end   : http://localhost:4200
 *   - Auth service      : http://localhost:3000
 *   - Trade API (Java)  : http://localhost:8085
 * and PostgreSQL with the creds in sprint8-auth-service/.env.
 */
export default defineConfig({
  testDir: './tests',
  timeout: 60000,
  fullyParallel: false,
  workers: 1,
  retries: 0,
  reporter: [['list']],
  use: {
    baseURL: 'http://localhost:4200',
    trace: 'retain-on-failure',
  },
});