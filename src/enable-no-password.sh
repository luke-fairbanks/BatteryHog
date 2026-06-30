#!/bin/bash
# Battery Hog — enable password-free Low Power Mode + energy readings.
#
# Installs a TIGHTLY-SCOPED sudoers rule that lets your user run ONLY these
# three exact commands without a password (nothing else):
#     /usr/bin/pmset -a lowpowermode 0
#     /usr/bin/pmset -a lowpowermode 1
#     /usr/bin/powermetrics --samplers tasks,cpu_power -n1 -i500
#
# Run once:   sudo bash enable-no-password.sh
# Undo:       sudo rm /etc/sudoers.d/battery-hog
set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run with sudo:  sudo bash \"$0\""
    exit 1
fi

USER_NAME="${SUDO_USER:-$(logname 2>/dev/null)}"
if [ -z "$USER_NAME" ] || [ "$USER_NAME" = "root" ]; then
    echo "Couldn't determine your username. Aborting."
    exit 1
fi

TMP="$(mktemp)"
cat > "$TMP" <<EOF
# Installed by Battery Hog. Lets $USER_NAME run ONLY these exact commands
# without a password. Remove with: sudo rm /etc/sudoers.d/battery-hog
$USER_NAME ALL=(root) NOPASSWD: /usr/bin/pmset -a lowpowermode 0
$USER_NAME ALL=(root) NOPASSWD: /usr/bin/pmset -a lowpowermode 1
$USER_NAME ALL=(root) NOPASSWD: /usr/bin/powermetrics --samplers tasks\,cpu_power -n1 -i500
EOF

# Validate BEFORE installing — a malformed sudoers file can lock you out of sudo.
if ! visudo -cf "$TMP" >/dev/null 2>&1; then
    echo "Validation failed; nothing was changed."
    rm -f "$TMP"
    exit 1
fi

install -m 0440 -o root -g wheel "$TMP" /etc/sudoers.d/battery-hog
rm -f "$TMP"

echo "✅ Done. Battery Hog will no longer ask $USER_NAME for a password"
echo "   for Low Power Mode or energy readings."
echo "   To undo later:  sudo rm /etc/sudoers.d/battery-hog"
