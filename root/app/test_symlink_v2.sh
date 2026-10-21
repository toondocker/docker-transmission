#!/bin/sh
# test_symlink_v2.sh — Test runner for symlink-videos-v2.sh
#
# Examples:
#   ./test_symlink_v2.sh "/downloads/complete/Ms.X Series 1 (2026) [540p mp4] [NZ]/Ms.X S01E01 [540p mp4].mp4"
#   ./test_symlink_v2.sh "/downloads/complete/Dark City The Cleaner - Series 1 (2026) [540p mp4] [NZ]"
#   ./test_symlink_v2.sh "/downloads/complete/The Rapture Series 1 (2026) [540p]"
#   ./test_symlink_v2.sh "/downloads/complete/Prog at the BBC (2009).SD.AVC.AAC.eng.mkv"

usage() {
    echo "Usage:"
    echo "  $0 <path-to-video-file-or-folder>"
    exit 1
}

if [ $# -lt 1 ]; then
    usage
fi

target="$1"

if [ -z "${target:-}" ]; then
    echo "ERROR: target not set"
    exit 1
fi

TR_TORRENT_DIR="$(dirname "$target")"
TR_TORRENT_NAME="$(basename "$target")"
DRY_RUN="${DRY_RUN:-1}"  # Default to DRY_RUN=1 during testing

export TR_TORRENT_DIR
export TR_TORRENT_NAME
export DRY_RUN

SCRIPT_DIR="$(dirname "$0")"

# Execute symlink-videos-v2.sh
sh "${SCRIPT_DIR}/symlink-videos-v2.sh"
