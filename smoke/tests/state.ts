/**
 * Loads the smoke test state written by infra-up.sh.
 * Throws a clear error if infra:up has not been run yet.
 */

import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';

export interface SmokeState {
  publicIp: string;
  accessUrl: string;
  desktopType?: string;
  novncHttpPort: number;
  novncHttpsPort: number;
  httpBaseUrl: string;
  httpsBaseUrl: string;
  vncUser: string;
  sshKeyPath: string;
}

const stateFile = join(__dirname, '../../.smoke-state/state.json');

if (!existsSync(stateFile)) {
  throw new Error(
    `Smoke state not found at ${stateFile}.\n` + `Run 'pnpm infra:up' first.`
  );
}

const parsed = JSON.parse(
  readFileSync(stateFile, 'utf8')
) as Partial<SmokeState>;

if (!parsed.publicIp || !parsed.vncUser || !parsed.sshKeyPath) {
  throw new Error(
    `Smoke state at ${stateFile} is missing SSH connection details.\n` +
      `Re-run 'pnpm infra:up' to recreate the infrastructure state.`
  );
}

if (!parsed.accessUrl) {
  throw new Error(
    `Smoke state at ${stateFile} does not include a desktop access URL.\n` +
      `Run 'pnpm provision:openbox', 'pnpm provision:elementary', or ` +
      `'pnpm provision:elementary:custom-ports' first.`
  );
}

export const state: SmokeState = {
  publicIp: parsed.publicIp,
  accessUrl: parsed.accessUrl,
  desktopType: parsed.desktopType,
  novncHttpPort: Number(parsed.novncHttpPort ?? 80),
  novncHttpsPort: Number(parsed.novncHttpsPort ?? 443),
  httpBaseUrl: `http://${parsed.publicIp}${Number(parsed.novncHttpPort ?? 80) === 80 ? '' : `:${Number(parsed.novncHttpPort ?? 80)}`}`,
  httpsBaseUrl: `https://${parsed.publicIp}${Number(parsed.novncHttpsPort ?? 443) === 443 ? '' : `:${Number(parsed.novncHttpsPort ?? 443)}`}`,
  vncUser: parsed.vncUser,
  sshKeyPath: parsed.sshKeyPath
};
