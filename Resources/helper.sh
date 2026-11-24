#!/bin/bash
# Installs / uninstalls the FanControl root helper as a LaunchDaemon.
# Usage: helper.sh install <path-to-FanControlHelper>
#        helper.sh uninstall
set -euo pipefail

LABEL="local.fancontrol.helper"
DEST="/Library/PrivilegedHelperTools/$LABEL"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

unload() {
  launchctl bootout system "$PLIST" 2>/dev/null || true
}

case "${1:-}" in
  install)
    SRC="${2:?path to FanControlHelper binary}"
    unload
    mkdir -p /Library/PrivilegedHelperTools
    install -m 0755 -o root -g wheel "$SRC" "$DEST"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$DEST</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/var/log/fancontrol-helper.log</string>
  <key>StandardErrorPath</key><string>/var/log/fancontrol-helper.log</string>
</dict>
</plist>
EOF
    chown root:wheel "$PLIST"
    chmod 0644 "$PLIST"
    launchctl bootstrap system "$PLIST"
    # Wait for the socket so the app can connect right away.
    for _ in $(seq 1 30); do [[ -S /var/run/fancontrol.sock ]] && break; sleep 0.1; done
    echo "Helper installed."
    ;;
  uninstall)
    unload
    rm -f "$PLIST" "$DEST" /var/run/fancontrol.sock
    echo "Helper removed."
    ;;
  *)
    echo "Usage: $0 install <helper-binary> | uninstall" >&2
    exit 1
    ;;
esac
