#!/usr/bin/env bash
# validate.sh - Bundle validation functions for the agent loop
#
# These functions validate generated bundles and return errors that can be
# fed back to Claude for self-correction.

# Base required files that must exist in every generated bundle
BASE_REQUIRED_FILES=(
  "README.md"
  "Makefile"
  ".gitignore"
  "config/detected.json"
  "config/inputs.example.sh"
  "infra/terraform/modules/hetzner-vps/main.tf"
  "infra/cloud-init/user-data.yaml"
  "deploy/compose/docker-compose.yml"
  "deploy/compose/Caddyfile"
  "deploy/scripts/deploy.sh"
  ".hetzner-deployer/manifest.json"
)

# Environment-specific files (will be added based on ENVIRONMENTS)
# Format: env:file
ENV_SPECIFIC_FILES=(
  "dev:config/envs/dev.env.example"
  "dev:infra/terraform/envs/dev/main.tf"
  "dev:ci/github-actions/workflows/deploy-dev.yml"
  "staging:config/envs/staging.env.example"
  "staging:infra/terraform/envs/staging/main.tf"
  "staging:ci/github-actions/workflows/deploy-staging.yml"
  "prod:config/envs/prod.env.example"
  "prod:infra/terraform/envs/prod/main.tf"
  "prod:ci/github-actions/workflows/deploy-prod.yml"
)

# build_required_files()
# Builds the list of required files based on environments
# Usage: build_required_files "dev,staging,prod"
build_required_files() {
  local environments="${1:-dev,staging,prod}"
  local -a required_files=("${BASE_REQUIRED_FILES[@]}")

  # Add environment-specific files
  for entry in "${ENV_SPECIFIC_FILES[@]}"; do
    local env="${entry%%:*}"
    local file="${entry#*:}"

    # Check if this environment is in the list
    if [[ ",$environments," == *",$env,"* ]]; then
      required_files+=("$file")
    fi
  done

  # Return as newline-separated list
  printf '%s\n' "${required_files[@]}"
}

# validate_bundle()
# Validates a generated bundle and returns errors as newline-separated strings.
# Returns empty string if validation passes.
#
# Usage: errors=$(validate_bundle "/path/to/bundle" "prod")
#        errors=$(validate_bundle "/path/to/bundle" "dev,staging,prod")
validate_bundle() {
  local bundle_dir="$1"
  local environments="${2:-dev,staging,prod}"
  local errors=""

  # Build required files list based on environments
  local -a required_files
  while IFS= read -r file; do
    required_files+=("$file")
  done < <(build_required_files "$environments")

  # Check required files exist
  for file in "${required_files[@]}"; do
    if [[ ! -f "${bundle_dir}/${file}" ]]; then
      errors+="MISSING FILE: ${file}"$'\n'
    fi
  done

  # Validate detected.json is valid JSON
  local detected_json="${bundle_dir}/config/detected.json"
  if [[ -f "$detected_json" ]]; then
    if ! jq empty "$detected_json" 2>/dev/null; then
      local jq_err
      jq_err=$(jq empty "$detected_json" 2>&1)
      errors+="INVALID JSON in config/detected.json: ${jq_err}"$'\n'
    fi
  fi

  # Validate docker-compose.yml syntax
  local compose_file="${bundle_dir}/deploy/compose/docker-compose.yml"
  if [[ -f "$compose_file" ]] && command -v docker >/dev/null 2>&1; then
    local compose_err
    if ! compose_err=$(docker compose -f "$compose_file" config 2>&1 >/dev/null); then
      # Extract just the error message, not the full output
      compose_err=$(echo "$compose_err" | grep -i "error\|invalid\|yaml" | head -3)
      errors+="DOCKER COMPOSE ERROR in deploy/compose/docker-compose.yml: ${compose_err}"$'\n'
    fi
  fi

  # Validate Caddyfile basic syntax (check for common issues)
  local caddyfile="${bundle_dir}/deploy/compose/Caddyfile"
  if [[ -f "$caddyfile" ]]; then
    # Check for unbalanced braces
    local open_braces close_braces
    open_braces=$(grep -o '{' "$caddyfile" | wc -l)
    close_braces=$(grep -o '}' "$caddyfile" | wc -l)
    if [[ "$open_braces" -ne "$close_braces" ]]; then
      errors+="CADDYFILE SYNTAX ERROR: Unbalanced braces (${open_braces} open, ${close_braces} close)"$'\n'
    fi
  fi

  # Validate Makefile exists and has expected targets
  local makefile="${bundle_dir}/Makefile"
  if [[ -f "$makefile" ]]; then
    # Check for basic expected targets
    if ! grep -q "^plan:" "$makefile" 2>/dev/null; then
      errors+="MAKEFILE MISSING TARGET: 'plan' target not found"$'\n'
    fi
    if ! grep -q "^apply:" "$makefile" 2>/dev/null; then
      errors+="MAKEFILE MISSING TARGET: 'apply' target not found"$'\n'
    fi
    if ! grep -q "^deploy:" "$makefile" 2>/dev/null; then
      errors+="MAKEFILE MISSING TARGET: 'deploy' target not found"$'\n'
    fi
  fi

  # Validate deploy scripts are executable shell scripts
  local deploy_script="${bundle_dir}/deploy/scripts/deploy.sh"
  if [[ -f "$deploy_script" ]]; then
    if ! head -1 "$deploy_script" | grep -q "^#!"; then
      errors+="DEPLOY SCRIPT ERROR: deploy.sh missing shebang line"$'\n'
    fi
  fi

  # Return errors (empty string means validation passed)
  printf "%s" "$errors"
}

