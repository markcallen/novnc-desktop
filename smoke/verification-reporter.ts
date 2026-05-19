/**
 * verification-reporter.ts
 *
 * Custom Playwright reporter that writes .smoke-artifacts/verification.json
 * after every test run. The manifest maps Acceptance Criteria IDs (defined in
 * PRD.md) to test outcomes so agents and operators can answer "is requirement
 * X verified?" without running the tests again.
 *
 * Each test pushes one or more requirement annotations:
 *   test.info().annotations.push({ type: 'requirement', description: 'AC-TLS-01' });
 *
 * The reporter collects those at onTestEnd and writes the manifest at onEnd.
 */

import type {
  Reporter,
  TestCase,
  TestResult,
  FullResult
} from '@playwright/test/reporter';
import { writeFileSync, readFileSync, existsSync, mkdirSync } from 'node:fs';
import { execSync } from 'node:child_process';

interface CriterionResult {
  status: 'pass' | 'fail' | 'skip';
  test: string;
  file: string;
  error?: string;
}

interface VerificationManifest {
  timestamp: string;
  commit: string;
  ami_id: string | null;
  variant: string | null;
  overall: 'pass' | 'fail';
  criteria: Record<string, CriterionResult>;
}

class VerificationReporter implements Reporter {
  private readonly criteria: Record<string, CriterionResult> = {};

  onTestEnd(test: TestCase, result: TestResult): void {
    const requirements = result.annotations
      .filter((a) => a.type === 'requirement')
      .map((a) => a.description ?? '')
      .filter(Boolean);

    for (const req of requirements) {
      const incoming: 'pass' | 'fail' | 'skip' =
        result.status === 'passed'
          ? 'pass'
          : result.status === 'skipped'
            ? 'skip'
            : 'fail';

      const existing = this.criteria[req];
      // A fail always wins; don't downgrade pass to skip.
      if (existing?.status === 'pass' && incoming === 'skip') continue;
      if (existing?.status === 'fail') continue;

      this.criteria[req] = {
        status: incoming,
        test: test.titlePath().slice(1).join(' > '),
        file: test.location.file.replace(/^.*?(smoke\/tests\/)/, '$1'),
        ...(result.error?.message
          ? { error: result.error.message.split('\n')[0] }
          : {})
      };
    }
  }

  async onEnd(result: FullResult): Promise<void> {
    mkdirSync('.smoke-artifacts', { recursive: true });

    let amiId: string | null = null;
    let variant: string | null = null;
    const stateFile = '.smoke-state/state.json';
    if (existsSync(stateFile)) {
      try {
        const state = JSON.parse(readFileSync(stateFile, 'utf8')) as {
          amiId?: string;
          variant?: string;
        };
        amiId = state.amiId ?? null;
        variant = state.variant ?? null;
      } catch {
        // state unreadable — leave as null
      }
    }

    let commit = 'unknown';
    try {
      commit = execSync('git rev-parse --short HEAD', {
        encoding: 'utf8'
      }).trim();
    } catch {
      // not a git repo or git unavailable
    }

    const hasFailure = Object.values(this.criteria).some(
      (c) => c.status === 'fail'
    );

    const manifest: VerificationManifest = {
      timestamp: new Date().toISOString(),
      commit,
      ami_id: amiId,
      variant,
      overall: hasFailure || result.status === 'failed' ? 'fail' : 'pass',
      criteria: this.criteria
    };

    writeFileSync(
      '.smoke-artifacts/verification.json',
      JSON.stringify(manifest, null, 2) + '\n'
    );

    // eslint-disable-next-line no-console
    console.log(
      `\nVerification manifest → .smoke-artifacts/verification.json` +
        ` (overall: ${manifest.overall})\n`
    );
  }
}

export default VerificationReporter;
