#!/bin/sh
# shellcheck shell=ash

# ═══════════════════════════════════════════════════════════════════
# postprocess.sh — Unified torrent post-process
#
# Handles TV releases (via Sonarr) and Movies / one-offs (via Radarr).
# Creates Jellyfin-compatible symlinks in the correct directory layout.
#
# Compatible: BusyBox sh / POSIX sh — no bash, no jq, no python, no perl
#
# Usage:  set as Transmission's "Script to run when torrent is done" — no arguments needed
#
# Transmission-set environment (automatic):
#   TR_TORRENT_NAME   torrent display name
#   TR_TORRENT_DIR    directory where the torrent was saved
#
# Environment:
#   SONARR_API_KEY        required for TV releases
#   RADARR_API_KEY        required for movie releases
#   SONARR_URL            default: http://sonarr:8989
#   RADARR_URL            default: http://radarr:7878
#   VIDEO_LINKS           default: /video-links
#   MOVIE_LINKS           default: /movie-links
#   LOG_FILE              default: /tmp/postprocess.log
#   DRY_RUN=1             log actions; write nothing to disk
#   FORCE_TV=1            skip detection; treat as TV
#   FORCE_MOVIE=1         skip detection; treat as movie/one-off
#
# Exit codes:
#   0   success
#   1   bad arguments / fatal config
#   10  release type unrecognised
#   20  Sonarr / Radarr returned no match
#   30  symlink creation failure
# ═══════════════════════════════════════════════════════════════════


# ───────────────────────────────────────────────────────────────────
# §1  CONFIGURATION
# ───────────────────────────────────────────────────────────────────

SONARR_URL="${SONARR_URL:-http://sonarr:8989}"
RADARR_URL="${RADARR_URL:-http://radarr:7878}"
SONARR_API_KEY="${SONARR_API_KEY:-}"
RADARR_API_KEY="${RADARR_API_KEY:-}"
JELLYFIN_TV_ROOT="${VIDEO_LINKS:-/video-links}"
JELLYFIN_MOVIES_ROOT="${MOVIE_LINKS:-/movie-links}"
LOG_FILE="${LOG_FILE:-/tmp/postprocess.log}"
DRY_RUN="${DRY_RUN:-0}"
FORCE_TV="${FORCE_TV:-0}"
FORCE_MOVIE="${FORCE_MOVIE:-0}"
VIDEO_EXTS="mp4 mkv avi mov m4v ts"

# Runtime globals — written by functions, consumed by handlers / mainline
CANONICAL_TITLE=""
SERIES_ID=""
SERIES_TITLE=""
SEASON_NUM=""
EPISODE_NUM=""
EPISODE_TITLE=""
MOVIE_TITLE=""
MOVIE_YEAR=""
_TMPDIR=""
_LOG_CTX="main"

# ───────────────────────────────────────────────────────────────────
# §2  UTILITIES
# ───────────────────────────────────────────────────────────────────

# ── Scratch-file workspace ──────────────────────────────────────────
# All temp state that must survive across subshell boundaries is
# written to individual files inside a private mktemp directory, then
# read back with "< file" redirects (same-shell, no subshell created).

_tmpfile() {
    if [ -z "$_TMPDIR" ]; then
        _TMPDIR=$(mktemp -d /tmp/postproc.XXXXXX) \
            || { printf 'FATAL: mktemp failed\n' >&2; exit 1; }
    fi
    printf '%s/%s' "$_TMPDIR" "$1"
}

# shellcheck disable=SC2329,SC2317
_cleanup() { [ -n "$_TMPDIR" ] && rm -rf "$_TMPDIR"; } 
trap _cleanup EXIT HUP INT TERM

