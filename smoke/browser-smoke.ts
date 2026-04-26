#!/usr/bin/env node
/**
 * browser-smoke.ts
 *
 * Smoke test for novnc-desktop. Uses a token-based access URL (no VNC
 * password). Flow:
 *   1. Navigate to the access URL — the auth service sets the access cookie
 *      and redirects to vnc.html?autoconnect=1.
 *   2. Wait for the noVNC canvas to become active with rendered content.
 *   3. Verify the green smoke-test marker xterm is visible (when
 *      smoke_test_marker_enabled is true).
 *   4. Take a screenshot.
 */

import process from "node:process";
import { chromium } from "playwright";
import type { Page } from "playwright";

interface Options {
  accessUrl: string;
  screenshot: string;
  ignoreHttpsErrors: string;
}

interface CanvasActivity {
  active: boolean;
  greenPixels: number;
  sampledPixels: number;
}

function die(message: string): never {
  console.error(`[smoke] ERROR: ${message}`);
  process.exit(1);
}

function parseArgs(argv: string[]): Options {
  const options: Options = {
    accessUrl: "",
    screenshot: "",
    ignoreHttpsErrors: "false",
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];

    switch (arg) {
      case "--access-url":
        options.accessUrl = argv[index + 1] ?? "";
        index += 1;
        break;
      case "--screenshot":
        options.screenshot = argv[index + 1] ?? "";
        index += 1;
        break;
      case "--ignore-https-errors":
        options.ignoreHttpsErrors = argv[index + 1] ?? "false";
        index += 1;
        break;
      default:
        die(`Unknown argument: ${arg}`);
    }
  }

  if (!options.accessUrl) {
    die("--access-url is required (obtain it by running 'desktop-url' on the host)");
  }
  if (!options.screenshot) {
    die("--screenshot is required");
  }

  return options;
}

async function waitForCanvasActivity(page: Page): Promise<void> {
  await page.waitForFunction(() => {
    const canvas = document.querySelector("canvas");
    return Boolean(canvas && canvas.width > 0 && canvas.height > 0);
  }, { timeout: 60000 });

  await page.waitForTimeout(5000);

  const activity = await page.evaluate((): CanvasActivity => {
    const canvas = document.querySelector("canvas");
    if (!canvas) {
      return { active: false, greenPixels: 0, sampledPixels: 0 };
    }

    const context = canvas.getContext("2d");
    if (!context) {
      return { active: false, greenPixels: 0, sampledPixels: 0 };
    }

    const sampleWidth = Math.min(canvas.width, 500);
    const sampleHeight = Math.min(canvas.height, 300);
    const image = context.getImageData(0, 0, sampleWidth, sampleHeight).data;
    let greenPixels = 0;
    let sampledPixels = 0;

    for (let index = 0; index < image.length; index += 4) {
      const red = image[index];
      const green = image[index + 1];
      const blue = image[index + 2];
      const alpha = image[index + 3];

      if (alpha === 0) {
        continue;
      }

      sampledPixels += 1;
      if (green >= 170 && red <= 120 && blue <= 120) {
        greenPixels += 1;
      }
    }

    return {
      active: greenPixels >= 200,
      greenPixels,
      sampledPixels,
    };
  });

  if (!activity.active) {
    throw new Error(
      `Desktop marker not detected in VNC canvas; ` +
      `greenPixels=${activity.greenPixels}, sampledPixels=${activity.sampledPixels}`
    );
  }
}

async function main(): Promise<void> {
  const options = parseArgs(process.argv.slice(2));
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    ignoreHTTPSErrors: options.ignoreHttpsErrors === "true",
    viewport: { width: 1440, height: 900 },
  });
  const page = await context.newPage();

  try {
    // Step 1: Load the access URL. The auth service validates the token, sets
    // the HttpOnly cookie, and redirects to vnc.html?autoconnect=1&resize=remote.
    console.log(`[smoke] Navigating to access URL...`);
    await page.goto(options.accessUrl, {
      waitUntil: "domcontentloaded",
      timeout: 60000,
    });

    // After the redirect we should be at vnc.html with autoconnect active.
    // Wait for the canvas to appear and contain rendered desktop content.
    console.log(`[smoke] Waiting for VNC canvas activity...`);
    await waitForCanvasActivity(page);

    console.log(`[smoke] Canvas active. Saving screenshot to ${options.screenshot}`);
    await page.screenshot({ path: options.screenshot, fullPage: true });
    console.log(`[smoke] PASS`);
  } finally {
    await context.close();
    await browser.close();
  }
}

main().catch((error: unknown) => {
  die(error instanceof Error ? error.message : String(error));
});
