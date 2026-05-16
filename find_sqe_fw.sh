#!/usr/bin/env bash
set -euo pipefail

BASE="https://dumps.tadiphone.dev/api/v4"
GROUP="dumps"
CONCURRENCY=10
OUTPUT="sqe_fw_files.csv"
TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

echo "repo,file_path,url" > "$OUTPUT"

# ── 1. Fetch all projects ────────────────────────────────────────────────────
echo "[*] Fetching project list..."
PROJECT_FILE="$TMPDIR_ROOT/projects.txt"   # id|path_with_namespace|web_url|default_branch

page=1
total=0
while true; do
  response=$(curl -sf \
    "${BASE}/groups/${GROUP}/projects?per_page=100&page=${page}&include_subgroups=true&simple=true" \
    || true)

  [[ -z "$response" || "$response" == "[]" ]] && break

  # parse with jq: emit one line per project
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

  local page=1
  while true; do
    local resp
    resp=$(curl -sf \
      "${BASE}/projects/${id}/repository/tree?recursive=true&per_page=100&page=${page}&ref=${ref}" \
      2>/dev/null || true)

    [[ -z "$resp" || "$resp" == "[]" || "$resp" == "null" ]] && break

    # filter blobs ending in .sqe.fw
    local matches
    matches=$(echo "$resp" | jq -r \
      '.[] | select(.type == "blob" and (.path | endswith(".sqe.fw"))) | .path' \
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

export -f search_project
export BASE RESULTS_DIR

echo "[*] Scanning trees (concurrency: $CONCURRENCY)..."
scanned=0
total_lines=$(wc -l < "$PROJECT_FILE")

# Use GNU parallel if available, otherwise xargs
if command -v parallel &>/dev/null; then
  parallel -j "$CONCURRENCY" --colsep '\t' \
    'search_project {1} {2} {3} {4}' \
    :::: "$PROJECT_FILE"
else
  # xargs fallback: wrap in a subshell so export -f works
  xargs -P "$CONCURRENCY" -I{} bash -c \
    'IFS=$'"'"'\t'"'"' read -r id ns url ref <<< "{}"; search_project "$id" "$ns" "$url" "$ref"' \
    < "$PROJECT_FILE"
fi

# ── 3. Merge results ─────────────────────────────────────────────────────────
echo "[*] Merging results..."
find "$RESULTS_DIR" -name "*.csv" -exec cat {} \; >> "$OUTPUT"

found=$(( $(wc -l < "$OUTPUT") - 1 ))
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Done. Found $found *.sqe.fw file(s)"
echo " Output: $OUTPUT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