# ── Structured logging ──────────────────────────────────────────────
_ts()       { date '+%Y-%m-%dT%H:%M:%S'; }
log_info()  { printf '[%s] INFO  [%s] %s\n'  "$(_ts)" "$_LOG_CTX" "$*" | tee -a "$LOG_FILE"; }
log_warn()  { printf '[%s] WARN  [%s] %s\n'  "$(_ts)" "$_LOG_CTX" "$*" | tee -a "$LOG_FILE"; }
log_error() { printf '[%s] ERROR [%s] %s\n'  "$(_ts)" "$_LOG_CTX" "$*" | tee -a "$LOG_FILE"
              printf '[%s] ERROR [%s] %s\n'  "$(_ts)" "$_LOG_CTX" "$*" >&2; }
log_debug() { printf '[%s] DEBUG [%s] %s\n'  "$(_ts)" "$_LOG_CTX" "$*" >> "$LOG_FILE"; }

die() { log_error "$1"; exit "${2:-1}"; }

# ── Numeric helpers ─────────────────────────────────────────────────
pad2()        { printf '%02d' "${1:-0}"; }
strip_zeros() { printf '%d' "${1:-0}" 2>/dev/null || printf '%s' "$1"; }

# ── URL encoding (pure awk — fast, no perl / python needed) ─────────
urlencode() {
    printf '%s' "$1" | awk '
    BEGIN { for (i = 0; i <= 255; i++) ord[sprintf("%c", i)] = i }
    {
        n = split($0, ch, ""); out = ""
        for (i = 1; i <= n; i++) {
            c = ch[i]
            if      (c ~ /[A-Za-z0-9._~-]/) out = out c
            else if (c == " ")              out = out "%20"
            else                            out = out sprintf("%%%02X", ord[c])
        }
        printf "%s", out
    }'
}


# ───────────────────────────────────────────────────────────────────
# §3  JSON HELPERS  (grep + sed; no jq)
#
# Designed for the minified, single-line arrays that Sonarr / Radarr
# return.  Not a general-purpose JSON parser.
# ───────────────────────────────────────────────────────────────────

# json_str <key> <json>  →  string value, unquoted
json_str() {
    printf '%s' "$2" \
        | grep -o "\"${1}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
        | sed "s/\"${1}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\"/\1/" \
        | head -1
}

# json_num <key> <json>  →  numeric / bool / null value, unquoted
json_num() {
    printf '%s' "$2" \
        | grep -o "\"${1}\"[[:space:]]*:[[:space:]]*[0-9A-Za-z_][^,}\"]*" \
        | sed "s/\"${1}\"[[:space:]]*:[[:space:]]*//" \
        | tr -d ' ' \
        | head -1
}

# json_split <json_array>  →  one top-level object per stdout line
json_split() {
    printf '%s' "$1" \
        | sed 's/^\[//; s/\]$//' \
        | sed 's/},{/}\{/g'
}


# ───────────────────────────────────────────────────────────────────
# §4  RELEASE DETECTION
#
# Patterns recognised as TV:
#   SxxExx / sXeX  (e.g. S01E03)
#   NxNN           (e.g. 1x03)
#   Series N / Season N  (BBC / NZ style)
#   Complete Series / Full Series
#
# Everything else is treated as a movie or one-off.
# Override with FORCE_TV=1 or FORCE_MOVIE=1.
# ───────────────────────────────────────────────────────────────────

_is_tv() {
    printf '%s' "$1" | grep -qiE '[Ss][0-9]{1,2}[Ee][0-9]{1,2}'           && return 0
    printf '%s' "$1" | grep -qE  '[0-9]{1,2}x[0-9]{1,2}'                  && return 0
    printf '%s' "$1" | grep -qiE '(Series|Season)[[:space:]_.+-]*[0-9]+'  && return 0
    printf '%s' "$1" | grep -qiE '(Complete|Full)[[:space:]_.+-]*Series'  && return 0
    return 1
}

# classify <torrent_name>  →  prints "tv" | "movie"
classify() {
    [ "$FORCE_TV"    = "1" ] && { printf 'tv';    return; }
    [ "$FORCE_MOVIE" = "1" ] && { printf 'movie'; return; }
    _is_tv "$1"               && { printf 'tv';    return; }
    printf 'movie'
}


