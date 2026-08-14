#!/bin/bash
# shellcheck shell=bash
set -euo pipefail

CACHE_RAW_NAME=""
CACHE_SERIES_TITLE=""
CACHE_SERIES_ID=""
CACHE_EPISODES_JSON=""
DOWNLOAD_PATH="$TR_TORRENT_DIR/$TR_TORRENT_NAME"
SONARR_URL="${SONARR_URL:-http://sonarr:8989}"
SONARR_API_KEY="${SONARR_API_KEY:-}"
SYMLINK_ROOT="${SYMLINK_ROOT:-/video-links}"

# -----------------------------
# Function definitions FIRST
# -----------------------------

clean_raw_name() {
    raw="$1"

    # Replace dots with spaces
    # shellcheck disable=SC2001
    raw=$(echo "$raw" | sed 's/\./ /g')

    # Remove bracketed junk
    # shellcheck disable=SC2001
    raw=$(echo "$raw" | sed 's/\[[^]]*\]//g')

    # Remove parentheses junk
    # shellcheck disable=SC2001
    raw=$(echo "$raw" | sed 's/([^)]*)//g')

    # Remove resolution tags
    # shellcheck disable=SC2001
    raw=$(echo "$raw" | sed -E 's/[0-9]{3,4}p//g')

    # Remove country codes
    # shellcheck disable=SC2001
    raw=$(echo "$raw" | sed -E 's/\b(NZ|UK|US|AU)\b//g')

    # Collapse spaces
    # shellcheck disable=SC2001
    raw=$(echo "$raw" | sed 's/  */ /g')

    # Trim
    raw=$(echo "$raw" | sed 's/^ *//;s/ *$//')

    echo "$raw"
}

# Requires: wget, jq (install jq in your Alpine container)
# apk add jq

create_sonarr_symlink() {
    raw_name="$1"
    file_path="$2"

    file_name=$(basename "$file_path")
    ext="${file_path##*.}"

    echo "[symlink] Processing: $file_name"

    # Extract SxxExx
    token=$(echo "$file_name" | grep -oE 'S[0-9]{2}E[0-9]{2}')
    if [ -z "$token" ]; then
        echo "[symlink] ERROR: No SxxExx token found in '$file_name'"
        return 1
    fi

    season=$(echo "$token" | sed -E 's/S([0-9]{2})E[0-9]{2}/\1/')
    episode=$(echo "$token" | sed -E 's/S[0-9]{2}E([0-9]{2})/\1/')

    if [ -z "$season" ] || [ -z "$episode" ]; then
        echo "[symlink] ERROR: Could not parse season/episode from token '$token'"
        return 1
    fi

    # -----------------------------
    # CACHING LAYER
    # -----------------------------
    if [ "$raw_name" != "$CACHE_RAW_NAME" ]; then
        echo "[cache] Refreshing Sonarr cache for series '$raw_name'"

        CACHE_RAW_NAME="$raw_name"

        # Lookup series
        series_json=$(wget -qO- "${SONARR_URL}/api/v3/series/lookup?term=${raw_name}&apikey=${SONARR_API_KEY}")
        CACHE_SERIES_TITLE=$(echo "$series_json" | jq -r '.[0].title')
        CACHE_SERIES_ID=$(echo "$series_json" | jq -r '.[0].id')

        if [ -z "$CACHE_SERIES_TITLE" ] || [ "$CACHE_SERIES_TITLE" = "null" ]; then
            echo "[symlink] ERROR: Sonarr could not identify series for '$raw_name'"
            CACHE_RAW_NAME=""
            return 1
        fi

        # Lookup all episodes for this series
        CACHE_EPISODES_JSON=$(wget -qO- "${SONARR_URL}/api/v3/episode?seriesId=${CACHE_SERIES_ID}&apikey=${SONARR_API_KEY}")
        if [ -z "$CACHE_EPISODES_JSON" ]; then
            echo "[symlink] ERROR: Sonarr returned no episode list for '$CACHE_SERIES_TITLE'"
            CACHE_RAW_NAME=""
            return 1
        fi
    fi

    # -----------------------------
    # USE CACHED DATA
    # -----------------------------
    series_title="$CACHE_SERIES_TITLE"
    # series_id="$CACHE_SERIES_ID"
    episodes_json="$CACHE_EPISODES_JSON"

    # Lookup episode title from cached JSON
    episode_title=$(echo "$episodes_json" | jq -r \
        ".[] | select(.seasonNumber==$season and .episodeNumber==$episode) | .title")

    if [ -z "$episode_title" ] || [ "$episode_title" = "null" ]; then
        echo "[symlink] ERROR: Sonarr has no metadata for S${season}E${episode}"
        return 1
    fi

    # Build folder + filename
    series_dir="${SYMLINK_ROOT}/${series_title}"
    season_dir="${series_dir}/Season ${season}"
    mkdir -p "$season_dir"

    filename="${series_title} - S${season}E${episode} - ${episode_title}.${ext}"
    symlink_path="${season_dir}/${filename}"

    echo "[symlink] Creating symlink:"
    echo "         $symlink_path"
    echo "         -> $file_path"

    ln -sf "$file_path" "$symlink_path"
    echo "[symlink] OK"
}


# -----------------------------
# Main logic (guarded)
# -----------------------------

if [ "$RUN_MODE" != "test" ]; then

    if [[ -e "$SYMLINK_ROOT" ]] && [[ ! -d "$SYMLINK_ROOT" ]]; then
        echo "ERROR: SYMLINK_ROOT exists and is not a directory: $SYMLINK_ROOT" >&2
        exit 1
    fi

    mkdir -p "$SYMLINK_ROOT"

    raw_name=$(clean_raw_name "$TR_TORRENT_NAME")

    # Check if the downloaded item is a directory
    if [[ -d "$DOWNLOAD_PATH" ]]; then
        # Only scan inside this specific torrent's directory
        find "$DOWNLOAD_PATH" -type f \( -name "*.mp4" -o -name "*.mkv" -o -name "*.avi" -o -name "*.mov" \) | while read -r video_file; do
            # file_name=$(basename "$video_file")
            # ln -sf "$video_file" "$SYMLINK_ROOT/$file_name" && \
            #     echo "Symlinked: $file_name" || echo "ERROR: Failed to symlink $file_name" >&2
            # Call the Sonarr naming function
            create_sonarr_symlink "$raw_name" "$video_file"
        done

    # Check if the downloaded item is a single file and matches video extensions
    elif [[ -f "$DOWNLOAD_PATH" ]]; then
        case "$TR_TORRENT_NAME" in
            *.mp4|*.mkv|*.avi|*.mov)
                # ln -sf "$DOWNLOAD_PATH" "$SYMLINK_ROOT/$TR_TORRENT_NAME" && \
                #     echo "Symlinked: $TR_TORRENT_NAME" || echo "ERROR: Failed to symlink $TR_TORRENT_NAME" >&2
                # Call the Sonarr naming function
                create_sonarr_symlink "$raw_name" "$TR_TORRENT_NAME"
                ;;
        esac
    fi
fi