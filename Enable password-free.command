#!/bin/bash
# Double-click to let Battery Hog skip the password prompt for Low Power Mode
# and energy readings. You'll be asked for your Mac password ONCE.
cd "$(dirname "$0")" || exit 1
echo "Battery Hog — enable password-free mode"
echo "----------------------------------------"
echo "This installs a tightly-scoped rule so Battery Hog can run just two"
echo "commands (Low Power Mode + powermetrics) without asking each time."
echo "You'll be asked for your Mac password once."
echo
sudo bash "src/enable-no-password.sh"
echo
echo "You can close this window."
