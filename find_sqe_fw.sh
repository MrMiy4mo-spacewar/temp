#!/usr/bin/env bash
set -euo pipefail

BASE="https://dumps.tadiphone.dev/api/v4"
GROUP="dumps"
CONCURRENCY=30
OUTPUT="sqe_fw_files.csv"
HTTP_LOG="http_responses.csv"
TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

ERRORS_LOG="http_errors.csv"

echo "repo,file_path,url" > "$OUTPUT"
echo "stage,project_id,namespace,url,http_code" > "$HTTP_LOG"
echo "stage,project_id,namespace,url,http_code" > "$ERRORS_LOG"

HTTP_LOG_DIR="$TMPDIR_ROOT/http_logs"
mkdir -p "$HTTP_LOG_DIR"

# ── Helper: curl with response code capture ──────────────────────────────────
# Usage: curl_with_code <log_file> <stage> <proj_id> <ns> <url>
# Prints response body to stdout; appends HTTP code to log_file
curl_with_code() {
  local log_file="$1"
  local stage="$2"
  local proj_id="$3"
  local ns="$4"
  local url="$5"

  local tmpbody
  tmpbody=$(mktemp)

  local http_code
  http_code=$(curl -s -o "$tmpbody" -w "%{http_code}" "$url" || echo "000")

  echo "\"${stage}\",\"${proj_id}\",\"${ns}\",\"${url}\",\"${http_code}\"" >> "$log_file"

  # Print anything that isn't 200 immediately to stderr
  if [[ "$http_code" != "200" ]]; then
    echo "[WARN] HTTP ${http_code} — stage=${stage} ns=${ns} url=${url}" >&2
    echo "\"${stage}\",\"${proj_id}\",\"${ns}\",\"${url}\",\"${http_code}\"" >> "${HTTP_LOG_DIR}/errors_${proj_id:-main}.csv"
  fi

  cat "$tmpbody"
  rm -f "$tmpbody"
}

# ── 1. Fetch all projects ────────────────────────────────────────────────────
echo "[*] Fetching project list..."
PROJECT_FILE="$TMPDIR_ROOT/projects.txt"
MAIN_HTTP_LOG="$HTTP_LOG_DIR/main.csv"

page=1
total=0
while true; do
  url="${BASE}/groups/${GROUP}/projects?per_page=100&page=${page}&include_subgroups=true&simple=true"
  response=$(curl_with_code "$MAIN_HTTP_LOG" "project_list" "" "${GROUP}" "$url" || true)

  [[ -z "$response" || "$response" == "[]" ]] && break

  echo "$response" | jq -r '.[] | [.id, .path_with_namespace, .web_url, (.default_branch // "main")] | @tsv' \
    >> "$PROJECT_FILE"

  count=$(echo "$response" | jq 'length')
  total=$((total + count))
  echo "    page $page — $total projects so far"

  [[ "$count" -lt 100 ]] && break
  page=$((page + 1))
done

echo "[*] Total projects: $total"
[[ $total -eq 0 ]] && { echo "[!] No projects found. Exiting."; exit 1; }

# ── 2. Search each repo's tree ───────────────────────────────────────────────
RESULTS_DIR="$TMPDIR_ROOT/results"
mkdir -p "$RESULTS_DIR"

search_project() {
  local id="$1"
  local ns="$2"
  local web_url="$3"
  local ref="$4"
  local out="$RESULTS_DIR/${id}.csv"
  local http_log="$HTTP_LOG_DIR/${id}.csv"

  local page=1
  while true; do
    local url="${BASE}/projects/${id}/repository/tree?recursive=true&per_page=100&page=${page}&ref=${ref}"
    local resp
    resp=$(curl_with_code "$http_log" "tree" "$id" "$ns" "$url" 2>/dev/null || true)

    [[ -z "$resp" || "$resp" == "[]" || "$resp" == "null" ]] && break

    local matches
    matches=$(echo "$resp" | jq -r \
      '.[] | select(.type == "blob" and (.path | endswith("sqe.fw"))) | .path' \
      2>/dev/null || true)

    if [[ -n "$matches" ]]; then
      while IFS= read -r filepath; do
        local file_url="${web_url}/-/blob/${ref}/${filepath}"
        echo "\"${ns}\",\"${filepath}\",\"${file_url}\"" >> "$out"
        echo "    [HIT] ${ns} → ${filepath}"
      done <<< "$matches"
    fi

    local count
    count=$(echo "$resp" | jq 'length' 2>/dev/null || echo 0)
    [[ "$count" -lt 100 ]] && break
    page=$((page + 1))
  done
}

export -f search_project curl_with_code
export BASE RESULTS_DIR HTTP_LOG_DIR ERRORS_LOG

echo "[*] Scanning trees (concurrency: $CONCURRENCY)..."

if command -v parallel &>/dev/null; then
  parallel -j "$CONCURRENCY" --line-buffer --colsep '\t' \
    'search_project {1} {2} {3} {4}' \
    :::: "$PROJECT_FILE"
else
  xargs -P "$CONCURRENCY" -I{} bash -c \
    'IFS=$'"'"'\t'"'"' read -r id ns url ref <<< "{}"; search_project "$id" "$ns" "$url" "$ref"' \
    < "$PROJECT_FILE"
fi

# ── 3. Merge results ─────────────────────────────────────────────────────────
echo "[*] Merging results..."
find "$RESULTS_DIR" -name "*.csv" -exec cat {} \; >> "$OUTPUT"

echo "[*] Merging HTTP logs..."
find "$HTTP_LOG_DIR" -name "*.csv" ! -name "errors_*.csv" -exec cat {} \; >> "$HTTP_LOG"

echo "[*] Merging error logs..."
find "$HTTP_LOG_DIR" -name "errors_*.csv" -exec cat {} \; >> "$ERRORS_LOG"

# ── 4. Summary ───────────────────────────────────────────────────────────────
found=$(( $(wc -l < "$OUTPUT") - 1 ))
total_requests=$(( $(wc -l < "$HTTP_LOG") - 1 ))
total_errors=$(( $(wc -l < "$ERRORS_LOG") - 1 ))

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Done. Found $found *sqe.fw file(s)"
echo " Output:     $OUTPUT"
echo " HTTP log:   $HTTP_LOG ($total_requests requests)"
echo " Errors log: $ERRORS_LOG ($total_errors non-200 responses)"
echo ""
echo " HTTP response code breakdown:"
tail -n +2 "$HTTP_LOG" | cut -d',' -f5 | tr -d '"' | sort | uniq -c | sort -rn | \
  while read -r cnt code; do
    echo "   HTTP $code : $cnt requests"
  done
if [[ $total_errors -gt 0 ]]; then
  echo ""
  echo " Non-200 requests:"
  tail -n +2 "$ERRORS_LOG" | while IFS=',' read -r stage proj ns url code; do
    echo "   [HTTP $(echo $code | tr -d '\"')] $(echo $ns | tr -d '\"') — $(echo $url | tr -d '\"')"
  done
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
