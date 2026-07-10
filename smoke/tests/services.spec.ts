/**
 * Services smoke tests
 *
 * Verifies via SSH that required commands and systemd services are present and
 * running on the provisioned host. These checks are deployment-path agnostic:
 * they pass whether the host was provisioned by Ansible directly (FR-7) or
 * launched from a pre-built AMI (FR-8).
 *
 * Acceptance Criteria covered:
 *   AC-ANSIBLE-01, AC-ANSIBLE-02, AC-ANSIBLE-03  (direct Ansible path)
 *   AC-AMI-02, AC-AMI-03, AC-AMI-04              (AMI launch path)
 *   AC-DESKTOP-02                                (browser defaults)
 */

import { test, expect } from '@playwright/test';
import { execFileSync } from 'node:child_process';
import { state } from './state';

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

test.describe('services', () => {
  test('novnc-desktop-url is installed and executable', () => {
    test
      .info()
      .annotations.push(
        { type: 'requirement', description: 'AC-ANSIBLE-01' },
        { type: 'requirement', description: 'AC-AMI-02' }
      );

    const result = ssh(
      'test -x /usr/local/bin/novnc-desktop-url && echo ok || echo missing'
    );
    expect(
      result,
      '/usr/local/bin/novnc-desktop-url not present or not executable'
    ).toBe('ok');
  });

  test('novnc-setup-tls is installed and executable', () => {
    test
      .info()
      .annotations.push(
        { type: 'requirement', description: 'AC-ANSIBLE-02' },
        { type: 'requirement', description: 'AC-AMI-03' }
      );

    const result = ssh(
      'test -x /usr/local/bin/novnc-setup-tls && echo ok || echo missing'
    );
    expect(
      result,
      '/usr/local/bin/novnc-setup-tls not present or not executable'
    ).toBe('ok');
  });

  test('novnc-auth.service is active', () => {
    test
      .info()
      .annotations.push(
        { type: 'requirement', description: 'AC-ANSIBLE-03' },
        { type: 'requirement', description: 'AC-AMI-04' }
      );

    const result = ssh(
      'systemctl is-active novnc-auth.service 2>/dev/null || echo inactive'
    );
    expect(result, 'novnc-auth.service is not active').toBe('active');
  });

  test('nginx is active', () => {
    test
      .info()
      .annotations.push(
        { type: 'requirement', description: 'AC-ANSIBLE-03' },
        { type: 'requirement', description: 'AC-AMI-04' }
      );

    const result = ssh(
      'systemctl is-active nginx 2>/dev/null || echo inactive'
    );
    expect(result, 'nginx is not active').toBe('active');
  });

  test('novnc.service is active', () => {
    test
      .info()
      .annotations.push(
        { type: 'requirement', description: 'AC-ANSIBLE-03' },
        { type: 'requirement', description: 'AC-AMI-04' }
      );

    const result = ssh(
      'systemctl is-active novnc.service 2>/dev/null || echo inactive'
    );
    expect(result, 'novnc.service is not active').toBe('active');
  });

  test('novnc-desktop.service is active', () => {
    test
      .info()
      .annotations.push(
        { type: 'requirement', description: 'AC-ANSIBLE-03' },
        { type: 'requirement', description: 'AC-AMI-04' }
      );

    const result = ssh(
      'systemctl is-active novnc-desktop.service 2>/dev/null || echo inactive'
    );
    expect(result, 'novnc-desktop.service is not active').toBe('active');
  });

  test('Google Chrome is the default browser', () => {
    test
      .info()
      .annotations.push({ type: 'requirement', description: 'AC-DESKTOP-02' });

    const defaultBrowserResult = ssh(
      'home="$(getent passwd "$(id -un)" | cut -d: -f6)" && ' +
        'test "$(update-alternatives --query x-www-browser | awk \'/^Value: / {print $2}\')" = /usr/bin/google-chrome-stable && ' +
        'test -f "$home/.config/mimeapps.list" && ' +
        'grep -Fxq "text/html=google-chrome.desktop;" "$home/.config/mimeapps.list" && ' +
        'grep -Fxq "application/xhtml+xml=google-chrome.desktop;" "$home/.config/mimeapps.list" && ' +
        'grep -Fxq "x-scheme-handler/http=google-chrome.desktop;" "$home/.config/mimeapps.list" && ' +
        'grep -Fxq "x-scheme-handler/https=google-chrome.desktop;" "$home/.config/mimeapps.list" && ' +
        'grep -Fxq "x-scheme-handler/about=google-chrome.desktop;" "$home/.config/mimeapps.list" && ' +
        'grep -Fxq "x-scheme-handler/unknown=google-chrome.desktop;" "$home/.config/mimeapps.list" && ' +
        'test -f "$home/.config/google-chrome/First Run" && ' +
        'echo ok'
    );
    expect(
      defaultBrowserResult,
      'Google Chrome is not configured as the default browser'
    ).toBe('ok');

    const managedPolicies = JSON.parse(
      ssh('cat /etc/opt/chrome/policies/managed/novnc-desktop.json')
    ) as { DefaultBrowserSettingEnabled?: unknown };

    expect(managedPolicies.DefaultBrowserSettingEnabled).toBe(false);
  });

  test('xdg-open launches Google Chrome from a terminal without default browser prompt', async () => {
    test
      .info()
      .annotations.push({ type: 'requirement', description: 'AC-DESKTOP-02' });

    killChrome();
    try {
      ssh(
        'rm -f /tmp/novnc-xdg-open-smoke.log && ' +
          'DISPLAY=:1 setsid -f xterm -title XDG_OPEN_SMOKE -e sh -lc ' +
          '\'xdg-open "https://www.google.com" > /tmp/novnc-xdg-open-smoke.log 2>&1; sleep 10\' ' +
          '</dev/null >/dev/null 2>&1'
      );

      await awaitExpectChromeWindow();
    } finally {
      killChrome();
    }
  });
});

function killChrome(): void {
  ssh(
    'pkill -x chrome || true; ' +
      'pkill -x google-chrome || true; ' +
      'pkill -x google-chrome-stable || true; ' +
      'DISPLAY=:1 wmctrl -c XDG_OPEN_SMOKE 2>/dev/null || true'
  );
}

async function awaitExpectChromeWindow(): Promise<void> {
  await expect
    .poll(
      () =>
        ssh(
          'DISPLAY=:1 wmctrl -lx 2>/dev/null | ' +
            "awk 'BEGIN { chrome=0; prompt=0 } " +
            'tolower($0) ~ /google-chrome/ { chrome=1 } ' +
            'tolower($0) ~ /(default browser|set as default|make.*default)/ { prompt=1 } ' +
            'END { if (prompt) print "prompt"; else if (chrome) print "chrome"; else print "missing" }\''
        ),
      {
        intervals: [1000, 2000, 2000, 3000, 3000],
        timeout: 30_000
      }
    )
    .toBe('chrome');
}