# ───────────────────────────────────────────────────────────────────
# §5  TITLE SANITISATION
#
# Extracts a clean title from a raw torrent name while preserving
# canonical punctuation (dots inside abbreviations).
#
# Examples:
#   "Ms.X Series 1 (2026) [540p mp4] [NZ]" → "Ms.X"
#   "The.Good.Doctor.S10E01.720p"           → "The Good Doctor"
#   "S.W.A.T.S05E12"                        → "S.W.A.T"
#
# Algorithm
#   Step 1 — _cut_at_noise
#     Locate the first noise token (quality tag, year, season marker,
#     episode code) and return only the prefix to the left of it.
#     The prefix retains original dots exactly as typed.
#
#   Step 2 — _expand_separator_dots
#     A dot that sits between two tokens that are BOTH ≥ 2 characters
#     long is a word separator and is replaced with a space.
#     Single-character tokens (e.g. the individual letters in "Ms.X"
#     or "S.W.A.T") keep their dot.
# ───────────────────────────────────────────────────────────────────

_cut_at_noise() {
    printf '%s' "$1" \
        | sed 's/[[(].*//'                                               \
        | sed 's/[[:space:]]*[Ss][0-9][0-9]*[Ee][0-9][0-9]*.*//'        \
        | sed 's/[[:space:]]*[0-9][0-9]*x[0-9][0-9]*.*//'               \
        | sed 's/[[:space:]]*[Ss]eries[[:space:]_.+-]*[0-9].*//'         \
        | sed 's/[[:space:]]*[Ss]eason[[:space:]_.+-]*[0-9].*//'         \
        | sed 's/[[:space:]]*[12][0-9][0-9][0-9][^0-9].*//'             \
        | sed 's/[[:space:]]*$//'
}

# Note: split separator is "[.]" not "." — "." is a regex wildcard in awk
_expand_separator_dots() {
    printf '%s' "$1" | awk '{
        n = split($0, tok, "[.]")
        if (n == 1) { printf "%s", $0; next }
        out = tok[1]
        for (i = 2; i <= n; i++) {
            p = tok[i-1]; c = tok[i]
            gsub(/^ +| +$/, "", p)
            gsub(/^ +| +$/, "", c)
            sep = (length(p) >= 2 && length(c) >= 2) ? " " : "."
            out = out sep c
        }
        printf "%s", out
    }'
}

# sanitise_title <raw_name>  →  sets global CANONICAL_TITLE
sanitise_title() {
    _LOG_CTX="sanitise_title"
    _prefix=$(_cut_at_noise "$1")
    log_debug "Title prefix (raw) : [$_prefix]"
    CANONICAL_TITLE=$(_expand_separator_dots "$_prefix")
    log_info  "Canonical title    : [$CANONICAL_TITLE]"
}


# ───────────────────────────────────────────────────────────────────
# §6  METADATA EXTRACTION  (season, episode, year)
# ───────────────────────────────────────────────────────────────────

extract_season() {
    _n="$1"
    # "Series N" / "Season N" with any separator
    _v=$(printf '%s' "$_n" \
         | grep -oiE '(Series|Season)[[:space:]_.+-]*[0-9]+' \
         | grep -oE '[0-9]+' | head -1)
    [ -n "$_v" ] && { printf '%s' "$_v"; return; }
    # SxxExx
    _v=$(printf '%s' "$_n" \
         | grep -oiE '[Ss][0-9]+[Ee][0-9]+' \
         | sed 's/[Ss]\([0-9]*\)[Ee].*/\1/' | head -1)
    [ -n "$_v" ] && { printf '%s' "$_v"; return; }
    # NxNN
    _v=$(printf '%s' "$_n" \
         | grep -oE '[0-9]+x[0-9]+' | sed 's/x.*//' | head -1)
    [ -n "$_v" ] && { printf '%s' "$_v"; return; }
    printf ''
}

