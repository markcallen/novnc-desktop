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

    const result = ssh(
      'home="$(getent passwd "$(id -un)" | cut -d: -f6)" && ' +
        'test "$(update-alternatives --query x-www-browser | awk \'/^Value: / {print $2}\')" = /usr/bin/google-chrome-stable && ' +
        'test -f "$home/.config/mimeapps.list" && ' +
        'grep -Fxq "text/html=google-chrome.desktop;" "$home/.config/mimeapps.list" && ' +
        'grep -Fxq "application/xhtml+xml=google-chrome.desktop;" "$home/.config/mimeapps.list" && ' +
        'grep -Fxq "x-scheme-handler/http=google-chrome.desktop;" "$home/.config/mimeapps.list" && ' +
        'grep -Fxq "x-scheme-handler/https=google-chrome.desktop;" "$home/.config/mimeapps.list" && ' +
        'grep -Fxq "x-scheme-handler/about=google-chrome.desktop;" "$home/.config/mimeapps.list" && ' +
        'grep -Fxq "x-scheme-handler/unknown=google-chrome.desktop;" "$home/.config/mimeapps.list" && ' +
        'echo ok'
    );
    expect(
      result,
      'Google Chrome is not configured as the default browser'
    ).toBe('ok');
  });
});
