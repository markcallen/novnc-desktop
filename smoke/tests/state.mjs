/**
 * Loads the smoke test state written by infra-up.sh.
 * Throws a clear error if infra:up has not been run yet.
 */

import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const stateFile = join(__dirname, "../../.smoke-state/state.json");

if (!existsSync(stateFile)) {
  throw new Error(
    `Smoke state not found at ${stateFile}.\n` +
    `Run 'pnpm infra:up' first.`
  );
}

export const state = JSON.parse(readFileSync(stateFile, "utf8"));