extract_episode() {
    _n="$1"
    # SxxExx
    _v=$(printf '%s' "$_n" \
         | grep -oiE '[Ss][0-9]+[Ee][0-9]+' \
         | sed 's/.*[Ee]\([0-9]*\)/\1/' | head -1)
    [ -n "$_v" ] && { printf '%s' "$_v"; return; }
    # NxNN
    _v=$(printf '%s' "$_n" \
         | grep -oE '[0-9]+x[0-9]+' | sed 's/.*x//' | head -1)
    [ -n "$_v" ] && { printf '%s' "$_v"; return; }
    printf ''
}

extract_year() {
    # Matches (YYYY) — parenthesised 4-digit year
    printf '%s' "$1" \
        | grep -oE '\([12][0-9]{3}\)' \
        | grep -oE '[0-9]+' \
        | head -1
}


# ───────────────────────────────────────────────────────────────────
# §7  TITLE VARIANTS
#
# Generates up to 5 normalised forms of a title so that a Sonarr or
# Radarr lookup succeeds despite punctuation differences in the name.
#
#   v1: as-is          "Ms.X"
#   v2: space → dash
#   v3: dots → dash 
#   v4: dots → spaces  "Ms X"
#   v5: no dots        "MsX"
#   v6: dot-space      "Ms. X"
#   v7: no apostrophes (handles "It's" etc.)
#
# A case-insensitive seen-file prevents the same normalised form being
# queried twice even when multiple variants collapse to the same string.
# ───────────────────────────────────────────────────────────────────

_build_variants() {
    _t="$1"
    printf '%s\n' "$_t"                                           # v1
    printf '%s\n' "$_t" | tr ' ' '-'                              # v2
    printf '%s\n' "$_t" | tr '.' '-'                              # v3
    printf '%s\n' "$_t" | tr '.' ' ' | sed 's/  */ /g; s/ *$//'   # v4
    printf '%s\n' "$_t" | tr -d '.'                               # v5
    printf '%s\n' "$_t" | sed 's/\.\([^ ]\)/. \1/g'               # v6
    printf '%s\n' "$_t" | tr -d "'"                               # v7
}


# ───────────────────────────────────────────────────────────────────
# §8  SONARR INTEGRATION
# ───────────────────────────────────────────────────────────────────

_sonarr_get() {
    # _sonarr_get <api_path>  →  stdout: response body
    wget -q -O - \
        --header="X-Api-Key: ${SONARR_API_KEY}" \
        --header="Accept: application/json" \
        "${SONARR_URL}/api/v3${1}" 2>/dev/null
}

# find_sonarr_series <title>
# Tries each title variant in turn; stops on first hit.
# Sets globals: SERIES_ID, SERIES_TITLE
# Returns: 0 = found  1 = not found
find_sonarr_series() {
    _LOG_CTX="find_sonarr_series"
    _var_f=$(_tmpfile "sv_var")
    _seen_f=$(_tmpfile "sv_seen")
    touch "$_seen_f"
    _build_variants "$1" > "$_var_f"

    while IFS= read -r _var; do
        [ -z "$_var" ] && continue

        _low=$(printf '%s' "$_var" | tr '[:upper:]' '[:lower:]')
        grep -qxF "$_low" "$_seen_f" 2>/dev/null && continue
        printf '%s\n' "$_low" >> "$_seen_f"

        log_debug "Sonarr lookup: [$_var]"
        _resp=$(_sonarr_get "/series/lookup?term=$(urlencode "$_var")") || continue
        [ -z "$_resp" ] || [ "$_resp" = "[]" ] && continue

        _first=$(json_split "$_resp" | head -1)
        _sid=$(json_num "id" "$_first")
        case "$_sid" in ''|*[!0-9]*|0) continue ;; esac

        SERIES_ID="$_sid"
        SERIES_TITLE=$(json_str "title" "$_first")
        log_info "Sonarr match: id=[$SERIES_ID] title=[$SERIES_TITLE] via=[$_var]"
        return 0
    done < "$_var_f"

    return 1
}

