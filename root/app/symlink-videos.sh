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
VIDEO_LINKS="${VIDEO_LINKS:-/video-links}"
MOVIE_LINKS="${MOVIE_LINKS:-/movie-links}"

# -----------------------------
# Function definitions FIRST
# -----------------------------
# Logging function with automatic caller identification
log() {
    local caller="${FUNCNAME[1]:-main}"
    echo "[$caller] $*"
}

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

    log "Processing: $file_name"
    log "File extension: $ext"

    # Extract SxxExx
    log "Attempting to extract SxxExx token from: $file_name"
    token=$(echo "$file_name" | grep -oE 'S[0-9]{2}E[0-9]{2}' || echo "")
    log "Extracted token: '$token'"
    
    if [ -z "$token" ]; then
        log "ERROR: No SxxExx token found in '$file_name'"
        return 1
    fi

    season=$(echo "$token" | sed -E 's/S([0-9]{2})E[0-9]{2}/\1/')
    episode=$(echo "$token" | sed -E 's/S[0-9]{2}E([0-9]{2})/\1/')

    if [ -z "$season" ] || [ -z "$episode" ]; then
        log "ERROR: Could not parse season/episode from token '$token'"
        return 1
    fi

    # -----------------------------
    # CACHING LAYER
    # -----------------------------
    if [ "$raw_name" != "$CACHE_RAW_NAME" ]; then
        log "Refreshing Sonarr cache for series '$raw_name'"
        log "Querying: ${SONARR_URL}/api/v3/series/lookup?term=${raw_name}&apikey=***"

        CACHE_RAW_NAME="$raw_name"

        # Lookup series
        series_json=$(wget -qO- "${SONARR_URL}/api/v3/series/lookup?term=${raw_name}&apikey=${SONARR_API_KEY}")
        log "Response length: ${#series_json} bytes"
        [ -n "$series_json" ] && log "First 300 chars: $(echo "$series_json" | head -c 300)" || log "Empty response"
        
        CACHE_SERIES_TITLE=$(echo "$series_json" | jq -r '.[0].title' 2>/dev/null || echo "")
        CACHE_SERIES_ID=$(echo "$series_json" | jq -r '.[0].id' 2>/dev/null || echo "")
        log "Parsed - Title: '$CACHE_SERIES_TITLE', ID: '$CACHE_SERIES_ID'"

        if [ -z "$CACHE_SERIES_TITLE" ] || [ "$CACHE_SERIES_TITLE" = "null" ]; then
            log "ERROR: Sonarr could not identify series for '$raw_name'"
            CACHE_RAW_NAME=""
            return 1
        fi

        # Lookup all episodes for this series
        log "Querying episodes for series ID: $CACHE_SERIES_ID"
        CACHE_EPISODES_JSON=$(wget -qO- "${SONARR_URL}/api/v3/episode?seriesId=${CACHE_SERIES_ID}&apikey=${SONARR_API_KEY}")
        if [ -z "$CACHE_EPISODES_JSON" ]; then
            log "ERROR: Sonarr returned no episode list for '$CACHE_SERIES_TITLE'"
            CACHE_RAW_NAME=""
            return 1
        fi
        episode_count=$(echo "$CACHE_EPISODES_JSON" | jq 'length' 2>/dev/null || echo "0")
        log "Retrieved $episode_count episodes"
    else
        log "Using cached data for '$raw_name'"
    fi

    # -----------------------------
    # USE CACHED DATA
    # -----------------------------
    series_title="$CACHE_SERIES_TITLE"
    episodes_json="$CACHE_EPISODES_JSON"

    # Lookup episode title from cached JSON
    episode_title=$(echo "$episodes_json" | jq -r \
        ".[] | select(.seasonNumber==$season and .episodeNumber==$episode) | .title" 2>/dev/null || echo "")

    log "Looking for S${season}E${episode} - found title: '$episode_title'"

    if [ -z "$episode_title" ] || [ "$episode_title" = "null" ]; then
        log "ERROR: Sonarr has no metadata for S${season}E${episode}"
        return 1
    fi

    # Build folder + filename
    series_dir="${VIDEO_LINKS}/${series_title}"
    season_dir="${series_dir}/Season ${season}"
    mkdir -p "$season_dir"

    filename="${series_title} - S${season}E${episode} - ${episode_title}.${ext}"
    symlink_path="${season_dir}/${filename}"

    log "Creating symlink:"
    log "         $symlink_path"
    log "         -> $file_path"

    ln -sf "$file_path" "$symlink_path"
    log "OK"
}

