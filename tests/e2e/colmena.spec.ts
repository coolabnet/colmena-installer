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
async function waitForSpaMount(page: Page) {
  await page.waitForLoadState('domcontentloaded');
  await page.waitForLoadState('networkidle', { timeout: 15_000 }).catch(() => {});
  // Give the SPA a moment to hydrate
  await page.waitForTimeout(500);
}

// Full login flow: register server -> connect -> login -> reach /home
async function loginAsTestUser(page: Page) {
  await page.goto('/');
  await waitForSpaMount(page);
  await page.evaluate(() => localStorage.clear());

  await page.goto('/auth/servers');
  await waitForSpaMount(page);
  await expect(page.locator('text=/^Servers$/').first()).toBeVisible({ timeout: 10_000 });

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
  await expect(page).toHaveURL(/\/auth\/login/, { timeout: 10_000 });

  await setReactInputValue(page, '#username_text_input', 'testuser@domain.org');
  await setReactInputValue(page, '#password_text_input', 'testpassword123');
  await page.getByRole('button', { name: /Sign in/i }).click();
  await expect(page).toHaveURL(/\/user\/welcome|\/home/, { timeout: 15_000 });

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
  await expect(page.locator('#nav-toggle')).toBeVisible({ timeout: 10_000 });
}

// Navigate to the recorder page
// Uses page.goto since ToolItem's forceReloadPage does a full page reload anyway.
// The OpenAPI client re-initializes from localStorage on page load.
async function goToRecorder(page: Page) {
  await page.goto('/tools');
  await waitForSpaMount(page);

  // Wait for the AccessTools page to render (the tools title appears before tool items)
  await expect(page.locator('.tools-title')).toBeVisible({ timeout: 30_000 });

  // Wait for the tool items to render
  const recorderButton = page.locator('button:has-text("Recorder")').first();
  await expect(recorderButton).toBeVisible({ timeout: 15_000 });

  // ToolItem uses forceReloadPage which does location.href = url (full page reload)
  await recorderButton.click();

  // Wait for the full page reload to complete
  await page.waitForLoadState('domcontentloaded');
  await page.waitForLoadState('networkidle', { timeout: 15_000 }).catch(() => {});
  await page.waitForTimeout(3000);

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
    await page.goto('/');
    await waitForSpaMount(page);
    await expect(page).toHaveURL(/\/auth\/servers/);
    await expect(page.locator('text=/^Servers$/').first()).toBeVisible({ timeout: 10_000 });
  });

  test('register a server, connect, log in, see home', async ({ page }) => {
    await page.goto('/');
    await waitForSpaMount(page);
    await page.evaluate(() => localStorage.clear());

    await page.goto('/auth/servers');
    await waitForSpaMount(page);
    await expect(page.locator('text=/^Servers$/').first()).toBeVisible({ timeout: 10_000 });

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
    await expect(page.locator('#nav-toggle')).toBeVisible({ timeout: 10_000 });

    // Sanity: JWT in localStorage
    const user = await page.evaluate(() => JSON.parse(localStorage.getItem('user') || '{}'));
    expect(user.access).toBeTruthy();
    // user is nested: {access, refresh, user: {email, ...}}
    expect(user.user?.email || user.email).toBe('testuser@domain.org');
  });

  test('hamburger menu opens and expands', async ({ page }) => {
    // Pre-seed localStorage to skip login
    await page.goto('/');
    await waitForSpaMount(page);
    await page.evaluate(() => {
      localStorage.clear();
      localStorage.setItem(
        'user',
        JSON.stringify({
          access: 'fake-jwt-for-hamburger-test',
          refresh: 'fake-refresh',
          user: {
            pk: 2,
            username: 'testuser',
            full_name: 'Test User',
            email: 'testuser@domain.org',
            group: { id: 5, name: 'User' },
            organization: null,
            organizationId: null,
            roles: ['User'],
          },
        }),
      );
      localStorage.setItem('serverId', '1');
      localStorage.setItem('isWelcomeMessageVisible', 'false');
    });
    await page.goto('/home');
    await waitForSpaMount(page);
    // Skip the welcome modal if it appears
    await page.getByRole('button', { name: /^Skip$/i }).click({ timeout: 3_000 }).catch(() => {});
    // Wait for the home page to be fully rendered
    await page.locator('#nav-toggle').waitFor({ state: 'visible', timeout: 15_000 });

    await page.locator('#nav-toggle').click();
    await expect(page.getByText('My account').first()).toBeVisible();

    await page.getByText('My account').first().click();
    await expect(page.getByText('User Profile')).toBeVisible({ timeout: 5_000 });
  });

  test('API call from the browser returns backend status', async ({ page }) => {
    await page.goto('/');
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
    await expect(teamsLink).toBeVisible({ timeout: 10_000 });
    await teamsLink.click();
    await expect(page).toHaveURL(/\/teams/, { timeout: 10_000 });
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
    await expect(page.getByText('Test Team').first()).toBeVisible({ timeout: 5_000 });

    // Verify the error state is NOT showing
    const errorState = page.locator('text=/preview_error/i');
    expect(await errorState.count()).toBe(0);
  });

  test('My Space page loads with personal workspace after login', async ({ page }) => {
    test.setTimeout(60_000);
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
    await expect(mySpaceLink).toBeVisible({ timeout: 10_000 });
    await mySpaceLink.click();
    await expect(page).toHaveURL(new RegExp(`/my-space/`), { timeout: 10_000 });
    await waitForSpaMount(page);

    // The My Space page renders TeamChat with a message text area
    const messageInput = page.locator('#message-text-area');
    await expect(messageInput).toBeVisible({ timeout: 20_000 });
  });

  test('Record audio and open upload modal', async ({ page }) => {
    test.setTimeout(120_000);
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