# lookup_episode <season_num> <episode_num>
# Requires SERIES_ID to already be set.
# Sets global: EPISODE_TITLE
# Returns: 0 = found  1 = not found
lookup_episode() {
    _LOG_CTX="lookup_episode"
    _sn="$1"; _en="$2"
    _ep_f=$(_tmpfile "ep_list")

    _resp=$(_sonarr_get "/episode?seriesId=${SERIES_ID}&seasonNumber=${_sn}") || return 1
    [ -z "$_resp" ] || [ "$_resp" = "[]" ] && return 1
    json_split "$_resp" > "$_ep_f"

    _want=$(strip_zeros "$_en")
    EPISODE_TITLE=""
    while IFS= read -r _ep; do
        [ -z "$_ep" ] && continue
        _got=$(strip_zeros "$(json_num "episodeNumber" "$_ep")")
        if [ "$_got" = "$_want" ]; then
            EPISODE_TITLE=$(json_str "title" "$_ep")
            log_info "Episode match: S$(pad2 "$_sn")E$(pad2 "$_en") — [$EPISODE_TITLE]"
            return 0
        fi
    done < "$_ep_f"

    return 1
}


# ───────────────────────────────────────────────────────────────────
# §9  RADARR INTEGRATION
# ───────────────────────────────────────────────────────────────────

_radarr_get() {
    # _radarr_get <api_path>  →  stdout: response body
    wget -q -O - \
        --header="X-Api-Key: ${RADARR_API_KEY}" \
        --header="Accept: application/json" \
        "${RADARR_URL}/api/v3${1}" 2>/dev/null
}

# find_radarr_movie <title> [year]
# Tries each title variant; appends year to the query when known
# (dramatically improves accuracy for common titles).
# If year is provided, prefers a result whose year field matches;
# falls back to the first result if none do.
# Sets globals: MOVIE_TITLE, MOVIE_YEAR
# Returns: 0 = found  1 = not found
find_radarr_movie() {
    _LOG_CTX="find_radarr_movie"
    _title="$1"; _year="${2:-}"
    _var_f=$(_tmpfile "rv_var")
    _seen_f=$(_tmpfile "rv_seen")
    _resp_f=$(_tmpfile "rv_resp")
    touch "$_seen_f"
    _build_variants "$_title" > "$_var_f"

    while IFS= read -r _var; do
        [ -z "$_var" ] && continue

        _low=$(printf '%s' "$_var" | tr '[:upper:]' '[:lower:]')
        grep -qxF "$_low" "$_seen_f" 2>/dev/null && continue
        printf '%s\n' "$_low" >> "$_seen_f"

        _query="$_var"
        [ -n "$_year" ] && _query="${_var} ${_year}"
        log_debug "Radarr lookup: [$_query]"
        _resp=$(_radarr_get "/movie/lookup?term=$(urlencode "$_query")") || continue
        [ -z "$_resp" ] || [ "$_resp" = "[]" ] && continue

        json_split "$_resp" > "$_resp_f"

        # Try to find a year-matching result first
        _obj=""
        if [ -n "$_year" ]; then
            while IFS= read -r _o; do
                [ -z "$_o" ] && continue
                [ "$(json_num "year" "$_o")" = "$_year" ] && { _obj="$_o"; break; }
            done < "$_resp_f"
        fi
        # Fall back to first result when no year match
        [ -z "$_obj" ] && _obj=$(head -1 "$_resp_f")
        [ -z "$_obj" ] && continue

        MOVIE_TITLE=$(json_str "title" "$_obj")
        MOVIE_YEAR=$(json_num "year"  "$_obj")
        log_info "Radarr match: title=[$MOVIE_TITLE] year=[$MOVIE_YEAR] via=[$_var]"
        return 0
    done < "$_var_f"

    return 1
}


# ───────────────────────────────────────────────────────────────────
# §10  FILE DISCOVERY
# ───────────────────────────────────────────────────────────────────

