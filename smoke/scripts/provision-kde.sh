#!/usr/bin/env bash
# provision-kde.sh — install the KDE Plasma WhiteSur desktop on the smoke test server.
#
# Usage:
#   bash smoke/scripts/provision-kde.sh
#
# Requires 'pnpm infra:up' to have been run first.

DESKTOP_TYPE="kde"
# shellcheck source=_provision-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_provision-common.sh"
