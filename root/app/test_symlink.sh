#!/bin/sh
# Test a single file
# ./test_symlink.sh file "/path/to/Ms.X.S01E01.mkv"
# Test a folder
# ./test_symlink.sh folder "/path/to/downloaded/torrent/"
# Test a folder with mixed junk
# ./test_symlink.sh folder "/path/to/testdata/"

# Load your functions
# shellcheck disable=SC2034
# shellcheck disable=SC2209
RUN_MODE=test
# shellcheck disable=SC1091
. /symlink-videos.sh

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

# Fake torrent name for testing
raw_name=$(clean_raw_name "$(basename "$target")")

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
