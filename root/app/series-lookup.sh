#!/bin/sh
# shellcheck shell=ash
# ─────────────────────────────────────────────────────────────────────────────
# series-lookup.sh - Standalone TV Series metadata lookup emulator
#
# Emulates Sonarr's /api/v3/series/lookup functionality without running Sonarr.
# Queries public TV metadata providers:
#   1. Sonarr SkyHook (https://skyhook.sonarr.tv) - Primary (TVDB + TMDB + status)
#   2. TVMaze API (https://api.tvmaze.com)       - Fallback (TVDB + premier year)
#
# Usage:
#   series-lookup.sh [--format=pipe|json] <title> [min_season]
#   series-lookup.sh episode <title> <season_num> <episode_num>
#
# Outputs:
#   --format=pipe (default):
#     <Title>|<tvdbId>|<year>|<tmdbId>|<cleanTitle>
#
#   --format=json:
#     [{"title":"...","cleanTitle":"...","year":...,"tvdbId":...,"tmdbId":...,"status":"...","seasonCount":...}]
#
# Exit codes:
#   0 = Found / success
#   1 = Not found
#   2 = Invalid arguments
# ─────────────────────────────────────────────────────────────────────────────

set -u

CACHE_DIR="${SERIES_CACHE_DIR:-/tmp/series_lookup_cache}"
# shellcheck disable=SC2034
CACHE_TTL="${SERIES_CACHE_TTL:-86400}" # 24 hours in seconds
HTTP_TIMEOUT="${SERIES_HTTP_TIMEOUT:-10}"

_http_get() {
    local _url="$1"
    local _response

    if command -v wget >/dev/null 2>&1; then
        if _response=$(wget -qO- --timeout="$HTTP_TIMEOUT" "$_url" 2>/dev/null); then
            printf '%s' "$_response"
            return 0
        fi
    fi

    if command -v curl >/dev/null 2>&1; then
        if _response=$(curl -fsSL --max-time "$HTTP_TIMEOUT" "$_url" 2>/dev/null); then
            printf '%s' "$_response"
            return 0
        fi
    fi

    return 1
}

urlencode() {
    printf '%s' "$1" | awk '
    BEGIN {
        for (i = 0; i <= 255; i++) {
            ord[sprintf("%c", i)] = i
        }
    }
    {
        len = length($0)
        for (i = 1; i <= len; i++) {
            c = substr($0, i, 1)
            if (c ~ /[a-zA-Z0-9._~-]/) {
                printf "%s", c
            } else {
                printf "%%%02X", ord[c]
            }
        }
    }'
}

# Normalizes titles for comparison: lowercase, strip punctuation, "the", "and"
universal_clean() {
    printf '%s' "$1" \
        | tr '[:upper:]' '[:lower:]' \
        | sed 's/[.:\-_]/ /g' \
        | sed -E 's/[[:space:]]+the[[:space:]]+/ /g' \
        | sed -E 's/[[:space:]]+and[[:space:]]+/ /g' \
        | sed 's/[^a-z0-9]//g'
}

# Generates search query variants to maximize match hit rate
build_variants() {
    local _t="$1"
    printf '%s\n' "$_t"
    printf '%s\n' "$_t" | tr '.' ' ' | sed 's/  */ /g; s/ *$//'
    printf '%s\n' "$_t" | tr -d '.'
    printf '%s\n' "$_t" | sed 's/\.\([^ ]\)/. \1/g'
    printf '%s\n' "$_t" | tr -d "'"
}

unique_variants() {
    build_variants "$1" | awk '!seen[tolower($0)]++'
}

_cache_get() {
    local _key="$1"
    local _file="${CACHE_DIR}/${_key}"
    if [ -f "$_file" ] && [ -s "$_file" ]; then
        printf '%s' "$_file"
        return 0
    fi
    return 1
}

_cache_put() {
    local _key="$1"
    local _content="$2"
    mkdir -p "$CACHE_DIR" 2>/dev/null || true
    printf '%s' "$_content" > "${CACHE_DIR}/${_key}" 2>/dev/null || true
}

