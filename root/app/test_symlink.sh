#!/bin/sh
# Test a single file
# ./test_symlink.sh file "/downloads/complete/Prog at the BBC (2009).SD.AVC.AAC.eng.mkv"
# Test a folder with mixed junk
# ./test_symlink.sh folder "/downloads/complete/Ms.X Series 1 (2026) [540p mp4] [NZ]"
# Test a folder 
# ./test_symlink.sh folder "/downloads/complete/The Rapture Series 1 (2026) [540p]"
# Load your functions
# shellcheck disable=SC2034
# shellcheck disable=SC2209
RUN_MODE=test

usage() {
    echo "Usage:"
    echo "  $0 file <path-to-video-file>"
    echo "  $0 folder <path-to-folder>"
    exit 1
}

if [ $# -lt 2 ]; then
    usage
fi

mode="$1"
target="$2"

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

# Fake torrent name for testing
raw_name=$(clean_raw_name "$TR_TORRENT_NAME")

case "$mode" in
    file)
        if [ ! -f "$target" ]; then
            echo "ERROR: '$target' is not a file"
            exit 1
        fi
        create_sonarr_symlink "$raw_name" "$target"
        ;;
    folder)
        if [ ! -d "$target" ]; then
            echo "ERROR: '$target' is not a folder"
            exit 1
        fi

        find "$target" -type f \( -name "*.mp4" -o -name "*.mkv" -o -name "*.avi" -o -name "*.mov" \) \
        | while read -r video_file; do
            create_sonarr_symlink "$raw_name" "$video_file"
        done
        ;;
    *)
        usage
        ;;
esac
