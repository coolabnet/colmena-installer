import { test, expect, Page } from '@playwright/test';

const serverUrl = process.env.COLMENA_SERVER_URL || 'http://localhost:8000';

// Helpers for React-controlled inputs
async function setReactInputValue(page: Page, selector: string, value: string) {
  await page.locator(selector).evaluate((el, v) => {
    const proto = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
    proto!.set!.call(el, v);
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
  }, value);
}

// Wait for the SPA to fully mount (PatternFly + React + the route's content)
// Uses 'commit' instead of 'domcontentloaded' because the Vite dev server
// behind Caddy can have slow/stuck module transforms that block the
// domcontentloaded event for 60+ seconds. 'commit' fires when the initial
// HTML response is received, then we wait for React to hydrate via selectors.
async function waitForSpaMount(page: Page) {
  await page.waitForLoadState('commit' as any);
  // Wait for a REAL readiness signal instead of a fixed sleep: React has mounted
  // content into #root. This resolves as soon as the app hydrates (fast on
  // localhost / a warm boot) and waits up to 45s on a cold remote droplet with
  // slow Vite module transforms. Authoritative route readiness is then asserted
  // by each caller's own expect(...).toBeVisible({ timeout }) which auto-retries,
  // so no blind sleep is needed here. (The old fixed 10s sleep was pure latency
  // locally and still raced on remote — the source of the run-to-run flake.)
  await page
    .waitForFunction(
      () => {
        const root = document.getElementById('root');
        return !!root && root.children.length > 0;
      },
      { timeout: 45_000 },
    )
    .catch(() => {});
}

// Full login flow: register server -> connect -> login -> reach /home
async function loginAsTestUser(page: Page) {
  await page.goto('/', { waitUntil: 'commit' });
  await waitForSpaMount(page);
  await page.evaluate(() => localStorage.clear());

  await page.goto('/auth/servers', { waitUntil: 'commit' });
  await waitForSpaMount(page);
  await expect(page.locator('text=/^Servers$/').first()).toBeVisible({ timeout: 60_000 });

  // Check if server already exists (from a previous test run)
  const existingServer = page.locator(`text=/Local Backend/i`).first();
  if (await existingServer.isVisible({ timeout: 5_000 }).catch(() => false)) {
    // Server already registered — skip to connect
    await page.locator('button[aria-label="Actions"]').first().click();
    const connectItem = page.getByRole('menuitem', { name: /Connect to server/i });
    await expect(connectItem).toBeEnabled({ timeout: 15_000 });
    await connectItem.click();
  } else {
    // Register the server
    await page.getByRole('button', { name: /Add server/i }).click();
    await expect(page.locator('#server_name_text_input')).toBeVisible({ timeout: 10_000 });

    await setReactInputValue(page, '#server_name_text_input', 'Local Backend');
    await setReactInputValue(page, '#server_address_text_input', serverUrl);

    await page.getByRole('button', { name: /^Confirm$/i }).click();
    await expect(page.locator('text=/server is saved correctly/i')).toBeVisible({ timeout: 10_000 });

    await page.getByRole('button', { name: /Close Success alert/i }).click().catch(() => {});

    await page.locator('button[aria-label="Actions"]').first().click();
    const connectItem = page.getByRole('menuitem', { name: /Connect to server/i });
    await expect(connectItem).toBeEnabled({ timeout: 15_000 });
    await connectItem.click();
  }
  await expect(page).toHaveURL(/\/auth\/login/, { timeout: 10_000 });

  await setReactInputValue(page, '#username_text_input', 'testuser@domain.org');
  await setReactInputValue(page, '#password_text_input', 'testpassword123');
  await page.getByRole('button', { name: /Sign in/i }).click();
  await expect(page).toHaveURL(/\/user\/welcome|\/home/, { timeout: 30_000 });

  // Skip onboarding if present
  const skipBtn = page.getByRole('button', { name: /^Skip$/i });
  if (await skipBtn.count()) {
    await skipBtn.first().click();
  }
  if (/\/user\/welcome/.test(page.url())) {
    await page.evaluate(() => {
      localStorage.setItem('isWelcomeMessageVisible', 'false');
      window.location.assign('/home');
    });
    await waitForSpaMount(page);
  }
  await expect(page).toHaveURL(/\/home/);
  await expect(page.locator('#nav-toggle')).toBeVisible({ timeout: 45_000 });
}

