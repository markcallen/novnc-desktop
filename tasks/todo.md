# WhiteSur KDE Variant Plan

## Status

- Branch: `review/whitesur-kde-variant`
- Mode: Approval-Required
- Scope: first implementation pass for `desktop_type=kde`, smoke provisioning,
  e2e coverage, and AMI plumbing

## Implementation Status

- [x] PRD updated for the KDE variant contract.
- [x] KDE desktop role task file added.
- [x] KDE VNC startup template added.
- [x] `pnpm provision:kde` command added.
- [x] `pnpm infra:ami:kde` command added.
- [x] KDE-specific Playwright smoke tests added.
- [ ] Live `pnpm infra:up && pnpm provision:kde && pnpm test` validation.
- [ ] Live KDE AMI build/launch validation.

## Source Review

- User-requested theme repo: `https://github.com/vinceliuice/whitesur-gtk-theme`
- KDE-specific companion repo: `https://github.com/vinceliuice/WhiteSur-kde`
- WhiteSur GTK provides GTK, GNOME Shell, Cinnamon, Metacity, XFWM, and Plank themes. It is useful for GTK applications running inside KDE, but it is not enough to theme Plasma itself.
- WhiteSur KDE provides Plasma global theme assets, Aurorae window decorations, Kvantum assets, wallpaper, Plasma color schemes, and Plasma desktop theme assets. This should be the primary source for the KDE variant.
- WhiteSur KDE recommends Kvantum for better rendering and separately recommends WhiteSur icon and cursor themes for consistency.
- Current upstream risk: `WhiteSur-kde` has open Plasma 6 compatibility reports, including a 2026 issue titled "Global theme causes complete desktop failure on Plasma 6". Treat Plasma 6 support as a validation risk, not an assumption.

## Governing Requirements

- Update `PRD.md` before implementation.
- Amend `FR-1.3` and defaults docs to include `kde` as an accepted `desktop_type`.
- Add a KDE-specific `FR-5.x` requirement covering:
  - KDE Plasma session installation on Ubuntu 24.04.
  - WhiteSur KDE theme installation and application.
  - WhiteSur GTK theme installation for GTK apps inside KDE.
  - Display manager masking so TigerVNC owns the display.
  - Smoke marker behavior equivalent to existing variants.
- Amend `FR-8.1` so `build-ami.sh` produces AMIs for `openbox`, `elementary`, and `kde`.
- Add KDE acceptance criteria for a rendered KDE session and applied WhiteSur theme evidence.

## Implementation Plan

1. PRD and docs
   - Update `PRD.md` accepted desktop variants and add KDE/WhiteSur requirements.
   - Update `README.md`, `docs/custom-ports.md`, and `docs/packer-build.md` variant references.
   - Decide whether the public release language should promise KDE AMIs immediately or describe it as buildable until smoke evidence exists.

2. Desktop role structure
   - Update `roles/desktop/defaults/main.yml` comments to include `kde`.
   - Update `roles/desktop/tasks/main.yml` validation from `openbox, elementary` to `openbox, elementary, kde`.
   - Add `roles/desktop/tasks/kde.yml`.
   - Add `roles/desktop/templates/xstartup-kde.j2`.

3. KDE package baseline
   - Prefer Ubuntu 24.04 repo packages before PPAs:
     - `kde-plasma-desktop` or a narrower Plasma package set if testing shows it starts reliably under TigerVNC.
     - `plasma-workspace`, `kwin-x11`, `dbus-x11`, `xterm`, `wmctrl`.
     - `qt5ct`/`qt6ct` only if needed to make Kvantum/theme selection deterministic.
     - `kvantum`/`qt5-style-kvantum` if available in Noble repos; otherwise add an explicit documented fallback.
   - Mask display managers likely pulled in by KDE packages: `sddm`, `lightdm`, and `gdm3`.

4. WhiteSur installation design
   - Install `git` as a desktop dependency if not already guaranteed.
   - Clone or download pinned upstream refs rather than floating `master`.
   - Use `WhiteSur-kde` as the primary Plasma theme source.
   - Use `WhiteSur-gtk-theme` to install GTK themes into the VNC user's theme directory and optionally system-wide if required by Chrome/GTK apps.
   - Consider adding defaults:
     - `whitesur_kde_ref`
     - `whitesur_gtk_ref`
     - `whitesur_color_variant`
     - `whitesur_window_variant`
   - Avoid running interactive installers. Use installer flags where stable; if installer behavior is not idempotent enough, copy known asset directories with Ansible `copy`/`synchronize` after checkout.

