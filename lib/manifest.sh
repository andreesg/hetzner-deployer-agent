#!/usr/bin/env bash
# lib/manifest.sh
#
# Manifest management functions for Hetzner Deployer Agent
# Handles state tracking, hash computation, and manifest read/write operations

set -euo pipefail

# Directory name for manifest storage within bundle
MANIFEST_DIR_NAME=".hetzner-deployer"

# Compute SHA256 hash of a file
# Args: $1 = file path
# Returns: hash string
compute_file_hash() {
  local file="$1"
  if [[ -f "$file" ]]; then
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum "$file" | cut -d' ' -f1
    else
      # macOS fallback
      shasum -a 256 "$file" | cut -d' ' -f1
    fi
  else
    echo ""
  fi
}

# Compute hash of prompt file for version tracking
# Args: $1 = prompt file path
# Returns: hash string
compute_prompt_hash() {
  local prompt_file="$1"
  compute_file_hash "$prompt_file"
}

# Get current git commit of app repo (or "unknown" if not a git repo)
# Args: $1 = app repo path
# Returns: commit hash or "unknown"
get_app_repo_commit() {
  local app_repo="$1"
  if [[ -d "${app_repo}/.git" ]]; then
    git -C "$app_repo" rev-parse HEAD 2>/dev/null || echo "unknown"
  else
    echo "unknown"
  fi
}

# Initialize manifest directory structure
# Args: $1 = bundle directory
init_manifest_dir() {
  local bundle_dir="$1"
  local manifest_dir="${bundle_dir}/${MANIFEST_DIR_NAME}"

  mkdir -p "${manifest_dir}/history"
  echo "$manifest_dir"
}

# Check if bundle has existing manifest (i.e., was previously generated)
# Args: $1 = bundle directory
# Returns: 0 if manifest exists, 1 otherwise
has_manifest() {
  local bundle_dir="$1"
  [[ -f "${bundle_dir}/${MANIFEST_DIR_NAME}/manifest.json" ]]
}

# Get manifest directory path
# Args: $1 = bundle directory
get_manifest_dir() {
  local bundle_dir="$1"
  echo "${bundle_dir}/${MANIFEST_DIR_NAME}"
}

# Get manifest file path
# Args: $1 = bundle directory
get_manifest_path() {
  local bundle_dir="$1"
  echo "${bundle_dir}/${MANIFEST_DIR_NAME}/manifest.json"
}

# Read a value from manifest.json using jq or python fallback
# Args: $1 = bundle directory, $2 = jq query
# Returns: value or empty string
read_manifest_value() {
  local bundle_dir="$1"
  local query="$2"
  local manifest_path
  manifest_path="$(get_manifest_path "$bundle_dir")"

  if [[ ! -f "$manifest_path" ]]; then
    echo ""
    return
  fi

  if command -v jq >/dev/null 2>&1; then
    jq -r "$query // empty" "$manifest_path" 2>/dev/null || echo ""
  else
    # Python fallback for systems without jq
    python3 -c "
import json
import sys
with open('$manifest_path') as f:
    data = json.load(f)
query = '$query'.lstrip('.')
parts = query.split('.')
result = data
for part in parts:
    if isinstance(result, dict) and part in result:
        result = result[part]
    else:
        result = ''
        break
print(result if result else '')
" 2>/dev/null || echo ""
  fi
}

# Check if a file was modified by user (current hash != generated hash)
# Args: $1 = bundle directory, $2 = relative file path
# Returns: 0 if modified, 1 if not modified or file doesn't exist
is_file_user_modified() {
  local bundle_dir="$1"
  local rel_path="$2"
  local abs_path="${bundle_dir}/${rel_path}"

  if [[ ! -f "$abs_path" ]]; then
    return 1
  fi

  local generated_hash
  local current_hash

  generated_hash="$(read_manifest_value "$bundle_dir" ".files.\"${rel_path}\".generated_hash")"
  current_hash="$(compute_file_hash "$abs_path")"

  if [[ -z "$generated_hash" ]]; then
    # File not in manifest, consider it user-created
    return 0
  fi

  [[ "$generated_hash" != "$current_hash" ]]
}

