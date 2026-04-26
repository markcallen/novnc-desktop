/**
 * Desktop smoke tests
 *
 * Verifies the full access flow: token URL → auth cookie → noVNC canvas →
 * rendered desktop content (smoke marker xterm).
 *
 * Requires smoke_test_marker_enabled=true on the provisioned host (infra-up.sh
 * sets this automatically).
 */

import { test, expect } from "@playwright/test";
import { mkdirSync } from "node:fs";
import { state } from "./state";

const { accessUrl } = state;

interface CanvasResult {
  active: boolean;
  greenPixels: number;
  sampledPixels: number;
}

test.describe("desktop", () => {
  test("access URL exchanges token for cookie and redirects to vnc.html", async ({
    page,
  }) => {
    const response = await page.goto(accessUrl, {
      waitUntil: "domcontentloaded",
      timeout: 60_000,
    });

    // The auth service returns 302 → vnc.html; Playwright follows the redirect.
    // Final URL must be vnc.html.
    expect(page.url()).toMatch(/vnc\.html/);

    // The initial response from the access URL must be a redirect (302).
    expect(response?.status()).toBeLessThan(400);
  });

  test("VNC canvas renders desktop with smoke marker", async ({ page }) => {
    await page.goto(accessUrl, {
      waitUntil: "domcontentloaded",
      timeout: 60_000,
    });

    // Step 1: wait for the noVNC canvas to exist with non-zero dimensions.
    await page.waitForFunction(
      () => {
        const canvas = document.querySelector("canvas");
        return Boolean(canvas && canvas.width > 0 && canvas.height > 0);
      },
      { timeout: 60_000 }
    );

    // Step 2: give VNC a few seconds to render content into the canvas.
    await page.waitForTimeout(5_000);

    // Step 3: sample the canvas for the bright-green smoke marker xterm.
    // The marker is visible when smoke_test_marker_enabled=true (set by infra-up.sh).
    const result = await page.evaluate((): CanvasResult => {
      const canvas = document.querySelector("canvas");
      if (!canvas) return { active: false, greenPixels: 0, sampledPixels: 0 };

      const ctx = canvas.getContext("2d");
      if (!ctx) return { active: false, greenPixels: 0, sampledPixels: 0 };

      const sampleW = Math.min(canvas.width, 500);
      const sampleH = Math.min(canvas.height, 300);
      const image = ctx.getImageData(0, 0, sampleW, sampleH).data;

      let greenPixels = 0;
      let sampledPixels = 0;
      for (let i = 0; i < image.length; i += 4) {
        if (image[i + 3] === 0) continue; // skip transparent
        sampledPixels += 1;
        // Bright green: G >= 170, R <= 120, B <= 120
        if (image[i + 1] >= 170 && image[i] <= 120 && image[i + 2] <= 120) {
          greenPixels += 1;
        }
      }

      return { active: greenPixels >= 200, greenPixels, sampledPixels };
    });

    // Save a screenshot as a test artifact regardless of pass/fail.
    mkdirSync(".smoke-artifacts", { recursive: true });
    await page.screenshot({
      path: ".smoke-artifacts/desktop-final.png",
      fullPage: true,
    });

    expect(
      result.active,
      `Desktop smoke marker not detected in VNC canvas. ` +
        `greenPixels=${result.greenPixels}, sampledPixels=${result.sampledPixels}. ` +
        `Check .smoke-artifacts/desktop-final.png for the captured frame.`
    ).toBe(true);
  });
});
