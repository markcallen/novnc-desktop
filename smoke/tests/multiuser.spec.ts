/**
 * Multi-user desktop smoke tests (FR-9.1 – FR-9.9)
 *
 * Verifies the auth service's multi-user registry, token generation, and
 * per-user backend routing via SSH + curl against the live server. Tests pass
 * whether the host was provisioned by Ansible directly (infra:up) or launched
 * from a pre-built AMI (infra:ami).
 *
 * Acceptance Criteria covered:
 *   AC-MULTI-01 through AC-MULTI-14  (FR-9.1 – FR-9.9)
 *
 * Test user strategy:
 *   SMOKE_TEST_USER is a synthetic registry entry (no real OS user is
 *   created). It is registered via POST /register in beforeAll hooks so that
 *   /generate and /verify tests have a predictable registry state. The
 *   initial OS user (state.vncUser, typically "ubuntu") is used for tests
 *   that require a real provisioned session (novnc-desktop-url, /verify
 *   with a live websockify port).
 */

import { test, expect } from '@playwright/test';
import { execFileSync } from 'node:child_process';
import { state } from './state';

const AUTH_URL = 'http://127.0.0.1:8898';

// Synthetic second user — a registry-only entry, no real OS user needed.
const SMOKE_TEST_USER = 'smoke_test_multi_user';
const SMOKE_TEST_DISPLAY = 50;
const SMOKE_TEST_WS_PORT = 6130;

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

/**
 * Run a curl command on the remote host and return the HTTP status code plus
 * the response body. The status is the first line; the body is the rest.
 */
function sshCurl(curlArgs: string): { status: string; body: string } {
  const raw = ssh(
    `_TMP=$(mktemp); ` +
      `_S=$(curl -s -o "$_TMP" -w "%{http_code}" --max-time 10 ${curlArgs} 2>/dev/null) || _S="000"; ` +
      `echo "$_S"; cat "$_TMP"; rm -f "$_TMP"`
  );
  const nl = raw.indexOf('\n');
  const status = nl >= 0 ? raw.slice(0, nl).trim() : raw.trim();
  const body = nl >= 0 ? raw.slice(nl + 1).trim() : '';
  return { status, body };
}

/**
 * Return the raw response headers (status line + header fields) from a curl
 * request run on the remote host. Useful for checking response headers like
 * X-VNC-Backend without a separate status-code request.
 */
function sshCurlHeaders(curlArgs: string): string {
  return ssh(`curl -s -D - -o /dev/null --max-time 10 ${curlArgs} 2>/dev/null`);
}

// ---------------------------------------------------------------------------
// Registry artefacts and provisioning scripts
// ---------------------------------------------------------------------------

test.describe('multi-user: registry and provisioning artefacts', () => {
  test('user registry file exists at /etc/novnc-auth/users.json', () => {
    test
      .info()
      .annotations.push({ type: 'requirement', description: 'AC-MULTI-01' });
    const result = ssh(
      'test -f /etc/novnc-auth/users.json && echo ok || echo missing'
    );
    expect(result, '/etc/novnc-auth/users.json not found').toBe('ok');
  });

  test('initial user is pre-registered in the user registry', () => {
    test
      .info()
      .annotations.push({ type: 'requirement', description: 'AC-MULTI-02' });
    const result = ssh(
      `python3 -c "import json; d=json.load(open('/etc/novnc-auth/users.json')); ` +
        `print('ok' if '${state.vncUser}' in d else 'missing')" 2>/dev/null || echo error`
    );
    expect(
      result,
      `'${state.vncUser}' not in users.json after provisioning`
    ).toBe('ok');
  });

  test('initial user registry entry has display and ws_port', () => {
    test
      .info()
      .annotations.push({ type: 'requirement', description: 'AC-MULTI-02' });
    const result = ssh(
      `python3 -c "` +
        `import json; d=json.load(open('/etc/novnc-auth/users.json'))['${state.vncUser}']; ` +
        `print('ok' if isinstance(d.get('display'), int) and isinstance(d.get('ws_port'), int) else 'missing')" ` +
        `2>/dev/null || echo error`
    );
    expect(
      result,
      'Initial user registry entry missing display or ws_port'
    ).toBe('ok');
  });

  test('initial user gen_key file exists with mode 0400', () => {
    test
      .info()
      .annotations.push({ type: 'requirement', description: 'AC-MULTI-02' });
    const exists = ssh('test -f ~/.novnc-gen-key && echo ok || echo missing');
    expect(exists, '~/.novnc-gen-key not found for initial user').toBe('ok');

    const perms = ssh("stat -c '%a' ~/.novnc-gen-key");
    expect(perms, '~/.novnc-gen-key should be mode 0400').toBe('400');
  });

  test('novnc-user-setup is installed and executable', () => {
    test
      .info()
      .annotations.push({ type: 'requirement', description: 'AC-MULTI-12' });
    const result = ssh(
      'test -x /usr/local/bin/novnc-user-setup && echo ok || echo missing'
    );
    expect(
      result,
      '/usr/local/bin/novnc-user-setup not present or not executable'
    ).toBe('ok');
  });

  test('novnc-user-setup sudoers rule is installed', () => {
    test
      .info()
      .annotations.push({ type: 'requirement', description: 'AC-MULTI-13' });
    const result = ssh(
      'sudo test -f /etc/sudoers.d/novnc-user-setup && echo ok || echo missing'
    );
    expect(result, '/etc/sudoers.d/novnc-user-setup not found').toBe('ok');
  });
});

