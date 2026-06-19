#!/usr/bin/env bash
set -euo pipefail

# Install a macOS launchd job that backs up the local dev instance every 6 hours
# and commits when the rolling export changes (daily at most if unchanged between runs).
#
# Usage:
#   ./scripts/install-backup-schedule.sh
#   ./scripts/install-backup-schedule.sh --uninstall

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LABEL="com.gavin.paperclip-instance-backup"
PLIST_PATH="$HOME/Library/LaunchAgents/${LABEL}.plist"
BACKUP_SCRIPT="$PROJECT_ROOT/scripts/backup-instance.sh"

if [[ "${1:-}" == "--uninstall" ]]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST_PATH"
  echo "Removed $PLIST_PATH"
  exit 0
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "launchd installer is macOS-only. Use cron instead:" >&2
  echo "  0 */6 * * * cd $PROJECT_ROOT && ./scripts/backup-instance.sh --commit" >&2
  exit 1
fi

chmod +x "$BACKUP_SCRIPT"

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${BACKUP_SCRIPT}</string>
    <string>--commit</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${PROJECT_ROOT}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PAPERCLIP_HOME</key>
    <string>${PROJECT_ROOT}/data/local-dev</string>
    <key>PATH</key>
    <string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StartInterval</key>
  <integer>21600</integer>
  <key>StandardOutPath</key>
  <string>${PROJECT_ROOT}/backups/paperclip-local-dev/backup-schedule.log</string>
  <key>StandardErrorPath</key>
  <string>${PROJECT_ROOT}/backups/paperclip-local-dev/backup-schedule.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
launchctl enable "gui/$(id -u)/$LABEL"
echo "Installed launchd job: $LABEL (every 6 hours, with --commit)"
echo "Logs: $PROJECT_ROOT/backups/paperclip-local-dev/backup-schedule.log"