5. KDE session startup
   - Start KDE through `dbus-launch --exit-with-session`.
   - Force X11 session variables:
     - `XDG_CURRENT_DESKTOP=KDE`
     - `XDG_SESSION_DESKTOP=KDE`
     - `XDG_SESSION_TYPE=x11`
   - Start with either `startplasma-x11` or a minimal `kwin_x11` plus Plasma shell path, choosing the one that survives TigerVNC smoke testing.
   - Add a smoke marker xterm when `smoke_test_marker_enabled=true`.
   - Add focus handling with `wmctrl -a SMOKE_READY`, similar to the Elementary startup path, if Plasma steals focus.

6. Apply theme deterministically
   - Apply Plasma look and feel with `lookandfeeltool` if it works non-interactively under the target session.
   - Seed KDE config files under the VNC user's home for:
     - global theme/look and feel
     - color scheme
     - Aurorae/KWin decoration
     - icon theme if WhiteSur icons are added
     - Kvantum theme selection
   - Restart or start Plasma only after config is present.

7. Smoke and AMI plumbing
   - Add `smoke/scripts/provision-kde.sh`.
   - Add package scripts:
     - `provision:kde`
     - `infra:ami:kde`
   - Update `smoke/scripts/infra-ami.sh` variant validation and examples.
   - Update `scripts/build-ami.sh` variant counts, status output, quota checks, and final messages.
   - Add an `amazon-ebs.kde` source and KDE Ansible provisioner in `packer.pkr.hcl`.
   - Update `scripts/cleanup-amis.sh` to accept `kde`.

8. Tests
   - Extend existing desktop canvas smoke coverage to run for KDE through `desktopType=kde`.
   - Add a KDE-specific smoke test file only for behavior not covered generically, such as verifying:
     - `startplasma-x11` or Plasma shell process is active.
     - WhiteSur Plasma theme files exist in the expected system/user directories.
     - KDE config selects a WhiteSur look-and-feel/color/decorator.
     - Optional: screenshot/canvas color or window decoration signal if stable enough.
   - Update `smoke/tests/state.ts` error text to include `provision:kde`.
   - Keep Elementary-specific tests skipped unless `desktopType=elementary`.

9. Verification
   - Static checks:
     - `ansible-playbook --syntax-check site.yml`
     - `ansible-lint`
     - `yamllint .`
     - `pnpm run lint`
     - `pnpm run prettier`
     - `pnpm test:unit`
   - Live direct provisioning:
     - `pnpm infra:up`
     - `pnpm provision:kde`
     - `pnpm test`
   - AMI path:
     - `pnpm run build:ami` or targeted dry run first if added.
     - `pnpm infra:ami:kde`
     - `pnpm test`
   - Idempotency:
     - Re-run the KDE Ansible provisioning against the same host and confirm no disruptive service/theme changes.

## Risks And Open Questions

- Plasma 6 under TigerVNC may require additional software rendering or compositor controls. Validate before promising the variant as fully supported.
- WhiteSur KDE upstream has open Plasma 6 failure reports; pinning to a known-good commit may be necessary.
- Running upstream install scripts as root is less auditable than copying assets with Ansible modules. Prefer pinned refs and deterministic copy/config tasks where practical.
- KDE increases AMI size and provisioning time significantly compared with Openbox.
- Kvantum availability and Qt 6 integration on Ubuntu 24.04 need live validation.
- Theme verification should avoid brittle screenshot-only assertions; prefer file/config/process checks plus the existing canvas smoke marker.

## Rollback Strategy

- Revert `desktop_type=kde` from `PRD.md`, docs, package scripts, Packer, and smoke scripts.
- Remove `roles/desktop/tasks/kde.yml` and `xstartup-kde.j2`.
- Keep existing `openbox` and `elementary` code paths untouched so rollback is a branch revert with no migration.
- Do not publish KDE AMIs until direct provisioning and AMI smoke evidence both pass.
