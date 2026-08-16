/**
 * KDE-specific smoke tests.
 *
 * Validates that the KDE Plasma session is running and the WhiteSur theme
 * assets/configuration were applied for the VNC user.
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

test.describe('kde', () => {
  test.skip(state.desktopType !== 'kde', 'requires a KDE smoke host');

  test('Plasma shell is running in the VNC session', async () => {
    test.info().annotations.push({
      type: 'requirement',
      description: 'AC-KDE-01'
    });

    await expect
      .poll(
        () =>
          ssh(
            "bash -lc 'pgrep -x plasmashell >/dev/null && pgrep -x kwin_x11 >/dev/null && echo running || echo missing'"
          ),
        {
          intervals: [1000, 2000, 3000, 5000],
          timeout: 30_000
        }
      )
      .toBe('running');
  });

  test('WhiteSur theme assets and user config are installed', () => {
    test.info().annotations.push({
      type: 'requirement',
      description: 'AC-KDE-02'
    });

    const result = ssh(
      'home="$(getent passwd "$(id -un)" | cut -d: -f6)" && ' +
        'test -d /usr/share/plasma/look-and-feel/com.github.vinceliuice.WhiteSur-dark && ' +
        'test -d /usr/share/plasma/desktoptheme/WhiteSur-dark && ' +
        'test -d /usr/share/Kvantum/WhiteSur && ' +
        'test -d /usr/share/themes/WhiteSur-Dark && ' +
        'grep -Fq "LookAndFeelPackage=com.github.vinceliuice.WhiteSur-dark" "$home/.config/kdeglobals" && ' +
        'grep -Fq "theme=__aurorae__svg__WhiteSur-dark" "$home/.config/kwinrc" && ' +
        'grep -Fq "gtk-theme-name=WhiteSur-Dark" "$home/.config/gtk-3.0/settings.ini" && ' +
        'echo ok'
    );

    expect(result, 'WhiteSur KDE/GTK theme state is incomplete').toBe('ok');
  });

  test('screen locker and wallet prompts are disabled', () => {
    test.info().annotations.push({
      type: 'requirement',
      description: 'AC-KDE-03'
    });

    const result = ssh(
      'home="$(getent passwd "$(id -un)" | cut -d: -f6)" && ' +
        'grep -Fq "Autolock=false" "$home/.config/kscreenlockerrc" && ' +
        'grep -Fq "LockOnResume=false" "$home/.config/kscreenlockerrc" && ' +
        'grep -Fq "Timeout=0" "$home/.config/kscreenlockerrc" && ' +
        'grep -Fq "Enabled=false" "$home/.config/kwalletrc" && ' +
        'grep -Fq "Hidden=true" "$home/.config/autostart/org.kde.polkit-kde-authentication-agent-1.desktop" && ' +
        'grep -Fq "Hidden=true" /etc/xdg/autostart/polkit-kde-authentication-agent-1.desktop && ' +
        'test -f /etc/polkit-1/rules.d/45-vnc-polkit.rules && ' +
        'grep -Fq "return polkit.Result.YES;" /etc/polkit-1/rules.d/45-vnc-polkit.rules && ' +
        '! ps -u "$(id -u)" -o comm= | grep -Fxq polkit-kde-aut && ' +
        '! ps -u "$(id -u)" -o comm= | grep -Fxq polkit-agent-he && ' +
        '! ps -u "$(id -u)" -o comm= | grep -Fxq kscreenlocker_g && ' +
        'echo ok'
    );

    expect(result, 'KDE lock/login prompts are not fully disabled').toBe('ok');
  });

  test('Konsole copy paste shortcuts are configured', () => {
    test.info().annotations.push({
      type: 'requirement',
      description: 'AC-KDE-04'
    });

    const result = ssh(
      'home="$(getent passwd "$(id -un)" | cut -d: -f6)" && ' +
        'test -x /usr/bin/konsole && ' +
        'test -f "$home/.local/share/kxmlgui5/konsole/sessionui.rc" && ' +
        'grep -Fq \'<Action name="edit_copy" shortcut="Ctrl+C"/>\' "$home/.local/share/kxmlgui5/konsole/sessionui.rc" && ' +
        'grep -Fq \'<Action name="edit_paste" shortcut="Ctrl+V; Shift+Ins"/>\' "$home/.local/share/kxmlgui5/konsole/sessionui.rc" && ' +
        'grep -Fq \'<Action name="sigint-signal" shortcut="Ctrl+Shift+C"/>\' "$home/.local/share/kxmlgui5/konsole/sessionui.rc" && ' +
        'echo ok'
    );

    expect(result, 'Konsole shortcut config is incomplete').toBe('ok');
  });
});
