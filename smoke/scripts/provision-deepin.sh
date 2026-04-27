#!/usr/bin/env bash
# provision-deepin.sh — install the Deepin desktop on the smoke test server.
#
# Usage:
#   bash smoke/scripts/provision-deepin.sh
#
# Requires 'pnpm infra:up' to have been run first.
#
# Note: deepin-desktop-environment is installed from the Ubuntu universe
# repository. Availability varies by Ubuntu release. The Ansible role
# proceeds best-effort and warns if the package is not found.

DESKTOP_TYPE="deepin"
# shellcheck source=_provision-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_provision-common.sh"
