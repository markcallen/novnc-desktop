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
  vncUser: string;
  sshKeyPath: string;
}

const stateFile = join(__dirname, '../../.smoke-state/state.json');

if (!existsSync(stateFile)) {
  throw new Error(
    `Smoke state not found at ${stateFile}.\n` + `Run 'pnpm infra:up' first.`
  );
}

export const state: SmokeState = JSON.parse(readFileSync(stateFile, 'utf8'));