// ---------------------------------------------------------------------------
// GET /user-status (FR-9.6)
// ---------------------------------------------------------------------------

test.describe('multi-user: GET /user-status', () => {
  test('/user-status returns 200 and registry entry for the initial user', () => {
    test
      .info()
      .annotations.push({ type: 'requirement', description: 'AC-MULTI-03' });
    const { status, body } = sshCurl(
      `"${AUTH_URL}/user-status?user=${state.vncUser}"`
    );
    expect(status, '/user-status should return 200 for the initial user').toBe(
      '200'
    );
    const data = JSON.parse(body) as {
      user: string;
      display: number;
      ws_port: number;
    };
    expect(data.user).toBe(state.vncUser);
    expect(typeof data.display).toBe('number');
    expect(typeof data.ws_port).toBe('number');
  });

  test('/user-status returns 404 for an unregistered user', () => {
    test
      .info()
      .annotations.push({ type: 'requirement', description: 'AC-MULTI-04' });
    const { status } = sshCurl(
      `"${AUTH_URL}/user-status?user=definitely_not_registered_xyz9999"`
    );
    expect(status, '/user-status should return 404 for unknown user').toBe(
      '404'
    );
  });

  test('/user-status returns 400 when the user parameter is missing', () => {
    const { status } = sshCurl(`"${AUTH_URL}/user-status"`);
    expect(
      status,
      '/user-status should return 400 when user param absent'
    ).toBe('400');
  });
});

// ---------------------------------------------------------------------------
// POST /register (FR-9.5)
// ---------------------------------------------------------------------------

test.describe('multi-user: POST /register', () => {
  test('/register creates a new user entry and returns a gen_key', () => {
    test
      .info()
      .annotations.push({ type: 'requirement', description: 'AC-MULTI-05' });
    const { status, body } = sshCurl(
      `-X POST "${AUTH_URL}/register" ` +
        `-H "Content-Type: application/json" ` +
        `-d '{"user": "${SMOKE_TEST_USER}", "display": ${SMOKE_TEST_DISPLAY}, "ws_port": ${SMOKE_TEST_WS_PORT}}'`
    );
    expect(status, '/register should return 200').toBe('200');
    const data = JSON.parse(body) as {
      user: string;
      display: number;
      ws_port: number;
      gen_key: string;
    };
    expect(data.user).toBe(SMOKE_TEST_USER);
    expect(data.display).toBe(SMOKE_TEST_DISPLAY);
    expect(data.ws_port).toBe(SMOKE_TEST_WS_PORT);
    expect(typeof data.gen_key).toBe('string');
    expect(data.gen_key.length).toBeGreaterThan(0);
  });

  test('/register makes the user visible in /user-status', () => {
    test
      .info()
      .annotations.push({ type: 'requirement', description: 'AC-MULTI-05' });
    // Register first (idempotent if already created above)
    sshCurl(
      `-X POST "${AUTH_URL}/register" ` +
        `-H "Content-Type: application/json" ` +
        `-d '{"user": "${SMOKE_TEST_USER}", "display": ${SMOKE_TEST_DISPLAY}, "ws_port": ${SMOKE_TEST_WS_PORT}}'`
    );
    const { status } = sshCurl(
      `"${AUTH_URL}/user-status?user=${SMOKE_TEST_USER}"`
    );
    expect(status, 'Registered user should appear in /user-status').toBe('200');
  });

  test('/register rejects ws_port below 6001 (SSRF prevention)', () => {
    test
      .info()
      .annotations.push({ type: 'requirement', description: 'AC-MULTI-06' });
    const { status } = sshCurl(
      `-X POST "${AUTH_URL}/register" ` +
        `-H "Content-Type: application/json" ` +
        `-d '{"user": "bad_port_user", "display": 2, "ws_port": 80}'`
    );
    expect(status, 'ws_port=80 should be rejected with 400').toBe('400');
  });

  test('/register rejects ws_port above 9999', () => {
    test
      .info()
      .annotations.push({ type: 'requirement', description: 'AC-MULTI-06' });
    const { status } = sshCurl(
      `-X POST "${AUTH_URL}/register" ` +
        `-H "Content-Type: application/json" ` +
        `-d '{"user": "bad_port_user2", "display": 2, "ws_port": 10000}'`
    );
    expect(status, 'ws_port=10000 should be rejected with 400').toBe('400');
  });

  test('/register rejects display number 0', () => {
    test
      .info()
      .annotations.push({ type: 'requirement', description: 'AC-MULTI-07' });
    const { status } = sshCurl(
      `-X POST "${AUTH_URL}/register" ` +
        `-H "Content-Type: application/json" ` +
        `-d '{"user": "bad_display_user", "display": 0, "ws_port": 6082}'`
    );
    expect(status, 'display=0 should be rejected with 400').toBe('400');
  });

  test('/register rejects display number above 9999', () => {
    test
      .info()
      .annotations.push({ type: 'requirement', description: 'AC-MULTI-07' });
    const { status } = sshCurl(
      `-X POST "${AUTH_URL}/register" ` +
        `-H "Content-Type: application/json" ` +
        `-d '{"user": "bad_display_user2", "display": 10000, "ws_port": 6082}'`
    );
    expect(status, 'display=10000 should be rejected with 400').toBe('400');
  });

  test('/register rejects a request missing required fields', () => {
    const { status } = sshCurl(
      `-X POST "${AUTH_URL}/register" ` +
        `-H "Content-Type: application/json" ` +
        `-d '{"user": "no_ports_user"}'`
    );
    expect(status, 'Missing fields should return 400').toBe('400');
  });

  test('/register rejects invalid JSON', () => {
    const { status } = sshCurl(
      `-X POST "${AUTH_URL}/register" ` +
        `-H "Content-Type: application/json" ` +
        `-d 'not-valid-json'`
    );
    expect(status, 'Invalid JSON should return 400').toBe('400');
  });
});