# Get list of all managed files from manifest
# Args: $1 = bundle directory
# Returns: newline-separated list of relative paths
get_managed_files() {
  local bundle_dir="$1"
  local manifest_path
  manifest_path="$(get_manifest_path "$bundle_dir")"

  if [[ ! -f "$manifest_path" ]]; then
    return
  fi

  if command -v jq >/dev/null 2>&1; then
    jq -r '.files | keys[]' "$manifest_path" 2>/dev/null || true
  else
    python3 -c "
import json
with open('$manifest_path') as f:
    data = json.load(f)
for key in data.get('files', {}).keys():
    print(key)
" 2>/dev/null || true
  fi
}

# Get list of user-modified files
# Args: $1 = bundle directory
# Returns: newline-separated list of relative paths that were modified
get_user_modified_files() {
  local bundle_dir="$1"
  local managed_files
  managed_files="$(get_managed_files "$bundle_dir")"

  while IFS= read -r rel_path; do
    [[ -z "$rel_path" ]] && continue
    if is_file_user_modified "$bundle_dir" "$rel_path"; then
      echo "$rel_path"
    fi
  done <<< "$managed_files"
}

# Archive current manifest to history before update
# Args: $1 = bundle directory
archive_current_manifest() {
  local bundle_dir="$1"
  local manifest_dir
  manifest_dir="$(get_manifest_dir "$bundle_dir")"
  local manifest_path="${manifest_dir}/manifest.json"

  if [[ ! -f "$manifest_path" ]]; then
    return
  fi

  local ts
  ts="$(date +%Y-%m-%dT%H-%M-%S)"
  local archive_dir="${manifest_dir}/history/${ts}"

  mkdir -p "$archive_dir"
  cp "$manifest_path" "$archive_dir/"

  if [[ -f "${manifest_dir}/detected-snapshot.json" ]]; then
    cp "${manifest_dir}/detected-snapshot.json" "$archive_dir/"
  fi

  if [[ -f "${manifest_dir}/prompt-version.md" ]]; then
    cp "${manifest_dir}/prompt-version.md" "$archive_dir/"
  fi

  echo "$archive_dir"
}

# Create initial manifest structure (JSON)
# Args: $1 = bundle directory, $2 = prompt hash, $3 = app repo commit, $4 = detection summary JSON
# Outputs to stdout
create_manifest_json() {
  local bundle_dir="$1"
  local prompt_hash="$2"
  local app_commit="$3"
  local detection_summary="$4"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  cat <<EOF
{
  "version": "1.0.0",
  "generated_at": "${ts}",
  "prompt_hash": "${prompt_hash}",
  "app_repo_commit": "${app_commit}",
  "files": {},
  "detection_summary": ${detection_summary}
}
EOF
}

# Add or update a file entry in the manifest
# Args: $1 = manifest JSON (stdin or string), $2 = relative path, $3 = hash, $4 = managed (true/false)
# This function is meant to be used with jq; for shell use, see update_manifest_file()
# Returns: updated JSON

# Update manifest with file information (writes directly to manifest.json)
# Args: $1 = bundle directory, $2 = relative file path
update_manifest_file() {
  local bundle_dir="$1"
  local rel_path="$2"
  local abs_path="${bundle_dir}/${rel_path}"
  local manifest_path
  manifest_path="$(get_manifest_path "$bundle_dir")"

  if [[ ! -f "$abs_path" ]] || [[ ! -f "$manifest_path" ]]; then
    return 1
  fi

  local file_hash
  local ts
  file_hash="$(compute_file_hash "$abs_path")"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if command -v jq >/dev/null 2>&1; then
    local tmp_file
    tmp_file="$(mktemp)"
    jq --arg path "$rel_path" \
       --arg hash "$file_hash" \
       --arg ts "$ts" \
       '.files[$path] = {
          "generated_hash": $hash,
          "current_hash": $hash,
          "managed": true,
          "user_modified": false,
          "last_updated": $ts
        }' "$manifest_path" > "$tmp_file"
    mv "$tmp_file" "$manifest_path"
  else
    # Python fallback
    python3 -c "
import json
with open('$manifest_path', 'r') as f:
    data = json.load(f)
data.setdefault('files', {})['$rel_path'] = {
    'generated_hash': '$file_hash',
    'current_hash': '$file_hash',
    'managed': True,
    'user_modified': False,
    'last_updated': '$ts'
}
with open('$manifest_path', 'w') as f:
    json.dump(data, f, indent=2)
"
  fi
}