# find_video_files <path>  →  one absolute video-file path per line
find_video_files() {
    _p="$1"
    if [ -f "$_p" ]; then
        _ext="${_p##*.}"
        for _e in $VIDEO_EXTS; do
            [ "$_ext" = "$_e" ] && { printf '%s\n' "$_p"; return 0; }
        done
    elif [ -d "$_p" ]; then
        find "$_p" -type f | while IFS= read -r _f; do
            _ext="${_f##*.}"
            for _e in $VIDEO_EXTS; do
                [ "$_ext" = "$_e" ] && printf '%s\n' "$_f"
            done
        done
    fi
}


# ───────────────────────────────────────────────────────────────────
# §11  SYMLINK HELPERS
# ───────────────────────────────────────────────────────────────────

# _safe_dirname <str>  →  filesystem-safe directory name
_safe_dirname() {
    printf '%s' "$1" | tr '/' '_' | sed 's/  */ /g; s/ *$//; s/^ *//'
}

# _make_symlink <source_file> <dest_dir>
# Creates dest_dir if needed.  Refreshes existing symlinks.
# Returns: 0 = ok  1 = error
_make_symlink() {
    _LOG_CTX="_make_symlink"
    _src="$1"; _ddir="$2"
    _dst="${_ddir}/$(basename "$_src")"

    if [ "$DRY_RUN" = "1" ]; then
        log_info "[DRY_RUN] mkdir -p $_ddir"
        log_info "[DRY_RUN] ln -sf   $_src  →  $_dst"
        return 0
    fi

    mkdir -p "$_ddir" || { log_error "Cannot create dir: $_ddir"; return 1; }

    if [ -L "$_dst" ]; then
        log_warn "Refreshing existing symlink: $_dst"
        rm -f "$_dst"
    elif [ -e "$_dst" ]; then
        log_error "Path exists and is not a symlink — skipping: $_dst"
        return 1
    fi

    if ln -sf "$_src" "$_dst"; then
        log_info "Symlink OK: [$_dst]"
    else
        log_error "ln -sf failed: $_src → $_dst"
        return 1
    fi
}

# _link_files <video_list_file> <dest_dir>
# Iterates the list, tallies failures via a temp file (survives the
# while-read loop without leaking through a subshell).
# Returns: 0 = all ok  1 = one or more failed
_link_files() {
    _LOG_CTX="_link_files"
    _list="$1"; _dir="$2"
    _err_f=$(_tmpfile "link_errs")
    printf '0' > "$_err_f"

    while IFS= read -r _vf; do
        _make_symlink "$_vf" "$_dir" \
            || { _c=$(cat "$_err_f"); printf '%d' "$((_c + 1))" > "$_err_f"; }
    done < "$_list"

    _errs=$(cat "$_err_f")
    [ "$_errs" -gt 0 ] && { log_error "$_errs symlink(s) failed"; return 1; }
    return 0
}


# ───────────────────────────────────────────────────────────────────
# §12  HIGH-LEVEL HANDLERS
#
# Each handler owns its full workflow end-to-end:
#   extract metadata → resolve in *arr → find files → create symlinks
# ───────────────────────────────────────────────────────────────────

handle_tv() {
    _LOG_CTX="handle_tv"
    log_info "--- TV handler ---"

    # 1. Derive a clean title and season/episode numbers
    sanitise_title "$TORRENT_NAME"
    SEASON_NUM=$(extract_season  "$TORRENT_NAME")
    EPISODE_NUM=$(extract_episode "$TORRENT_NAME")
    log_info "Season : [${SEASON_NUM:-<none>}]"
    log_info "Episode: [${EPISODE_NUM:-<none>}]"

    # 2. Resolve the series in Sonarr (fatal if not found)
    [ -z "$SONARR_API_KEY" ] && die "SONARR_API_KEY is required for TV releases" 1
    find_sonarr_series "$CANONICAL_TITLE" \
        || die "No Sonarr series found for: [$CANONICAL_TITLE]" 20

    # 3. Resolve the episode title in Sonarr (informational; non-fatal)
    if [ -n "$SEASON_NUM" ] && [ -n "$EPISODE_NUM" ]; then
        lookup_episode "$SEASON_NUM" "$EPISODE_NUM" \
            || log_warn "S$(pad2 "$SEASON_NUM")E$(pad2 "$EPISODE_NUM") not found in Sonarr (may not have aired yet)"
    elif [ -n "$SEASON_NUM" ]; then
        log_info "Season pack — no individual episode number"
    else
        log_warn "Season not detected — symlink will land in Season 00"
    fi

    # 4. Find every video file inside the torrent path
    _vf_list=$(_tmpfile "tv_videos")
    find_video_files "$TORRENT_PATH" > "$_vf_list"
    [ -s "$_vf_list" ] || die "No video files found in: $TORRENT_PATH" 30
    log_info "Video files:"; while IFS= read -r _f; do log_info "  $_f"; done < "$_vf_list"

    # 5. Build the target directory and create symlinks
    #    Layout: <TV_ROOT>/<Series Title>/Season NN/
    _dest="${JELLYFIN_TV_ROOT}/$(_safe_dirname "$SERIES_TITLE")/Season $(pad2 "${SEASON_NUM:-0}")"
    log_info "Target dir : [$_dest]"
    _link_files "$_vf_list" "$_dest" || exit 30
}

