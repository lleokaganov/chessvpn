#!/usr/bin/env bash
#
# One-time Linux setup for the chess VPN app.
#
# TUN mode needs root. To avoid a password prompt on every connect, this installs a
# small privileged helper and whitelists ONLY that helper in sudoers (NOPASSWD) — not
# general sudo. Run from the repo root:  sudo ./scripts/install-linux.sh
#
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CORE_SRC="${CHESSVPN_CORE:-$REPO/desktop/sing-box}"     # override for non-amd64 arches
HELPER_SRC="$REPO/desktop/chessvpn-helper"
USER_NAME="${SUDO_USER:-$(id -un)}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo: sudo $0" >&2
  exit 1
fi
[ -f "$CORE_SRC" ]   || { echo "core not found: $CORE_SRC (set CHESSVPN_CORE=/path/to/sing-box)"; exit 1; }
[ -f "$HELPER_SRC" ] || { echo "helper not found: $HELPER_SRC"; exit 1; }

install -d /usr/local/lib/chessvpn
install -m755 "$CORE_SRC"   /usr/local/lib/chessvpn/sing-box
install -m755 "$HELPER_SRC" /usr/local/bin/chessvpn-helper

printf '%s ALL=(root) NOPASSWD: /usr/local/bin/chessvpn-helper *\n' "$USER_NAME" \
  > /etc/sudoers.d/chessvpn
chmod 440 /etc/sudoers.d/chessvpn
visudo -cf /etc/sudoers.d/chessvpn

echo "OK: core + helper installed; passwordless for user '$USER_NAME'."
echo "Run the app:  app/build/linux/x64/release/bundle/twomove"