# Refresh current_hash and user_modified status for all files in manifest
# Args: $1 = bundle directory
refresh_manifest_hashes() {
  local bundle_dir="$1"
  local manifest_path
  manifest_path="$(get_manifest_path "$bundle_dir")"

  if [[ ! -f "$manifest_path" ]]; then
    return 1
  fi

  local managed_files
  managed_files="$(get_managed_files "$bundle_dir")"

  while IFS= read -r rel_path; do
    [[ -z "$rel_path" ]] && continue
    local abs_path="${bundle_dir}/${rel_path}"

    if [[ ! -f "$abs_path" ]]; then
      continue
    fi

    local current_hash
    current_hash="$(compute_file_hash "$abs_path")"
    local generated_hash
    generated_hash="$(read_manifest_value "$bundle_dir" ".files.\"${rel_path}\".generated_hash")"
    local user_modified="false"

    if [[ "$current_hash" != "$generated_hash" ]]; then
      user_modified="true"
    fi

    if command -v jq >/dev/null 2>&1; then
      local tmp_file
      tmp_file="$(mktemp)"
      jq --arg path "$rel_path" \
         --arg hash "$current_hash" \
         --argjson modified "$user_modified" \
         '.files[$path].current_hash = $hash | .files[$path].user_modified = $modified' \
         "$manifest_path" > "$tmp_file"
      mv "$tmp_file" "$manifest_path"
    else
      python3 -c "
import json
with open('$manifest_path', 'r') as f:
    data = json.load(f)
if '$rel_path' in data.get('files', {}):
    data['files']['$rel_path']['current_hash'] = '$current_hash'
    data['files']['$rel_path']['user_modified'] = $user_modified
with open('$manifest_path', 'w') as f:
    json.dump(data, f, indent=2)
"
    fi
  done <<< "$managed_files"
}

# Save detection snapshot
# Args: $1 = bundle directory, $2 = detected.json content or path
save_detection_snapshot() {
  local bundle_dir="$1"
  local detected_content="$2"
  local manifest_dir
  manifest_dir="$(get_manifest_dir "$bundle_dir")"

  mkdir -p "$manifest_dir"

  if [[ -f "$detected_content" ]]; then
    cp "$detected_content" "${manifest_dir}/detected-snapshot.json"
  else
    echo "$detected_content" > "${manifest_dir}/detected-snapshot.json"
  fi
}

# Save prompt version snapshot
# Args: $1 = bundle directory, $2 = prompt file path
save_prompt_snapshot() {
  local bundle_dir="$1"
  local prompt_file="$2"
  local manifest_dir
  manifest_dir="$(get_manifest_dir "$bundle_dir")"

  mkdir -p "$manifest_dir"
  cp "$prompt_file" "${manifest_dir}/prompt-version.md"
}

# Compare current prompt with saved snapshot
# Args: $1 = bundle directory, $2 = current prompt file
# Returns: 0 if changed, 1 if same
has_prompt_changed() {
  local bundle_dir="$1"
  local current_prompt="$2"
  local manifest_dir
  manifest_dir="$(get_manifest_dir "$bundle_dir")"
  local saved_prompt="${manifest_dir}/prompt-version.md"

  if [[ ! -f "$saved_prompt" ]]; then
    return 0  # No saved prompt = changed
  fi

  local current_hash saved_hash
  current_hash="$(compute_file_hash "$current_prompt")"
  saved_hash="$(compute_file_hash "$saved_prompt")"

  [[ "$current_hash" != "$saved_hash" ]]
}

# Clean up old history entries, keeping only last N
# Args: $1 = bundle directory, $2 = number to keep (default 10)
cleanup_history() {
  local bundle_dir="$1"
  local keep="${2:-10}"
  local history_dir="${bundle_dir}/${MANIFEST_DIR_NAME}/history"

  if [[ ! -d "$history_dir" ]]; then
    return
  fi

  local count
  count="$(find "$history_dir" -maxdepth 1 -type d | wc -l)"
  count=$((count - 1))  # Subtract 1 for the history dir itself

  if [[ $count -le $keep ]]; then
    return
  fi

  # Remove oldest entries
  local to_remove=$((count - keep))
  find "$history_dir" -maxdepth 1 -type d | sort | head -n "$to_remove" | while read -r dir; do
    [[ "$dir" == "$history_dir" ]] && continue
    rm -rf "$dir"
  done
}