# Parse SkyHook JSON array
parse_skyhook() {
    local _search="$1"
    local _min_seasons="${2:-1}"
    local _json="$3"
    local _fmt="${4:-pipe}"

    printf '%s\n' "$_json" | \
      sed 's/,[[:space:]]*"/,\n"/g; s/{[[:space:]]*"/{\n"/g' | \
      awk -F'"' -v search="$_search" -v min_seasons="$_min_seasons" -v fmt="$_fmt" '
      function uclean(str) {
          s = tolower(str)
          gsub(/[.:\-_]/, " ", s)
          gsub(/[[:space:]]+the[[:space:]]+/, " ", s)
          gsub(/[[:space:]]+and[[:space:]]+/, " ", s)
          gsub(/[^a-z0-9]/, "", s)
          return s
      }

      function evaluate_show() {
          if (_tvdbId == "" || _title == "") return
          _cleanTitle = uclean(_title)
          _cleanTitle_cmp = _cleanTitle
          sub(/[0-9][0-9][0-9][0-9]$/, "", _cleanTitle_cmp)

          if ((_cleanTitle_cmp == search || _cleanTitle == search) && _seasonCount >= min_seasons) {
              _status_low = tolower(_status)
              _score = (_status_low == "continuing" || _status_low == "upcoming") ? 2 : 1
              if (_score > _best_score) {
                  _best_score = _score
                  _best_title = _title
                  _best_tvdb = _tvdbId
                  _best_year = _year
                  _best_tmdb = _tmdbId
                  _best_clean = _cleanTitle
                  _best_status = _status_low
                  _best_seasons = _seasonCount
              }
          }
      }

      BEGIN {
          _best_score = 0
          _tvdbId = ""
          _title = ""
          _year = ""
          _tmdbId = ""
          _status = ""
          _seasonCount = 0
      }

      /"tvdbId"[[:space:]]*:/ {
          evaluate_show()
          match($0, /[0-9]+/)
          _tvdbId = substr($0, RSTART, RLENGTH)
          _title = ""
          _year = ""
          _tmdbId = ""
          _status = ""
          _seasonCount = 0
      }

      /"title"[[:space:]]*:/ {
          if (_title == "") _title = $4
      }

      /"firstAired"[[:space:]]*:/ {
          if ($4 ~ /^[0-9]{4}/) {
              _year = substr($4, 1, 4)
          }
      }

      /"status"[[:space:]]*:/ {
          _status = $4
      }

      /"tmdbId"[[:space:]]*:/ {
          match($0, /[0-9]+/)
          _tmdbId = substr($0, RSTART, RLENGTH)
      }

      /"seasonNumber"[[:space:]]*:/ {
          match($0, /[0-9]+/)
          sn = substr($0, RSTART, RLENGTH) + 0
          if (sn > 0) _seasonCount++
      }

      END {
          evaluate_show()
          if (_best_score > 0) {
              if (fmt == "json") {
                  printf "[{\"title\":\"%s\",\"cleanTitle\":\"%s\",\"year\":%s,\"tvdbId\":%s,\"tmdbId\":%s,\"status\":\"%s\",\"seasonCount\":%d}]\n",
                      _best_title, _best_clean, (_best_year != "" ? _best_year : "null"),
                      (_best_tvdb != "" ? _best_tvdb : "0"), (_best_tmdb != "" ? _best_tmdb : "0"),
                      _best_status, _best_seasons
              } else {
                  printf "%s|%s|%s|%s|%s\n", _best_title, _best_tvdb, _best_year, _best_tmdb, _best_clean
              }
          }
      }
      '
}

# Parse TVMaze JSON array (fallback provider)
parse_tvmaze() {
    local _search="$1"
    local _json="$2"
    local _fmt="${3:-pipe}"

    printf '%s\n' "$_json" | \
      sed 's/,[[:space:]]*"/,\n"/g; s/{[[:space:]]*"/{\n"/g' | \
      awk -F'"' -v search="$_search" -v fmt="$_fmt" '
      function uclean(str) {
          s = tolower(str)
          gsub(/[.:\-_]/, " ", s)
          gsub(/[[:space:]]+the[[:space:]]+/, " ", s)
          gsub(/[[:space:]]+and[[:space:]]+/, " ", s)
          gsub(/[^a-z0-9]/, "", s)
          return s
      }

      function evaluate_show() {
          if (_name == "") return
          _cleanTitle = uclean(_name)
          _cleanTitle_cmp = _cleanTitle
          sub(/[0-9][0-9][0-9][0-9]$/, "", _cleanTitle_cmp)

          if (_cleanTitle_cmp == search || _cleanTitle == search) {
              _status_low = tolower(_status)
              _score = (_status_low == "running" || _status_low == "in development") ? 2 : 1
              if (_score > _best_score) {
                  _best_score = _score
                  _best_title = _name
                  _best_tvdb = _tvdbId
                  _best_year = _year
                  _best_clean = _cleanTitle
                  _best_status = _status_low
              }
          }
      }

      BEGIN {
          _best_score = 0
          _name = ""
          _year = ""
          _tvdbId = ""
          _status = ""
      }

      /"score"[[:space:]]*:/ {
          evaluate_show()
          _name = ""
          _year = ""
          _tvdbId = ""
          _status = ""
      }

      /"name"[[:space:]]*:/ {
          if (_name == "") _name = $4
      }

      /"premiered"[[:space:]]*:/ {
          if ($4 ~ /^[0-9]{4}/) {
              _year = substr($4, 1, 4)
          }
      }

      /"status"[[:space:]]*:/ {
          _status = $4
      }

      /"thetvdb"[[:space:]]*:/ {
          match($0, /[0-9]+/)
          if (RSTART > 0) {
              _tvdbId = substr($0, RSTART, RLENGTH)
          }
      }

      END {
          evaluate_show()
          if (_best_score > 0) {
              if (fmt == "json") {
                  printf "[{\"title\":\"%s\",\"cleanTitle\":\"%s\",\"year\":%s,\"tvdbId\":%s,\"tmdbId\":0,\"status\":\"%s\",\"seasonCount\":1}]\n",
                      _best_title, _best_clean, (_best_year != "" ? _best_year : "null"),
                      (_best_tvdb != "" ? _best_tvdb : "0"), _best_status
              } else {
                  printf "%s|%s|%s||%s\n", _best_title, _best_tvdb, _best_year, _best_clean
              }
          }
      }
      '
}

