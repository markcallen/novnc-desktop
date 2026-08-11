# noVNC Desktop — XFCE Configuration

## Objective

Replace the Elementary/Pantheon desktop environment with a lightweight XFCE desktop optimized for use through noVNC.

The desktop should:

* Perform well over noVNC.
* Avoid unnecessary compositing and animations.
* Provide reliable clipboard support between the local browser and remote desktop.
* Provide a usable terminal with copy/paste.
* Include Google Chrome.
* Have a clean interface inspired by macOS.
* Minimize CPU and memory usage.
* Work well as an automated VM, container, or Kubernetes desktop.

## Target Architecture

```text
Browser
   │
   │ HTTPS / WebSocket
   ▼
noVNC
   │
   ▼
websockify
   │
   ▼
TigerVNC
   │
   ▼
XFCE
   ├── xfwm4
   ├── xfce4-panel
   ├── xfce4-terminal
   ├── xfce4-clipman
   └── Google Chrome
```

Elementary/Pantheon and Gala should not run inside the VNC session.

---

# 1. Install XFCE

Install a minimal XFCE environment rather than a complete Ubuntu desktop.

```bash
sudo apt update

sudo apt install -y \
    xfce4 \
    xfce4-goodies \
    xfce4-terminal \
    xfce4-clipman \
    xfce4-clipman-plugin \
    dbus-x11 \
    xclip \
    xsel
```

Do not install GNOME, Pantheon, Cinnamon, or another compositing desktop environment.

---

# 2. Fonts and Appearance

Install lightweight fonts and GTK assets.

```bash
sudo apt install -y \
    fonts-inter \
    fonts-noto \
    fonts-noto-color-emoji \
    adwaita-icon-theme-full
```

Configure XFCE approximately as follows:

```text
GTK Theme:       Adwaita
Icon Theme:      Adwaita
Default Font:    Inter 10
Monospace Font:  DejaVu Sans Mono 10
Hinting:         Slight
Subpixel:        None
```

The goal is not to reproduce macOS exactly.

Instead, use macOS as inspiration for a clean, minimal remote desktop.

---

# 3. Disable Compositing

Desktop compositing creates unnecessary framebuffer changes and should be disabled.

```bash
xfconf-query \
    -c xfwm4 \
    -p /general/use_compositing \
    -s false
```

Do not enable:

* transparency
* window shadows
* animated window transitions
* animated desktop effects
* blur
* translucent panels

Performance over noVNC takes priority over desktop effects.

---

# 4. XFCE Panel

Use a single panel at the top of the screen.

Suggested height:

```text
30 px
```

Example layout:

```text
┌────────────────────────────────────────────────────────────────────┐
│ Applications   Chrome   Terminal                  🔊  📋  14:03   │
├────────────────────────────────────────────────────────────────────┤
│                                                                    │
│                                                                    │
│                         Desktop                                    │
│                                                                    │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

Left side:

* Applications menu
* Chrome launcher
* Terminal launcher

Right side:

* Notification area
* Clipboard
* Volume
* Network status if applicable
* Clock

Avoid animated docks.

A dock such as Plank is unnecessary for the remote environment and generates additional screen updates.

---

# 5. Desktop Background

Use a solid or simple desktop background.

Avoid:

* high-resolution photographs
* gradients
* animated backgrounds
* frequently changing backgrounds

Simple backgrounds significantly reduce framebuffer changes and improve VNC compression.

---

# 6. Terminal

Use:

```text
xfce4-terminal
```

Terminal clipboard shortcuts should be:

```text
Copy           Ctrl+Shift+C
Paste          Ctrl+Shift+V
Select All     Ctrl+Shift+A
```

Standard X11 selection should also work:

```text
Select text    Copy to X11 selection
Middle click   Paste X11 selection
```

Install both `xclip` and `xsel` so scripts and applications can interact with the X11 clipboard.

---

# 7. Clipboard Manager

Run XFCE Clipman automatically.

Create:

```text
~/.config/autostart/
```

and configure `xfce4-clipman` to start with the desktop session.

For example:

```bash
mkdir -p ~/.config/autostart

cp /etc/xdg/autostart/xfce4-clipman-plugin-autostart.desktop \
    ~/.config/autostart/ 2>/dev/null || true
```

Clipboard data should work across:

```text
Local computer
      │
      ▼
Browser
      │
      ▼
noVNC clipboard
      │
      ▼
X11 clipboard
      │
      ├── Chrome
      └── xfce4-terminal
