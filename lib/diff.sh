#!/usr/bin/env bash
# lib/diff.sh
#
# Diff and comparison functions for Hetzner Deployer Agent update mode
# Handles detection comparison, change analysis, and conflict identification

set -euo pipefail

# Source manifest functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/manifest.sh"

# Compare two detection snapshots and return changes
# Args: $1 = old detection JSON path, $2 = new detection JSON path
# Returns: JSON with changes
compare_detections() {
  local old_detection="$1"
  local new_detection="$2"

  if [[ ! -f "$old_detection" ]]; then
    echo '{"status": "no_previous", "changes": []}'
    return
  fi

  if [[ ! -f "$new_detection" ]]; then
    echo '{"status": "no_current", "changes": []}'
    return
  fi

  if command -v jq >/dev/null 2>&1; then
    # Use jq for comparison
    local old_backend new_backend old_frontend new_frontend old_db new_db

    old_backend="$(jq -r '.backend // "none"' "$old_detection" 2>/dev/null || echo "none")"
    new_backend="$(jq -r '.backend // "none"' "$new_detection" 2>/dev/null || echo "none")"
    old_frontend="$(jq -r '.frontend // "none"' "$old_detection" 2>/dev/null || echo "none")"
    new_frontend="$(jq -r '.frontend // "none"' "$new_detection" 2>/dev/null || echo "none")"
    old_db="$(jq -r '.database // "none"' "$old_detection" 2>/dev/null || echo "none")"
    new_db="$(jq -r '.database // "none"' "$new_detection" 2>/dev/null || echo "none")"

    local changes=()
    local has_changes="false"

    if [[ "$old_backend" != "$new_backend" ]]; then
      changes+=("backend: ${old_backend} -> ${new_backend}")
      has_changes="true"
    fi

    if [[ "$old_frontend" != "$new_frontend" ]]; then
      changes+=("frontend: ${old_frontend} -> ${new_frontend}")
      has_changes="true"
    fi

    if [[ "$old_db" != "$new_db" ]]; then
      changes+=("database: ${old_db} -> ${new_db}")
      has_changes="true"
    fi

    if [[ "$has_changes" == "true" ]]; then
      echo '{"status": "changed", "changes": ["'"$(IFS='","'; echo "${changes[*]}")"'"]}'
    else
      echo '{"status": "unchanged", "changes": []}'
    fi
  else
    # Python fallback
    python3 -c "
import json

with open('$old_detection') as f:
    old = json.load(f)
with open('$new_detection') as f:
    new = json.load(f)

changes = []
for key in ['backend', 'frontend', 'database', 'migrations']:
    old_val = old.get(key, 'none')
    new_val = new.get(key, 'none')
    if old_val != new_val:
        changes.append(f'{key}: {old_val} -> {new_val}')

result = {
    'status': 'changed' if changes else 'unchanged',
    'changes': changes
}
print(json.dumps(result))
"
  fi
}

# Analyze bundle for update requirements
# Args: $1 = bundle directory, $2 = app repo path, $3 = prompt file path
# Returns: JSON analysis result
analyze_update_requirements() {
  local bundle_dir="$1"
  local app_repo="$2"
  local prompt_file="$3"

  local manifest_dir
  manifest_dir="$(get_manifest_dir "$bundle_dir")"

  # Check prompt changes
  local prompt_changed="false"
  if has_prompt_changed "$bundle_dir" "$prompt_file"; then
    prompt_changed="true"
  fi

  # Get user-modified files
  local modified_files
  modified_files="$(get_user_modified_files "$bundle_dir")"
  local modified_count
  modified_count="$(echo "$modified_files" | grep -c . || echo 0)"

  # Get managed files count
  local managed_files
  managed_files="$(get_managed_files "$bundle_dir")"
  local managed_count
  managed_count="$(echo "$managed_files" | grep -c . || echo 0)"

  # Get last generation timestamp
  local last_generated
  last_generated="$(read_manifest_value "$bundle_dir" ".generated_at")"

  # Build result
  cat <<EOF
{
  "bundle_dir": "${bundle_dir}",
  "last_generated": "${last_generated}",
  "prompt_changed": ${prompt_changed},
  "managed_files_count": ${managed_count},
  "user_modified_count": ${modified_count},
  "user_modified_files": [$(echo "$modified_files" | sed 's/^/"/;s/$/"/' | paste -sd, - 2>/dev/null || echo "")]
}
EOF
}

# Generate diff between original generated file and current file
# Args: $1 = bundle directory, $2 = relative file path
# Returns: diff output or empty if no diff
generate_file_diff() {
  local bundle_dir="$1"
  local rel_path="$2"
  local current_file="${bundle_dir}/${rel_path}"

  if [[ ! -f "$current_file" ]]; then
    echo "File does not exist: $rel_path"
    return
  fi

  # We don't have the original file stored, only the hash
  # This function is for generating diffs between .new and current
  echo "Cannot generate diff - original file content not stored"
}

# Generate diff between current file and newly generated .new file
# Args: $1 = current file path, $2 = new file path
# Returns: unified diff output
generate_update_diff() {
  local current_file="$1"
  local new_file="$2"

  if [[ ! -f "$current_file" ]] || [[ ! -f "$new_file" ]]; then
    return 1
  fi

  diff -u "$current_file" "$new_file" 2>/dev/null || true
}