lookup_series() {
    local _input="$1"
    local _min_season="${2:-1}"
    local _fmt="${3:-pipe}"
    local _clean_search
    _clean_search=$(universal_clean "$_input")

    # 1. Try Sonarr SkyHook with all title variants
    local _v _enc _resp _key _match=""
    while IFS= read -r _v; do
        [ -z "$_v" ] && continue
        _enc=$(urlencode "$_v")
        _key="skyhook_$(printf '%s' "$_v" | tr -cd 'a-zA-Z0-9_-').json"

        if _cfile=$(_cache_get "$_key"); then
            _resp=$(cat "$_cfile")
        else
            _resp=$(_http_get "https://skyhook.sonarr.tv/v1/tvdb/search/en/?term=${_enc}")
            [ -n "$_resp" ] && [ "$_resp" != "[]" ] && _cache_put "$_key" "$_resp"
        fi

        [ -z "$_resp" ] || [ "$_resp" = "[]" ] && continue

        _match=$(parse_skyhook "$_clean_search" "$_min_season" "$_resp" "$_fmt")
        if [ -n "$_match" ]; then
            printf '%s\n' "$_match"
            return 0
        fi
    done <<EOF
$(unique_variants "$_input")
EOF

    # 2. Fallback: Try TVMaze API
    while IFS= read -r _v; do
        [ -z "$_v" ] && continue
        _enc=$(urlencode "$_v")
        _key="tvmaze_$(printf '%s' "$_v" | tr -cd 'a-zA-Z0-9_-').json"

        if _cfile=$(_cache_get "$_key"); then
            _resp=$(cat "$_cfile")
        else
            _resp=$(_http_get "https://api.tvmaze.com/search/shows?q=${_enc}")
            [ -n "$_resp" ] && [ "$_resp" != "[]" ] && _cache_put "$_key" "$_resp"
        fi

        [ -z "$_resp" ] || [ "$_resp" = "[]" ] && continue

        _match=$(parse_tvmaze "$_clean_search" "$_resp" "$_fmt")
        if [ -n "$_match" ]; then
            printf '%s\n' "$_match"
            return 0
        fi
    done <<EOF
$(unique_variants "$_input")
EOF

    return 1
}

# Optional episode lookup using TVMaze
lookup_episode() {
    local _title="$1"
    local _season="$2"
    local _episode="$3"

    local _enc
    _enc=$(urlencode "$_title")
    local _show_json
    _show_json=$(_http_get "https://api.tvmaze.com/singlesearch/shows?q=${_enc}")
    [ -z "$_show_json" ] && return 1

    local _show_id
    _show_id=$(printf '%s' "$_show_json" | sed 's/,[[:space:]]*"/,\n"/g' | awk -F'"' '/"id"[[:space:]]*:/ { match($0, /[0-9]+/); print substr($0, RSTART, RLENGTH); exit }')
    [ -z "$_show_id" ] && return 1

    local _ep_json
    _ep_json=$(_http_get "https://api.tvmaze.com/shows/${_show_id}/episodebynumber?season=${_season}&number=${_episode}")
    [ -z "$_ep_json" ] && return 1

    local _ep_name
    _ep_name=$(printf '%s' "$_ep_json" | sed 's/,[[:space:]]*"/,\n"/g' | awk -F'"' '/"name"[[:space:]]*:/ { print $4; exit }')
    [ -n "$_ep_name" ] && printf '%s\n' "$_ep_name" && return 0

    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Entry Point
# ─────────────────────────────────────────────────────────────────────────────

FORMAT="pipe"
while [ $# -gt 0 ]; do
    case "$1" in
        --format=pipe)
            FORMAT="pipe"; shift ;;
        --format=json)
            FORMAT="json"; shift ;;
        episode)
            shift
            if [ $# -lt 3 ]; then
                echo "Usage: $0 episode <title> <season> <episode>" >&2
                exit 2
            fi
            lookup_episode "$1" "$2" "$3"
            exit $?
            ;;
        --help|-h)
            echo "Usage: $0 [--format=pipe|json] <title> [min_season]"
            echo "       $0 episode <title> <season> <episode>"
            exit 0
            ;;
        *)
            break ;;
    esac
done

if [ $# -lt 1 ]; then
    echo "Usage: $0 [--format=pipe|json] <title> [min_season]" >&2
    exit 2
fi

TITLE="$1"
SEASON="${2:-1}"

lookup_series "$TITLE" "$SEASON" "$FORMAT"
exit $?