create_video_symlink() {
    if [[ -e "$VIDEO_LINKS" ]] && [[ ! -d "$VIDEO_LINKS" ]]; then
        log "ERROR: VIDEO_LINKS exists and is not a directory: $VIDEO_LINKS" >&2
        exit 1
    fi

    mkdir -p "$VIDEO_LINKS"
    log "VIDEO_LINKS directory ready: $VIDEO_LINKS"

    raw_name=$(clean_raw_name "$TR_TORRENT_NAME")
    log "Cleaned torrent name: '$raw_name'"

    # Check if the downloaded item is a directory
    if [[ -d "$DOWNLOAD_PATH" ]]; then
        log "DOWNLOAD_PATH is a directory, scanning for video files..."
        # Only scan inside this specific torrent's directory
        find "$DOWNLOAD_PATH" -type f \( -name "*.mp4" -o -name "*.mkv" -o -name "*.avi" -o -name "*.mov" \) | while read -r video_file; do
            log "Found video file: $video_file"
            # Call the Sonarr naming function
            create_sonarr_symlink "$raw_name" "$video_file"
        done
        log "Directory scan complete"

    # Check if the downloaded item is a single file and matches video extensions
    elif [[ -f "$DOWNLOAD_PATH" ]]; then
        log "DOWNLOAD_PATH is a file: $DOWNLOAD_PATH"
        case "$TR_TORRENT_NAME" in
            *.mp4|*.mkv|*.avi|*.mov)
                log "File matches video extension, creating symlink..."
                # Call the Sonarr naming function
                create_sonarr_symlink "$raw_name" "$DOWNLOAD_PATH"
                ;;
            *)
                log "File does not match video extensions: $TR_TORRENT_NAME"
                ;;
        esac
    else
        log "ERROR: DOWNLOAD_PATH does not exist or is neither file nor directory: $DOWNLOAD_PATH" >&2
        log "Checking path existence:"
        if [ -e "$DOWNLOAD_PATH" ]; then
            log "Path exists but is not a regular file or directory"
        else
            log "Path does not exist"
        fi
    fi

    log "Done"
}
# ============================================================
#                     MOVIE / ONE-OFF LOGIC
# ============================================================
create_movie_symlink() {
    log "Detected Movie / One-off"

    # Clean movie title
    CLEAN_TITLE="$(echo "$TR_TORRENT_NAME" \
        | sed -E 's/\.[^.]+$//' \
        | sed -E 's/[0-9]{3,4}p//g' \
        | sed -E 's/WEBRip|WEB-DL|x264|H\.264|AAC|MP4//gi' \
        | sed -E 's/[[:space:]]+/ /g' \
        | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"

    if [[ -e "$MOVIE_LINKS" ]] && [[ ! -d "$MOVIE_LINKS" ]]; then
        log "ERROR: MOVIE_LINKS exists and is not a directory: $MOVIE_LINKS" >&2
        exit 1
    fi

    mkdir -p "$MOVIE_LINKS"
    log "MOVIE_LINKS directory ready: $MOVIE_LINKS"

    file_name="$(basename "$TR_TORRENT_NAME")"
    ext="${file_name##*.}"

    TARGET_FILE="$MOVIE_LINKS/${CLEAN_TITLE}.$ext"

    log "Creating Movie symlink:"
    log "  $TARGET_FILE"
    log "  -> $TR_TORRENT_NAME"

    ln -sf "$$DOWNLOAD_PATH" "$TARGET_FILE"
    exit 0
}
# -----------------------------
# Main logic (guarded)
# -----------------------------

log "TR_TORRENT_DIR: $TR_TORRENT_DIR"
log "TR_TORRENT_NAME: $TR_TORRENT_NAME"
log "DOWNLOAD_PATH: $DOWNLOAD_PATH"
log "SONARR_URL: $SONARR_URL"
log "VIDEO_LINKS: $VIDEO_LINKS"
log "MOVIE_LINKS: $MOVIE_LINKS"

# --- Validate required Transmission variables ---
: "${TR_TORRENT_DIR:?TR_TORRENT_DIR not set}"
: "${TR_TORRENT_NAME:?TR_TORRENT_NAME not set}"

# --- Detect TV episode pattern ---
if echo "$TR_TORRENT_NAME" | grep -qiE 'S[0-9]{2}E[0-9]{2}'; then
    log "Detected TV episode"
    create_video_symlink
else
    log "Detected Movie / One-off"
    create_movie_symlink
fi