# validate_bundle_verbose()
# Same as validate_bundle but prints progress to stderr
validate_bundle_verbose() {
  local bundle_dir="$1"
  local environments="${2:-dev,staging,prod}"
  local errors=""
  local pass_count=0
  local fail_count=0

  echo "Validating bundle: ${bundle_dir}" >&2
  echo "Environments: ${environments}" >&2
  echo "---" >&2

  # Build required files list based on environments
  local -a required_files
  while IFS= read -r file; do
    required_files+=("$file")
  done < <(build_required_files "$environments")

  # Check required files
  for file in "${required_files[@]}"; do
    if [[ -f "${bundle_dir}/${file}" ]]; then
      ((pass_count++))
    else
      errors+="MISSING FILE: ${file}"$'\n'
      ((fail_count++))
      echo "✗ Missing: ${file}" >&2
    fi
  done
  echo "Files: ${pass_count} present, ${fail_count} missing" >&2

  # Validate JSON
  local detected_json="${bundle_dir}/config/detected.json"
  if [[ -f "$detected_json" ]]; then
    if jq empty "$detected_json" 2>/dev/null; then
      echo "✓ detected.json is valid JSON" >&2
    else
      local jq_err
      jq_err=$(jq empty "$detected_json" 2>&1)
      errors+="INVALID JSON in config/detected.json: ${jq_err}"$'\n'
      echo "✗ detected.json has JSON errors" >&2
    fi
  fi

  # Validate docker-compose
  local compose_file="${bundle_dir}/deploy/compose/docker-compose.yml"
  if [[ -f "$compose_file" ]] && command -v docker >/dev/null 2>&1; then
    if docker compose -f "$compose_file" config >/dev/null 2>&1; then
      echo "✓ docker-compose.yml syntax valid" >&2
    else
      local compose_err
      compose_err=$(docker compose -f "$compose_file" config 2>&1 | grep -i "error\|invalid\|yaml" | head -3)
      errors+="DOCKER COMPOSE ERROR: ${compose_err}"$'\n'
      echo "✗ docker-compose.yml has errors" >&2
    fi
  fi

  echo "---" >&2
  if [[ -z "$errors" ]]; then
    echo "Validation PASSED" >&2
  else
    echo "Validation FAILED with errors" >&2
  fi

  printf "%s" "$errors"
}

# count_validation_errors()
# Returns the number of validation errors
count_validation_errors() {
  local errors="$1"
  if [[ -z "$errors" ]]; then
    echo "0"
  else
    echo "$errors" | grep -c "^" || echo "0"
  fi
}

# format_errors_for_retry()
# Formats validation errors into a prompt section for Claude
format_errors_for_retry() {
  local errors="$1"
  local attempt="$2"

  cat <<EOF

## ⚠️ RETRY ATTEMPT ${attempt} - PREVIOUS GENERATION FAILED

The previous generation attempt failed validation. You MUST fix these errors:

\`\`\`
${errors}
\`\`\`

### Instructions for this retry:
1. Carefully read each error above
2. Generate the COMPLETE bundle again, fixing all errors
3. Pay special attention to:
   - Creating ALL required files (don't skip any)
   - Valid JSON syntax in detected.json
   - Valid YAML syntax in docker-compose.yml
   - Balanced braces in Caddyfile
   - Including shebang lines in shell scripts
4. Do NOT apologize or explain - just generate the corrected files

EOF
}