// Navigate to the recorder page
// Uses page.goto since ToolItem's forceReloadPage does a full page reload anyway.
// The OpenAPI client re-initializes from localStorage on page load.
async function goToRecorder(page: Page) {
  await page.goto('/tools', { waitUntil: 'commit' });
  await waitForSpaMount(page);

  // Wait for the AccessTools page to render (the tools title appears before tool items)
  await expect(page.locator('.tools-title')).toBeVisible({ timeout: 30_000 });

  // Wait for the tool items to render
  const recorderButton = page.locator('button:has-text("Recorder")').first();
  await expect(recorderButton).toBeVisible({ timeout: 15_000 });

  // ToolItem uses forceReloadPage which does location.href = url (full page reload)
  await recorderButton.click();

  // After the Recorder trigger, ToolItem does a full location.href reload.
  // App.tsx then (re)creates the OpenAPI client from localStorage async, so the
  // upload modal can open before teams have loaded and the "Save .wav" / "Save
  // project" buttons stay disabled. A blind sleep is a fragile proxy for
  // readiness; instead wait on a real signal — the teams endpoint returning 200
  // for the saved JWT proves the backend is up and the token is valid. The
  // frontend-side readiness (record button enabled, team selector populated,
  // "Test Team" visible) is gated by the downstream expects in
  // openUploadModalAndFillFields and the test body. (Handoff § Option 1.)
  // Works locally (http://localhost:8000) and against a remote droplet (serverUrl).
  await page.waitForLoadState('commit' as any);
  const token = await page.evaluate(() => {
    const user = JSON.parse(localStorage.getItem('user') || '{}');
    return user?.access || '';
  });
  await page.waitForFunction(
    async ({ serverUrl, token }: { serverUrl: string; token: string }) => {
      if (!token) return false;
      try {
        const res = await fetch(`${serverUrl}/api/teams/?skip_personal_workspace=true`, {
          headers: { Authorization: `Bearer ${token}` },
        });
        if (!res.ok) return false;
        const data: unknown = await res.json();
        return Array.isArray(data);
      } catch {
        return false;
      }
    },
    { serverUrl, token },
    { timeout: 30_000 },
  );

  // Wait for the record button to be ready
  const recordButton = page.locator('#initial-record-button');
  await expect(recordButton).toBeVisible({ timeout: 30_000 });
  await expect(recordButton).toBeEnabled({ timeout: 10_000 });
}

// Record audio for ~1.5 seconds then stop
async function recordAndStop(page: Page) {
  await goToRecorder(page);

  // Click the record button to start recording
  await page.locator('#initial-record-button').click();

  // Wait for the stop button to appear (recording state)
  const stopButton = page.locator('#recording-stop-button');
  await expect(stopButton).toBeVisible({ timeout: 10_000 });
  await expect(stopButton).toBeEnabled({ timeout: 5_000 });

  // Record for ~1.5 seconds
  await page.waitForTimeout(1_500);

  // Stop recording
  await stopButton.click();

  // Wait for the upload button to appear (stopped state shows action bar)
  await expect(page.locator('button[aria-label="action-upload"]')).toBeVisible({
    timeout: 20_000,
  });
}

// Open the upload modal, fill the recording name, select a team
async function openUploadModalAndFillFields(page: Page, recordingName: string) {
  // Click the upload button to open the modal
  await page.locator('button[aria-label="action-upload"]').click();

  // Wait for the upload modal to appear
  const modal = page.getByRole('dialog');
  await expect(modal).toBeVisible({ timeout: 10_000 });
  await expect(modal).toContainText(/Save to Colmena/i);

  // Fill the recording name
  const nameInput = modal.locator('input[aria-label="select-all"]');
  await expect(nameInput).toBeVisible({ timeout: 10_000 });
  await setReactInputValue(page, 'div[role="dialog"] input[aria-label="select-all"]', recordingName);

  // Open the team selector dropdown
  const teamSelect = modal.locator('.teams-modal-selector');
  await expect(teamSelect).toBeVisible({ timeout: 10_000 });

  // Wait for teams to load (options should not show an error)
  await expect
    .poll(async () => {
      const text = await teamSelect.textContent();
      return text || '';
    }, { timeout: 20_000 })
    .not.toMatch(/error/i);

  // Open the dropdown
  await teamSelect.locator('button').first().click();

  // Personal Workspace is auto-selected by the app; click a regular team so
  // the checkbox select cannot be toggled back to an empty selection.
  const testTeamOption = teamSelect.getByText('Test Team', { exact: true });
  await expect(testTeamOption).toBeVisible({ timeout: 20_000 });
  await testTeamOption.click();
  await teamSelect.locator('button').first().click();
  await expect(modal).toBeVisible();

  return modal;
}