# Determine which components need regeneration based on changes
# Args: $1 = detection changes JSON
# Returns: comma-separated list of components
determine_regeneration_scope() {
  local changes_json="$1"

  local components=()

  if echo "$changes_json" | grep -q '"backend:'; then
    components+=("compose" "dockerfile" "env" "deploy-scripts")
  fi

  if echo "$changes_json" | grep -q '"frontend:'; then
    components+=("compose" "dockerfile" "env" "caddy")
  fi

  if echo "$changes_json" | grep -q '"database:'; then
    components+=("compose" "env" "deploy-scripts" "backup-scripts")
  fi

  if echo "$changes_json" | grep -q '"migrations:'; then
    components+=("deploy-scripts")
  fi

  # Deduplicate
  printf '%s\n' "${components[@]}" | sort -u | paste -sd, -
}

# Check if specific component should be regenerated
# Args: $1 = component name, $2 = scope string (comma-separated)
# Returns: 0 if should regenerate, 1 if not
should_regenerate_component() {
  local component="$1"
  local scope="$2"

  echo "$scope" | tr ',' '\n' | grep -qx "$component"
}

# Print human-readable update summary
# Args: $1 = analysis JSON
print_update_summary() {
  local analysis="$1"

  echo "╔══════════════════════════════════════════════════════════════════╗"
  echo "║ UPDATE ANALYSIS                                                   ║"
  echo "╠══════════════════════════════════════════════════════════════════╣"

  local last_gen prompt_changed managed_count modified_count

  if command -v jq >/dev/null 2>&1; then
    last_gen="$(echo "$analysis" | jq -r '.last_generated // "unknown"')"
    prompt_changed="$(echo "$analysis" | jq -r '.prompt_changed')"
    managed_count="$(echo "$analysis" | jq -r '.managed_files_count')"
    modified_count="$(echo "$analysis" | jq -r '.user_modified_count')"
  else
    last_gen="$(echo "$analysis" | python3 -c "import sys,json; print(json.load(sys.stdin).get('last_generated','unknown'))")"
    prompt_changed="$(echo "$analysis" | python3 -c "import sys,json; print(json.load(sys.stdin).get('prompt_changed',False))")"
    managed_count="$(echo "$analysis" | python3 -c "import sys,json; print(json.load(sys.stdin).get('managed_files_count',0))")"
    modified_count="$(echo "$analysis" | python3 -c "import sys,json; print(json.load(sys.stdin).get('user_modified_count',0))")"
  fi

  printf "║ %-67s║\n" "Last generated: ${last_gen}"
  printf "║ %-67s║\n" "Prompt changed: ${prompt_changed}"
  printf "║ %-67s║\n" "Managed files: ${managed_count}"
  printf "║ %-67s║\n" "User-modified files: ${modified_count}"

  if [[ "$modified_count" -gt 0 ]]; then
    echo "║                                                                    ║"
    printf "║ %-67s║\n" "User-modified files (will generate .new alongside):"

    local modified_files
    if command -v jq >/dev/null 2>&1; then
      modified_files="$(echo "$analysis" | jq -r '.user_modified_files[]')"
    else
      modified_files="$(echo "$analysis" | python3 -c "import sys,json; [print(f) for f in json.load(sys.stdin).get('user_modified_files',[])]")"
    fi

    while IFS= read -r file; do
      [[ -z "$file" ]] && continue
      printf "║   • %-63s║\n" "$file"
    done <<< "$modified_files"
  fi

  echo "╚══════════════════════════════════════════════════════════════════╝"
}

# Generate update report markdown
# Args: $1 = bundle directory, $2 = analysis JSON, $3 = detection changes JSON
generate_update_report() {
  local bundle_dir="$1"
  local analysis="$2"
  local detection_changes="$3"
  local report_path="${bundle_dir}/UPDATE_REPORT.md"

  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  cat > "$report_path" <<EOF
# Update Report

Generated: ${ts}

## Summary

This report summarizes changes made during the bundle update.

## Detection Changes

\`\`\`json
${detection_changes}
\`\`\`

## Analysis

\`\`\`json
${analysis}
\`\`\`

## Files Requiring Manual Merge

The following files were modified by you and have been preserved.
New versions have been generated alongside with \`.new\` extension.

EOF

  local modified_files
  if command -v jq >/dev/null 2>&1; then
    modified_files="$(echo "$analysis" | jq -r '.user_modified_files[]' 2>/dev/null)"
  else
    modified_files="$(echo "$analysis" | python3 -c "import sys,json; [print(f) for f in json.load(sys.stdin).get('user_modified_files',[])]" 2>/dev/null)"
  fi

  if [[ -n "$modified_files" ]]; then
    while IFS= read -r file; do
      [[ -z "$file" ]] && continue
      echo "- \`${file}\` → Review \`${file}.new\`" >> "$report_path"
    done <<< "$modified_files"
  else
    echo "_No user-modified files detected._" >> "$report_path"
  fi

  cat >> "$report_path" <<EOF

## Next Steps

1. Review the \`.new\` files listed above
2. Merge changes manually into your modified files
3. Delete the \`.new\` files after merging
4. Commit the changes:

\`\`\`bash
git add -A
git commit -m "chore(infra): update bundle"
\`\`\`

## Rollback

If you need to rollback, previous manifest snapshots are stored in:
\`\`\`
.hetzner-deployer/history/
\`\`\`
EOF

  echo "$report_path"
}
