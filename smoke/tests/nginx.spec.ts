/**
 * nginx smoke tests
 *
 * Verifies that nginx is up, TLS is working, HTTP redirects to HTTPS,
 * unauthenticated requests are gated, and the /generate endpoint is blocked.
 */

import { test, expect } from '@playwright/test';
import { state } from './state';

test.describe('nginx', () => {
  test('HTTPS endpoint responds', async ({ request }) => {
    test
      .info()
      .annotations.push({ type: 'requirement', description: 'AC-TLS-01' });
    // baseURL is https://ip so a relative path uses HTTPS.
    // /access without a token redirects to / which redirects back — use
    // maxRedirects:0 to capture the first response and avoid the loop.
    const response = await request.get('/access', { maxRedirects: 0 });
    expect(response.status()).toBeLessThan(500);
  });

  test('HTTP redirects to HTTPS with 301', async ({ page }) => {
    test
      .info()
      .annotations.push({ type: 'requirement', description: 'AC-TLS-02' });
    // Capture all responses so we can inspect the very first one (the 301)
    // before Playwright follows the redirect chain.
    const responses: import('@playwright/test').Response[] = [];
    page.on('response', (r) => responses.push(r));

    // page.goto follows redirects. After the 301 the chain leads to /access
    // (no token), which the auth service handles. Ignore navigation errors
    // caused by redirect loops — we only care about the first response.
    await page
      .goto(`${state.httpBaseUrl}/`, { waitUntil: 'commit', timeout: 15_000 })
      .catch(() => {});

    const first = responses[0];
    expect(first, 'no response received from HTTP request').toBeTruthy();
    expect(first.status()).toBe(301);

    const location = first.headers()['location'];
    expect(location).toBeTruthy();

    const redirected = new URL(location);
    expect(redirected.protocol).toBe('https:');
    expect(redirected.hostname).toBe(state.publicIp);
    expect(redirected.port || '443').toBe(String(state.novncHttpsPort));
  });

  test('generated access URL uses configured HTTPS port', () => {
    test
      .info()
      .annotations.push({ type: 'requirement', description: 'AC-TLS-03' });
    const accessUrl = new URL(state.accessUrl);
    expect(accessUrl.protocol).toBe('https:');
    const validHosts = [state.publicIp, state.publicDns];
    if (state.tlsDomain) {
      validHosts.push(state.tlsDomain);
    }
    expect(validHosts).toContain(accessUrl.hostname);
    expect(accessUrl.port || '443').toBe(String(state.novncHttpsPort));
  });

  test('unauthenticated request to / redirects to /access', async ({
    request
  }) => {
    test
      .info()
      .annotations.push({ type: 'requirement', description: 'AC-AUTH-01' });
    // With maxRedirects:0 the 302 is returned directly without following it.
    const response = await request.get('/', { maxRedirects: 0 });
    expect(response.status()).toBe(302);
    expect(response.headers()['location']).toContain('/access');
  });

  test('POST to /generate is blocked with 403', async ({ request }) => {
    test
      .info()
      .annotations.push({ type: 'requirement', description: 'AC-AUTH-02' });
    const response = await request.post('/generate');
    expect(response.status()).toBe(403);
  });
});
