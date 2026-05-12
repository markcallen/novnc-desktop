#!/usr/bin/env bash
# provision-elementary-custom-ports.sh — install Elementary with nginx on 8080/8443.
#
# Usage:
#   bash smoke/scripts/provision-elementary-custom-ports.sh
#
# Requires 'pnpm infra:up' to have been run first.

DESKTOP_TYPE="elementary"
NOVNC_HTTP_PORT=8080
NOVNC_HTTPS_PORT=8443
# shellcheck source=_provision-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_provision-common.sh"
