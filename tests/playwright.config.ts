import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: './e2e',
  timeout: 30_000,
  expect: { timeout: 5_000 },
  fullyParallel: false,
  workers: 1,
  reporter: [['list'], ['html', { open: 'never' }]],
  use: {
    baseURL: process.env.PLAYWRIGHT_BASE_URL || 'http://localhost:5173',
    // The default letsencrypt_staging=true deploys a staging LE cert that browsers
    // reject as untrusted. Skip cert verification so the e2e can talk to a
    // freshly-deployed droplet without depending on a real cert.
    ignoreHTTPSErrors: true,
    headless: true,
    viewport: { width: 1280, height: 720 },
    actionTimeout: 5_000,
    navigationTimeout: 15_000,
    screenshot: 'on',
    video: 'on',
    trace: 'on',
    extraHTTPHeaders: {
      // The frontend uses [::1] by default; make sure Playwright connects via 127.0.0.1
    },
  },
  projects: [
    {
      name: 'chromium',
      use: {
        ...devices['Desktop Chrome'],
        // Allow recorder tests to use getUserMedia without prompting
        launchOptions: {
          args: [
            '--use-fake-device-for-media-stream',
            '--use-fake-ui-for-media-stream',
            // When running against a remote droplet whose domain DNS is not
            // yet propagated, map the domain directly to the droplet's IP.
            // PLAYWRIGHT_DROPLET_IP is set by scripts/wait-and-test.sh.
            ...(process.env.PLAYWRIGHT_DROPLET_IP
              ? [`--host-resolver-rules=MAP ${process.env.PLAYWRIGHT_BASE_URL?.replace(/^https?:\/\//, '').split('/')[0] || ''} ${process.env.PLAYWRIGHT_DROPLET_IP}`]
              : []),
          ],
        },
      },
    },
  ],
  outputDir: './test-results',
  // Use the cached Chromium (no downloads)
});
