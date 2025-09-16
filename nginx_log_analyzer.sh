#!/usr/bin/env bash
set -euo pipefail

# nginx_log_analyzer.sh (merged, robust + friendly)
# Shows Top-N IPs, paths, status codes, and user agents from an Nginx combined log.
#
# Usage:
#   ./nginx_log_analyzer.sh [LOGFILE|-] [TOP_N]
#   zcat access.log.gz | ./nginx_log_analyzer.sh - 10
#
# Notes:
# - LOGFILE: a path, a .gz file, or "-" to read from stdin
# - Default TOP_N = 5
# - Assumes Nginx "combined" format (request/referrer/UA in quotes)

show_usage() {
  cat <<EOF
Usage: $0 [LOGFILE|-] [TOP_N]

Examples:
  $0 /var/log/nginx/access.log
  $0 /var/log/nginx/access.log 10
  zcat /var/log/nginx/access.log.gz | $0 - 10

Notes:
  - LOGFILE may be a regular file, a .gz file, or "-" to read from stdin
  - Default TOP_N = 5
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  show_usage
  exit 0
fi

if [[ $# -lt 1 ]]; then
  echo "Error: missing LOGFILE argument." >&2
  show_usage
  exit 1
fi

LOGFILE="$1"
TOPN="${2:-5}"

# Validate TOPN is a positive integer
if ! [[ "$TOPN" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: TOP_N must be a positive integer. Got: $TOPN" >&2
  exit 1
fi

# Choose input source
read_input() {
  if [[ "$LOGFILE" == "-" ]]; then
    cat
  elif [[ "$LOGFILE" =~ \.gz$ ]]; then
    if [[ ! -r "$LOGFILE" ]]; then
      echo "Error: cannot read $LOGFILE" >&2
      exit 1
    fi
    zcat -- "$LOGFILE"
  else
    if [[ ! -r "$LOGFILE" ]]; then
      echo "Error: cannot read $LOGFILE" >&2
      exit 1
    fi
    cat -- "$LOGFILE"
  fi
}

# Normalize each line into a TSV: IP \t PATH \t STATUS \t USER_AGENT
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

# Quote-aware parsing:
# - Split on double quotes (FS="\"")
#   $2 = request line "METHOD PATH HTTP/x.y"
#   $3 = trailing part after request (starts with space STATUS space SIZE ...)
#   $6 = user agent (if present)
# - IP is the first token before the first quote (from $1 split by space)
read_input | awk '
BEGIN { FS="\""; OFS="\t" }
{
  # First part (before first quote) contains IP as the first space-delimited token
  split($1, pre, " ")
  ip = (length(pre) ? pre[1] : "-")

  req = (NF>=2 ? $2 : "")
  ua  = (NF>=6 && $6 != "" ? $6 : "-")

  # Extract PATH from request: "METHOD PATH HTTP/x.y"
  split(req, r, " ")
  path = (length(r) >= 2 ? r[2] : "-")

  # STATUS = first non-empty token in the segment right after the request
  status = "-"
  split($3, post, " ")
  for (i=1; i<=length(post); i++) { if (post[i] != "") { status = post[i]; break } }

  print ip, path, status, ua
}
' > "$TMP"

# Faster, deterministic sort
export LC_ALL=C

topN () {
  local col="$1" title="$2" suffix="$3"
  echo -e "\n${title}"
  cut -f"${col}" "$TMP" \
    | awk 'NF' \
    | sort \
    | uniq -c \
    | sort -nr \
    | head -n "${TOPN}" \
    | awk -v suf="${suffix}" '{count=$1; $1=""; sub(/^ +/,""); printf "%s - %d %s\n", $0, count, suf}'
}

topN 1 "Top ${TOPN} IP addresses with the most requests:" "requests"
topN 2 "Top ${TOPN} most requested paths:" "requests"
topN 3 "Top ${TOPN} response status codes:" "requests"
topN 4 "Top ${TOPN} user agents:" "requests"

