#!/usr/bin/env bash
# Mission Centre launcher for macOS
# Double-click this file in Finder, or run: bash launch.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$SCRIPT_DIR/mission-centre.sh"
exit_code=$?
if [[ $exit_code -ne 0 ]]; then
    echo ""
    echo "*** Mission Centre exited with error code $exit_code ***"
    printf "Press Enter to close... "; read -r _
fi
