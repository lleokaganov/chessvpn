#!/usr/bin/env bash
#
# One-time Linux setup for the chess VPN app.
#
# TUN mode needs the CAP_NET_ADMIN/CAP_NET_RAW capabilities (to create the tun device
# and program routes) — but NOT full root. So instead of a passwordless root helper
# (which was a local-privilege-escalation hole: any local process could run an
# arbitrary sing-box config as root), we grant just those two capabilities to the core
# binary itself. The app then runs it directly as your normal user — no sudo, no
# password at connect time, and an attacker-supplied config can never become root.
#
# Run from the repo root:  sudo ./scripts/install-linux.sh
#
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CORE_SRC="${CHESSVPN_CORE:-$REPO/desktop/sing-box}"     # override for non-amd64 arches
CORE_DST=/usr/local/lib/chessvpn/sing-box

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo: sudo $0" >&2
  exit 1
fi
[ -f "$CORE_SRC" ] || { echo "core not found: $CORE_SRC (set CHESSVPN_CORE=/path/to/sing-box)"; exit 1; }
command -v setcap >/dev/null 2>&1 || {
  echo "setcap not found — install libcap2-bin (Debian/Ubuntu) or libcap (Fedora/Arch) and re-run." >&2
  exit 1
}

# --- migrate away from the old NOPASSWD root helper, if a previous version left it ---
if [ -e /etc/sudoers.d/chessvpn ] || [ -e /usr/local/bin/chessvpn-helper ]; then
  echo "Removing the old privileged helper + sudoers rule (no longer used)…"
  rm -f /etc/sudoers.d/chessvpn /usr/local/bin/chessvpn-helper
fi

# --- install the core (root-owned so the capability can't be swapped by a user) ---
install -d -m755 /usr/local/lib/chessvpn
install -o root -g root -m755 "$CORE_SRC" "$CORE_DST"

# --- grant ONLY the network capabilities; this is what replaces root ---
setcap 'cap_net_admin,cap_net_raw+ep' "$CORE_DST"

# verify it took (some filesystems mounted nosuid/noexec silently drop file caps)
if ! getcap "$CORE_DST" | grep -q cap_net_admin; then
  echo "WARNING: capabilities did not stick on $CORE_DST." >&2
  echo "  This filesystem may be mounted nosuid, or doesn't support file caps." >&2
  echo "  The VPN will fail to create the tunnel. Install onto a normal ext4/xfs path." >&2
  exit 1
fi

# --- let the core program systemd-resolved DNS on its tun without a password ---
# cap_net_admin covers routes, but resolved DNS goes via D-Bus → polkit, which would
# otherwise prompt every connect (defeating the no-password goal). Grant ONLY the
# resolve1 actions, ONLY to the installing user. Supports both polkit flavours.
USER_NAME="${SUDO_USER:-$(id -un)}"
if [ -d /etc/polkit-1/rules.d ]; then                      # modern polkit (>=0.106, JS)
  cat > /etc/polkit-1/rules.d/49-chessvpn.rules <<RULE
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.resolve1.") === 0 &&
        subject.user === "$USER_NAME" && subject.local && subject.active) {
        return polkit.Result.YES;
    }
});
RULE
  echo "polkit (rules.d): resolved DNS allowed for '$USER_NAME' without password."
elif [ -d /etc/polkit-1/localauthority/50-local.d ]; then  # legacy polkit (0.105, .pkla)
  cat > /etc/polkit-1/localauthority/50-local.d/49-chessvpn.pkla <<RULE
[chessvpn resolved DNS without password]
Identity=unix-user:$USER_NAME
Action=org.freedesktop.resolve1.*
ResultAny=yes
ResultInactive=yes
ResultActive=yes
RULE
  echo "polkit (.pkla): resolved DNS allowed for '$USER_NAME' without password."
else
  echo "NOTE: no polkit rules dir found — you may be prompted to 'set domains' on connect."
fi

echo "OK: core installed at $CORE_DST with cap_net_admin,cap_net_raw — no root needed."
echo "    $(getcap "$CORE_DST")"
echo "Run the app:  app/build/linux/x64/release/bundle/twomove"
echo
echo "Note: any local user who can execute $CORE_DST gains CAP_NET_ADMIN (network"
echo "      reconfiguration — NOT root). On a shared machine, restrict it to a group:"
echo "      groupadd -f chessvpn && chgrp chessvpn $CORE_DST && chmod 0750 $CORE_DST"
echo "      then add trusted users with: usermod -aG chessvpn <user> (re-login needed)."
