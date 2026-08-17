#!/bin/bash
# Test a single file
# ./test_symlink.sh  "/downloads/complete/Prog at the BBC (2009).SD.AVC.AAC.eng.mkv"
# Test a folder with mixed junk
# ./test_symlink.sh  "/downloads/complete/Ms.X Series 1 (2026) [540p mp4] [NZ]"
# Test a folder 
# ./test_symlink.sh  "/downloads/complete/The Rapture Series 1 (2026) [540p]"
# Load your functions

usage() {
    echo "Usage:"
    echo "  $0 <path-to-video-file>"
    echo "  $0 <path-to-folder>"
    exit 1
}

if [ $# -lt 1 ]; then
    usage
fi

target="$1"

# Extract TR_TORRENT_DIR and TR_TORRENT_NAME from the target path
if [ -z "${target:-}" ]; then
    echo "ERROR: target not set"
    exit 1
fi

TR_TORRENT_DIR="$(dirname "$target")"
TR_TORRENT_NAME="$(basename "$target")"
export TR_TORRENT_DIR
export TR_TORRENT_NAME

# Load the symlink-videos.sh script - have to do this after exporting TR_TORRENT_DIR and TR_TORRENT_NAME
# shellcheck disable=SC1091
. ./symlink-videos.sh