test.describe('Colmena end-to-end', () => {
  test('redirects to /auth/servers when no server is saved', async ({ page }) => {
    await page.context().clearCookies();
    await page.goto('/', { waitUntil: 'commit' });
    await page.evaluate(() => localStorage.clear());
    await waitForSpaMount(page);
    await expect(page).toHaveURL(/\/auth\/servers/, { timeout: 60_000 });
    await expect(page.locator('text=/^Servers$/').first()).toBeVisible({ timeout: 60_000 });
  });

  test('register a server, connect, log in, see home', async ({ page }) => {
    await page.goto('/', { waitUntil: 'commit' });
    await waitForSpaMount(page);
    await page.evaluate(() => localStorage.clear());

    await page.goto('/auth/servers', { waitUntil: 'commit' });
    await waitForSpaMount(page);
    await expect(page.locator('text=/^Servers$/').first()).toBeVisible({ timeout: 60_000 });

    // Open the Add Server modal
    await page.getByRole('button', { name: /Add server/i }).click();
    // The modal may have a different title; wait for the URL/name field instead
    await expect(page.locator('#server_name_text_input')).toBeVisible({ timeout: 10_000 });

    await setReactInputValue(page, '#server_name_text_input', 'Local Backend');
    await setReactInputValue(page, '#server_address_text_input', serverUrl);

    // The actual button text is "Confirm" (not "Save")
    await page.getByRole('button', { name: /^Confirm$/i }).click();
    await expect(page.locator('text=/server is saved correctly/i')).toBeVisible({ timeout: 10_000 });

    // Close the success alert so it doesn't intercept clicks
    await page.getByRole('button', { name: /Close Success alert/i }).click().catch(() => {});

    // Wait for the server status check to complete (status icon turns green), then open kebab
    await page.locator('button[aria-label="Actions"]').first().click();
    // Wait for "Connect to server" menu item to be enabled (server must be reachable)
    const connectItem = page.getByRole('menuitem', { name: /Connect to server/i });
    await expect(connectItem).toBeEnabled({ timeout: 15_000 });
    await connectItem.click();
    await expect(page).toHaveURL(/\/auth\/login/, { timeout: 10_000 });

    await setReactInputValue(page, '#username_text_input', 'testuser@domain.org');
    await setReactInputValue(page, '#password_text_input', 'testpassword123');
    await page.getByRole('button', { name: /Sign in/i }).click();
    await expect(page).toHaveURL(/\/user\/welcome|\/home/, { timeout: 15_000 });

    // If we're on the new-user onboarding, click Skip to reach /home
    const skipBtn = page.getByRole('button', { name: /^Skip$/i });
    if (await skipBtn.count()) {
      await skipBtn.first().click();
    }

    // If we're still on /user/welcome, set the flag and reload /home
    if (/\/user\/welcome/.test(page.url())) {
      await page.evaluate(() => {
        localStorage.setItem('isWelcomeMessageVisible', 'false');
        window.location.assign('/home');
      });
      await waitForSpaMount(page);
    }
    await expect(page).toHaveURL(/\/home/);
    // Wait for the home page to mount (header + side nav render)
    await expect(page.locator('#nav-toggle')).toBeVisible({ timeout: 45_000 });

    // Sanity: JWT in localStorage
    const user = await page.evaluate(() => JSON.parse(localStorage.getItem('user') || '{}'));
    expect(user.access).toBeTruthy();
    // user is nested: {access, refresh, user: {email, ...}}
    expect(user.user?.email || user.email).toBe('testuser@domain.org');
  });

  test('hamburger menu opens and expands', async ({ page }) => {
    await loginAsTestUser(page);

    // Wait for the home page to be fully rendered
    await page.locator('#nav-toggle').waitFor({ state: 'visible', timeout: 30_000 });

    await page.locator('#nav-toggle').click();
    await expect(page.getByText('My account').first()).toBeVisible();

    await page.getByText('My account').first().click();
    await expect(page.getByText('User Profile')).toBeVisible({ timeout: 15_000 });
  });

  test('API call from the browser returns backend status', async ({ page }) => {
    await page.goto('/', { waitUntil: 'commit' });
    const status = await page.evaluate(async (url) => {
      const r = await fetch(`${url}/api/status/`);
      return r.json();
    }, serverUrl);
    expect(status.backend.status).toBe('ok');
  });

  test('Teams page shows seeded test team after login', async ({ page }) => {
    await loginAsTestUser(page);

    // Navigate to Teams via SPA router (page.goto would reload and lose OpenAPI client context)
    // Use React Router's navigate by clicking the Teams link in the bottom nav
    const teamsLink = page.getByRole('link', { name: /teams/i }).first();
    await expect(teamsLink).toBeVisible({ timeout: 30_000 });
    await teamsLink.click();
    await expect(page).toHaveURL(/\/teams/, { timeout: 15_000 });
    await waitForSpaMount(page);

    // Wait for team items to load (skeletons should be replaced by real data)
    // TeamItem renders with id="team-list-item-{index}" and team name in a <b> tag
    const firstTeamItem = page.locator('[id^="team-list-item-"]').first();
    await expect(firstTeamItem).toBeVisible({ timeout: 20_000 });

    // Verify the seeded "Test Team" is visible (not just any team)
    const teamName = firstTeamItem.locator('b').first();
    await expect(teamName).toBeVisible({ timeout: 10_000 });
    const nameText = await teamName.textContent();
    expect(nameText).toBeTruthy();
    expect(nameText!.length).toBeGreaterThan(0);

    // Verify the specific seeded team appears somewhere on the page
    await expect(page.getByText('Test Team').first()).toBeVisible({ timeout: 15_000 });

    // Verify the error state is NOT showing
    const errorState = page.locator('text=/preview_error/i');
    expect(await errorState.count()).toBe(0);
  });

  test('My Space page loads with personal workspace after login', async ({ page }) => {
    await loginAsTestUser(page);

    // Get the personal workspace team ID from the API
    const teams = await page.evaluate(async (url) => {
      const user = JSON.parse(localStorage.getItem('user') || '{}');
      const token = user.access;
      const r = await fetch(`${url}/api/teams/`, {
        headers: { Authorization: `Bearer ${token}` },
      });
      return r.json();
    }, serverUrl);

    // Find the personal workspace
    const personalWorkspace = teams.find((t: { is_personal_workspace: boolean }) => t.is_personal_workspace);
    expect(personalWorkspace).toBeTruthy();
    expect(personalWorkspace.id).toBeGreaterThan(0);

    // Navigate via the nav menu (page.goto would reload and lose OpenAPI client context)
    // The My Space nav link goes to /my-space/{teamId}
    await page.locator('#nav-toggle').click();
    // The My Space nav link is the second NavLink in the side nav
    const mySpaceLink = page.locator('a[href^="/my-space/"]').first();
    await expect(mySpaceLink).toBeVisible({ timeout: 30_000 });
    await mySpaceLink.click();
    await expect(page).toHaveURL(new RegExp(`/my-space/`), { timeout: 15_000 });
    await waitForSpaMount(page);

    // The My Space page renders TeamChat with a message text area
    const messageInput = page.locator('#message-text-area');
    await expect(messageInput).toBeVisible({ timeout: 20_000 });
  });

  test('Record audio and open upload modal', async ({ page }) => {
    // The microphone / MediaRecorder path needs a secure context. A plain-HTTP
    // target (IP-only / no-SSL deploy, COLMENA_SCHEME=http) is not one, so the
    // fake-media render that produces the upload payload never completes there.
    // Skip the recorder flow on http; it stays covered on https / localhost.
    test.skip(
      process.env.COLMENA_SCHEME === 'http',
      'recorder needs a secure context; skipped on plain-HTTP (no-SSL) targets',
    );
    await loginAsTestUser(page);
    await recordAndStop(page);

    const modal = await openUploadModalAndFillFields(page, `e2e-recording-${Date.now()}`);

    // Verify the modal is open
    await expect(modal).toBeVisible();
    await expect(modal).toContainText(/Save to Colmena/i);

    // Verify both action buttons are present in the modal
    const wavButton = modal.getByRole('button', { name: /Save \.wav/i });
    const projectButton = modal.getByRole('button', { name: /Save project/i });
    await expect(wavButton).toBeVisible();
    await expect(projectButton).toBeVisible();

    // The buttons should become enabled after team selection
    // (pf-m-progress class appears when buttons are disabled, not from isLoading)
    await expect(wavButton).toBeEnabled({ timeout: 20_000 });
    await expect(projectButton).toBeEnabled({ timeout: 5_000 });

    // Click "Save .wav" to trigger the upload
    await wavButton.click();

    // Wait for the upload to complete — modal should close on success
    await expect(modal).toBeHidden({ timeout: 30_000 });
  });
});