```

Verify noVNC's clipboard integration is enabled.

---

# 8. Google Chrome

Install Google Chrome rather than Chromium when possible.

Chrome should integrate with the XFCE GTK environment.

Configure Chrome appearance using:

```text
chrome://settings/appearance
```

Enable system title bars where supported.

Chrome should inherit the GTK/Adwaita appearance.

Do not enable browser animations or visual effects that provide little value remotely.

---

# 9. VNC Startup

The VNC session should explicitly start XFCE.

Example `xstartup`:

```bash
#!/bin/sh

unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS

exec dbus-run-session startxfce4
```

Make it executable:

```bash
chmod +x ~/.vnc/xstartup
```

Do not automatically launch Pantheon or Gala.

---

# 10. Prevent Multiple Desktop Sessions

The environment should avoid accidentally starting multiple desktop/window-manager sessions.

Useful diagnostics:

```bash
ps aux | grep -E \
    'gala|pantheon|Xvnc|Xtigervnc|Xorg|xfce|xfwm'
```

Also inspect login sessions:

```bash
loginctl list-sessions
```

There should normally be one XFCE window manager associated with each active VNC desktop.

Unexpected multiple `gala`, `xfwm4`, or desktop-session processes should be investigated.

---

# 11. Disable Pantheon/Gala

Gala should not run within the XFCE VNC session.

Verify:

```bash
pgrep -a gala
```

For a dedicated remote desktop image, Pantheon should not be installed at all.

The preferred base is:

```text
Ubuntu Server / minimal Ubuntu
        │
        ▼
XFCE
```

rather than:

```text
Elementary OS
      │
      ▼
Pantheon
      │
      ▼
XFCE
```

This reduces package count, memory consumption, background services, and the possibility of conflicting desktop components.

---

# 12. Recommended Packages

The resulting desktop image should contain approximately:

```text
xfce4
xfce4-goodies
xfce4-terminal
xfce4-clipman
xfce4-clipman-plugin
dbus-x11

xclip
xsel

fonts-inter
fonts-noto
fonts-noto-color-emoji
adwaita-icon-theme-full

tigervnc

websockify
novnc

google-chrome
```

Avoid installing unnecessary desktop applications.

---

# 13. Performance Priorities

Optimize in this order:

1. Input latency
2. Browser responsiveness
3. Terminal responsiveness
4. Clipboard reliability
5. Screen update latency
6. CPU utilization
7. Memory utilization
8. Visual appearance

Visual effects should never take priority over remote desktop performance.

---

# 14. Screen Resolution

Use fixed, reasonable resolutions where possible.

Recommended defaults:

```text
1440x900
```

or:

```text
1280x800
```

Support larger resolutions when requested, but don't default to 4K.

The number of pixels VNC must process and transmit has a direct impact on remote desktop performance.

---

# 15. Session Environment

Set a predictable desktop environment:

```bash
export XDG_CURRENT_DESKTOP=XFCE
export XDG_SESSION_DESKTOP=xfce
export DESKTOP_SESSION=xfce
```

Ensure `DISPLAY` points to the appropriate TigerVNC display.

---

# 16. Desired User Experience

When the user opens `novnc-desktop`, they should see a clean desktop immediately.

The desktop should resemble:

```text
┌──────────────────────────────────────────────────────────────────┐
│ Applications    🌐 Chrome    >_ Terminal           📋 🔊  14:03 │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│                                                                  │
│                                                                  │
│                        Clean Desktop                             │
│                                                                  │
│                                                                  │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

Chrome and Terminal should be available with one click.

Copy/paste should work naturally between the user's computer and applications running inside the remote desktop.

---

# 17. Acceptance Tests

## Desktop

```bash
pgrep -a xfwm4
```

should return the XFCE window manager.

```bash
pgrep -a gala
```

should return nothing.

## Compositor

```bash
xfconf-query \
    -c xfwm4 \
    -p /general/use_compositing
```

should return:

```text
false
```

## Clipboard

Verify:

```text
Local → Terminal
Local → Chrome
Terminal → Local
Chrome → Local
Terminal → Chrome
Chrome → Terminal
```

## Terminal

Verify:

```text
Ctrl+Shift+C
Ctrl+Shift+V
```

work correctly.

## Chrome

Verify Chrome:

* launches from the panel
* renders correctly
* can access the clipboard
* uses the GTK desktop appearance
* remains responsive while scrolling

## Sessions

Verify there is only one expected desktop session per VNC display.

---

# 18. Final Target

The resulting stack should be:

```text
Ubuntu Minimal
     │
     ├── XFCE
     │    ├── xfwm4
     │    │    └── compositor OFF
     │    ├── xfce4-panel
     │    ├── xfce4-terminal
     │    └── xfce4-clipman
     │
     ├── Google Chrome
     │
     ├── TigerVNC
     │
     ├── websockify
     │
     └── noVNC
```

The desktop should prioritize a fast remote-development experience rather than recreating a full local workstation desktop.

