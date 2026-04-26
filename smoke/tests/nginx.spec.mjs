/**
 * nginx smoke tests
 *
 * Verifies that nginx is up, TLS is working, HTTP redirects to HTTPS,
 * unauthenticated requests are gated, and the /generate endpoint is blocked.
 */

import { test, expect } from "@playwright/test";
import { state } from "./state.mjs";

const { publicIp } = state;

test.describe("nginx", () => {
  test("HTTPS endpoint responds", async ({ request }) => {
    // baseURL is https://ip so a relative path uses HTTPS.
    // /access without a token is public and handled by the auth service (non-5xx).
    const response = await request.get("/access");
    expect(response.status()).toBeLessThan(500);
  });

  test("HTTP redirects to HTTPS with 301", async ({ page }) => {
    // Capture all responses so we can inspect the very first one (the 301)
    // before Playwright follows the redirect chain.
    const responses = [];
    page.on("response", (r) => responses.push(r));

    // page.goto follows redirects. After the 301 the chain leads to /access
    // (no token), which the auth service handles. Ignore navigation errors
    // caused by redirect loops — we only care about the first response.
    await page
      .goto(`http://${publicIp}/`, { waitUntil: "commit", timeout: 15_000 })
      .catch(() => {});

    const first = responses[0];
    expect(first, "no response received from HTTP request").toBeTruthy();
    expect(first.status()).toBe(301);
    expect(first.headers()["location"]).toMatch(/^https:/i);
  });

  test("unauthenticated request to / redirects to /access", async ({
    request,
  }) => {
    // With maxRedirects:0 the 302 is returned directly without following it.
    const response = await request.get("/", { maxRedirects: 0 });
    expect(response.status()).toBe(302);
    expect(response.headers()["location"]).toContain("/access");
  });

  test("POST to /generate is blocked with 403", async ({ request }) => {
    const response = await request.post("/generate");
    expect(response.status()).toBe(403);
  });
});