// ---------------------------------------------------------------------------
// POST /generate (FR-9.4)
// ---------------------------------------------------------------------------

test.describe('multi-user: POST /generate', () => {
  let smokeTestGenKey = '';

  test.beforeAll(() => {
    // Register SMOKE_TEST_USER and capture the gen_key so subsequent tests in
    // this block can mint tokens for it.
    const { status, body } = sshCurl(
      `-X POST "${AUTH_URL}/register" ` +
        `-H "Content-Type: application/json" ` +
        `-d '{"user": "${SMOKE_TEST_USER}", "display": ${SMOKE_TEST_DISPLAY}, "ws_port": ${SMOKE_TEST_WS_PORT}}'`
    );
    if (status === '200') {
      smokeTestGenKey = (JSON.parse(body) as { gen_key: string }).gen_key;
    }
  });

  test('/generate returns 404 for an unregistered user', () => {
    test
      .info()
      .annotations.push({ type: 'requirement', description: 'AC-MULTI-08' });
    const { status } = sshCurl(
      `-X POST "${AUTH_URL}/generate?user=totally_unknown_user_xyz9999"`
    );
    expect(status, '/generate should return 404 for unknown user').toBe('404');
  });

  test('/generate returns 403 for a wrong gen_key', () => {
    test
      .info()
      .annotations.push({ type: 'requirement', description: 'AC-MULTI-09' });
    const { status } = sshCurl(
      `-X POST "${AUTH_URL}/generate?user=${SMOKE_TEST_USER}&key=definitely_wrong_key_value"`
    );
    expect(status, '/generate should return 403 for wrong gen_key').toBe('403');
  });

  test('/generate returns 400 when the user parameter is missing', () => {
    const { status } = sshCurl(`-X POST "${AUTH_URL}/generate"`);
    expect(status, '/generate should return 400 when user param absent').toBe(
      '400'
    );
  });

  test('/generate returns a valid access URL for the initial user', () => {
    test
      .info()
      .annotations.push({ type: 'requirement', description: 'AC-MULTI-10' });
    const genKey = ssh('cat ~/.novnc-gen-key');
    expect(
      genKey.length,
      '~/.novnc-gen-key should be non-empty'
    ).toBeGreaterThan(0);

    const { status, body } = sshCurl(
      `-X POST "${AUTH_URL}/generate?user=${state.vncUser}&key=${genKey}"`
    );
    expect(status, '/generate should return 200 with a valid gen_key').toBe(
      '200'
    );

    const data = JSON.parse(body) as {
      url: string;
      token: string;
      expires_at: string;
    };
    expect(data.url, 'URL should contain /access?token=').toMatch(
      /\/access\?token=/
    );
    expect(data.token, 'token field should be non-empty').toBeTruthy();
    expect(data.expires_at, 'expires_at should be an ISO timestamp').toMatch(
      /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/
    );
  });

  test('/generate returns a valid access URL for a synthetic registered user', () => {
    test
      .info()
      .annotations.push({ type: 'requirement', description: 'AC-MULTI-10' });
    expect(
      smokeTestGenKey.length,
      'beforeAll registration must have succeeded'
    ).toBeGreaterThan(0);

    const { status, body } = sshCurl(
      `-X POST "${AUTH_URL}/generate?user=${SMOKE_TEST_USER}&key=${smokeTestGenKey}"`
    );
    expect(status, '/generate should return 200 for SMOKE_TEST_USER').toBe(
      '200'
    );

    const data = JSON.parse(body) as { url: string; token: string };
    expect(data.url).toMatch(/\/access\?token=/);
    expect(data.token).toBeTruthy();
  });
});

