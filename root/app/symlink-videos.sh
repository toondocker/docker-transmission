#!/bin/bash
# shellcheck shell=bash
set -euo pipefail

TARGET_DIR="${TARGET_DIR:-/video-links}"
DOWNLOAD_PATH="$TR_TORRENT_DIR/$TR_TORRENT_NAME"

if [[ -e "$TARGET_DIR" ]] && [[ ! -d "$TARGET_DIR" ]]; then
    echo "ERROR: TARGET_DIR exists and is not a directory: $TARGET_DIR" >&2
    exit 1
fi

mkdir -p "$TARGET_DIR"

# Check if the downloaded item is a directory
if [[ -d "$DOWNLOAD_PATH" ]]; then
    # Only scan inside this specific torrent's directory
    find "$DOWNLOAD_PATH" -type f \( -name "*.mp4" -o -name "*.mkv" -o -name "*.avi" -o -name "*.mov" \) | while read -r video_file; do
        file_name=$(basename "$video_file")
        ln -sf "$video_file" "$TARGET_DIR/$file_name" && \
            echo "Symlinked: $file_name" || echo "ERROR: Failed to symlink $file_name" >&2
    done

# Check if the downloaded item is a single file and matches video extensions
elif [[ -f "$DOWNLOAD_PATH" ]]; then
    case "$TR_TORRENT_NAME" in
        *.mp4|*.mkv|*.avi|*.mov)
            ln -sf "$DOWNLOAD_PATH" "$TARGET_DIR/$TR_TORRENT_NAME" && \
                echo "Symlinked: $TR_TORRENT_NAME" || echo "ERROR: Failed to symlink $TR_TORRENT_NAME" >&2
            ;;
    esac
fi
