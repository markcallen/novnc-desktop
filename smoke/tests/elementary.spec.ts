/**
 * Elementary-specific smoke tests.
 *
 * Validates that the Pantheon compositor (`gala`) is restarted automatically
 * if it exits while the VNC session is still active.
 */

import { test, expect } from '@playwright/test';
import { execFileSync } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import { state } from './state';

interface CanvasResult {
  active: boolean;
  greenPixels: number;
  sampledPixels: number;
}

const sshArgs = [
  '-o',
  'BatchMode=yes',
  '-o',
  'ConnectTimeout=10',
  '-o',
  'StrictHostKeyChecking=no',
  '-o',
  'UserKnownHostsFile=/dev/null',
  '-i',
  state.sshKeyPath,
  `${state.vncUser}@${state.publicIp}`
];

function ssh(command: string): string {
  return execFileSync('ssh', [...sshArgs, command], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
    timeout: 15_000
  }).trim();
}

function activeWindowName(): string {
  const windowId = ssh(
    "DISPLAY=:1 xprop -root _NET_ACTIVE_WINDOW | awk '{print $5}'"
  );
  const details = ssh(`DISPLAY=:1 xwininfo -id ${windowId} -wm`);
  const match = details.match(/Window id: .*?"([^"]+)"/);

  return match?.[1] ?? details;
}

async function readCanvas(
  page: import('@playwright/test').Page
): Promise<CanvasResult> {
  return page.evaluate((): CanvasResult => {
    const canvas = document.querySelector('canvas');
    if (!canvas) return { active: false, greenPixels: 0, sampledPixels: 0 };

    const ctx = canvas.getContext('2d');
    if (!ctx) return { active: false, greenPixels: 0, sampledPixels: 0 };

    const sampleW = Math.min(canvas.width, 500);
    const sampleH = Math.min(canvas.height, 300);
    const image = ctx.getImageData(0, 0, sampleW, sampleH).data;

    let greenPixels = 0;
    let sampledPixels = 0;
    for (let i = 0; i < image.length; i += 4) {
      if (image[i + 3] === 0) continue;
      sampledPixels += 1;
      if (image[i + 1] >= 170 && image[i] <= 120 && image[i + 2] <= 120) {
        greenPixels += 1;
      }
    }

    return { active: greenPixels >= 200, greenPixels, sampledPixels };
  });
}

test.describe('elementary', () => {
  test.skip(
    state.desktopType !== 'elementary',
    'requires an Elementary smoke host'
  );

  test('gala is restarted after it crashes', async ({ page }) => {
    await page.goto(state.accessUrl, {
      waitUntil: 'domcontentloaded',
      timeout: 60_000
    });

    await page.waitForFunction(
      () => {
        const canvas = document.querySelector('canvas');
        return Boolean(canvas && canvas.width > 0 && canvas.height > 0);
      },
      { timeout: 60_000 }
    );

    await page.waitForTimeout(5_000);
    expect((await readCanvas(page)).active).toBe(true);

    ssh('pgrep -x gala >/dev/null && pkill -x gala || true');

    await expect
      .poll(
        () =>
          ssh(
            "bash -lc 'pgrep -x gala >/dev/null && echo running || echo missing'"
          ),
        {
          intervals: [1000, 2000, 2000, 3000, 3000],
          timeout: 20_000
        }
      )
      .toBe('running');

    await page.waitForTimeout(5_000);

    const result = await readCanvas(page);
    mkdirSync('.smoke-artifacts', { recursive: true });
    await page.screenshot({
      path: '.smoke-artifacts/elementary-gala-restart.png',
      fullPage: true
    });

    expect(
      result.active,
      `Desktop canvas was not healthy after gala restart. ` +
        `greenPixels=${result.greenPixels}, sampledPixels=${result.sampledPixels}. ` +
        `Check .smoke-artifacts/elementary-gala-restart.png for the captured frame.`
    ).toBe(true);
  });

  test('smoke marker xterm keeps keyboard focus through noVNC', async ({
    page
  }) => {
    await page.goto(state.accessUrl, {
      waitUntil: 'domcontentloaded',
      timeout: 60_000
    });

    await page.waitForFunction(
      () => {
        const canvas = document.querySelector('canvas');
        return Boolean(canvas && canvas.width > 0 && canvas.height > 0);
      },
      { timeout: 60_000 }
    );

    await page.waitForTimeout(5_000);
    expect((await readCanvas(page)).active).toBe(true);

    await page.locator('canvas').click({ position: { x: 260, y: 165 } });

    await expect
      .poll(activeWindowName, {
        intervals: [500, 1000, 1000, 2000, 2000],
        timeout: 10_000
      })
      .toContain('SMOKE_READY');
  });
});
