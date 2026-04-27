#!/usr/bin/env bash
# provision-elementary.sh — install the Elementary (Pantheon) desktop on the smoke test server.
#
# Usage:
#   bash smoke/scripts/provision-elementary.sh
#
# Requires 'pnpm infra:up' to have been run first.
#
# Note: elementary-desktop is installed from ppa:elementary-os/stable which may
# lag behind Ubuntu LTS releases. The Ansible role proceeds best-effort and
# warns if the PPA does not yet support the host's Ubuntu version.

DESKTOP_TYPE="elementary"
# shellcheck source=_provision-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_provision-common.sh"