// ---------------------------------------------------------------------------
// GET /verify — X-VNC-Backend routing header (FR-9.3)
// ---------------------------------------------------------------------------

test.describe('multi-user: GET /verify', () => {
  let initialUserToken = '';
  let initialUserWsPort = 0;

  test.beforeAll(() => {
    // Get the initial user's ws_port from the registry and mint a fresh token
    // so the /verify tests have a valid cookie to present.
    const { status: statusStatus, body: statusBody } = sshCurl(
      `"${AUTH_URL}/user-status?user=${state.vncUser}"`
    );
    if (statusStatus === '200') {
      initialUserWsPort = (JSON.parse(statusBody) as { ws_port: number })
        .ws_port;
    }

    const genKey = ssh('cat ~/.novnc-gen-key 2>/dev/null || echo ""');
    if (genKey.length > 0) {
      const { status, body } = sshCurl(
        `-X POST "${AUTH_URL}/generate?user=${state.vncUser}&key=${genKey}"`
      );
      if (status === '200') {
        initialUserToken = (JSON.parse(body) as { token: string }).token;
      }
    }
  });

  test('/verify returns 401 with no cookie', () => {
    test
      .info()
      .annotations.push({ type: 'requirement', description: 'AC-MULTI-11' });
    const { status } = sshCurl(`"${AUTH_URL}/verify"`);
    expect(status, '/verify should return 401 when no cookie is present').toBe(
      '401'
    );
  });

  test('/verify returns 401 for an invalid token cookie', () => {
    test
      .info()
      .annotations.push({ type: 'requirement', description: 'AC-MULTI-11' });
    const { status } = sshCurl(
      `-H "Cookie: novnc_access=invalid.token.value" "${AUTH_URL}/verify"`
    );
    expect(status, '/verify should return 401 for an invalid token').toBe(
      '401'
    );
  });

  test('/verify returns 200 and X-VNC-Backend for a valid token cookie', () => {
    test
      .info()
      .annotations.push({ type: 'requirement', description: 'AC-MULTI-11' });
    expect(
      initialUserToken.length,
      'beforeAll must have obtained a valid token for the initial user'
    ).toBeGreaterThan(0);

    const headers = sshCurlHeaders(
      `-H "Cookie: novnc_access=${initialUserToken}" "${AUTH_URL}/verify"`
    );
    expect(headers, '/verify must return 200').toContain('200');
    expect(headers, '/verify must include X-VNC-Backend header').toContain(
      'X-VNC-Backend'
    );
  });

  test('/verify X-VNC-Backend contains the correct ws_port for the user', () => {
    test
      .info()
      .annotations.push({ type: 'requirement', description: 'AC-MULTI-11' });
    expect(initialUserToken.length).toBeGreaterThan(0);
    expect(initialUserWsPort).toBeGreaterThan(0);

    const headers = sshCurlHeaders(
      `-H "Cookie: novnc_access=${initialUserToken}" "${AUTH_URL}/verify"`
    );
    expect(headers).toContain(`127.0.0.1:${initialUserWsPort}`);
  });
});

// ---------------------------------------------------------------------------
// novnc-desktop-url end-to-end (FR-9.8)
// ---------------------------------------------------------------------------

test.describe('multi-user: novnc-desktop-url', () => {
  test('novnc-desktop-url generates an access URL for the initial user', () => {
    test
      .info()
      .annotations.push({ type: 'requirement', description: 'AC-MULTI-14' });
    const output = ssh('novnc-desktop-url 2>&1');
    expect(output, 'novnc-desktop-url should print "Desktop URL"').toContain(
      'Desktop URL'
    );
    expect(output, 'Output should contain an https:// URL').toMatch(
      /https?:\/\//
    );
    expect(output, 'Output should contain an expiry timestamp').toContain(
      'Expires'
    );
  });
});