handle_movie() {
    _LOG_CTX="handle_movie"
    log_info "--- Movie / one-off handler ---"

    # 1. Derive a clean title and year from the torrent name
    sanitise_title "$TORRENT_NAME"
    MOVIE_YEAR=$(extract_year "$TORRENT_NAME")
    MOVIE_TITLE="$CANONICAL_TITLE"           # Radarr lookup may override both
    log_info "Extracted year : [${MOVIE_YEAR:-<unknown>}]"

    # 2. Resolve in Radarr (optional — skip gracefully if not configured)
    if [ -n "$RADARR_API_KEY" ]; then
        find_radarr_movie "$CANONICAL_TITLE" "$MOVIE_YEAR" \
            || log_warn "Radarr found no match — falling back to extracted title/year"
    else
        log_warn "RADARR_API_KEY not set — skipping Radarr lookup"
    fi

    # 3. Find every video file inside the torrent path
    _vf_list=$(_tmpfile "mv_videos")
    find_video_files "$TORRENT_PATH" > "$_vf_list"
    [ -s "$_vf_list" ] || die "No video files found in: $TORRENT_PATH" 30
    log_info "Video files:"; while IFS= read -r _f; do log_info "  $_f"; done < "$_vf_list"

    # 4. Build the target directory and create symlinks
    #    Layout: <MOVIES_ROOT>/<Title> (YEAR)/
    #    Jellyfin requires the year in the folder name for correct matching.
    _movie_dir="${MOVIE_TITLE}${MOVIE_YEAR:+ (${MOVIE_YEAR})}"
    _dest="${JELLYFIN_MOVIES_ROOT}/$(_safe_dirname "$_movie_dir")"
    log_info "Target dir : [$_dest]"
    _link_files "$_vf_list" "$_dest" || exit 30
}


# ═══════════════════════════════════════════════════════════════════
#  MAINLINE
# ═══════════════════════════════════════════════════════════════════

[ -z "$TR_TORRENT_NAME" ] && die "TR_TORRENT_NAME is not set (run via Transmission?)" 1
[ -z "$TR_TORRENT_DIR"  ] && die "TR_TORRENT_DIR is not set (run via Transmission?)" 1

TORRENT_NAME="$TR_TORRENT_NAME"
TORRENT_PATH="${TR_TORRENT_DIR}/${TR_TORRENT_NAME}"

log_info "========================================================"
log_info "=== postprocess start"
log_info "Torrent name : [$TORRENT_NAME]"
log_info "Torrent path : [$TORRENT_PATH]"

RELEASE_TYPE=$(classify "$TORRENT_NAME")
log_info "Release type : [$RELEASE_TYPE]"

case "$RELEASE_TYPE" in
    tv)    handle_tv    ;;
    movie) handle_movie ;;
    *)     die "Unrecognised release type: [$RELEASE_TYPE]" 10 ;;
esac

log_info "=== postprocess complete (OK)"
exit 0
