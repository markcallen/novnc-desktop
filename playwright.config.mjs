import { defineConfig } from "@playwright/test";
import { readFileSync, existsSync } from "node:fs";

const stateFile = ".smoke-state/state.json";

let state = null;
if (existsSync(stateFile)) {
  state = JSON.parse(readFileSync(stateFile, "utf8"));
}

if (!state) {
  throw new Error(
    `\nSmoke state not found at ${stateFile}.\n` +
    `Run 'pnpm infra:up' first to provision the test server.\n`
  );
}

export default defineConfig({
  testDir: "smoke/tests",
  timeout: 120_000,
  reporter: [
    ["list"],
    ["html", { open: "never", outputFolder: ".smoke-artifacts/report" }],
  ],
  use: {
    baseURL: `https://${state.publicIp}`,
    ignoreHTTPSErrors: true,
    screenshot: "only-on-failure",
    video: "retain-on-failure",
  },
});
