#!/bin/bash
# Test a single file
# ./test_symlink.sh  "/downloads/complete/Prog at the BBC (2009).SD.AVC.AAC.eng.mkv"
# ./test_symlink.sh  "/downloads/complete/Ms.X Series 1 (2026) [540p mp4] [NZ]/Ms.X S01E01 [540p mp4].mp4"
# Test a folder with mixed junk
# ./test_symlink.sh  "/downloads/complete/Ms.X Series 1 (2026) [540p mp4] [NZ]"
# Test a folder 
# ./test_symlink.sh  "/downloads/complete/The Rapture Series 1 (2026) [540p]"
# ------------------------------------------------------------------------------------ 
# Delete one symlink	            rm symlink
# Delete all symlinks in a folder	find folder -type l -delete
# Delete entire show folder	        rm -r folder
# ------------------------------------------------------------------------------------ 

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
DRY_RUN=1  # Set to 1 to prevent actual symlink creation during testing
export TR_TORRENT_DIR
export TR_TORRENT_NAME
export DRY_RUN

# Load the symlink-videos.sh script - have to do this after exporting TR_TORRENT_DIR and TR_TORRENT_NAME
# shellcheck disable=SC1091
. ./symlink-videos.sh
