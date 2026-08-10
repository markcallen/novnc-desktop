#!/usr/bin/env bash
# provision-openbox.sh — install the openbox-compatible lightweight XFCE desktop on the smoke test server.
#
# Usage:
#   bash smoke/scripts/provision-openbox.sh
#
# Requires 'pnpm infra:up' to have been run first.

DESKTOP_TYPE="openbox"
# shellcheck source=_provision-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_provision-common.sh"
