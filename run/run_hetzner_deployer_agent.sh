#!/usr/bin/env bash
# run_hetzner_deployer_agent.sh
#
# Opinionated runner for Claude Code (terminal) to generate an app-specific Hetzner infra bundle
# in a NEW directory OUTSIDE the app repo, with full audit logs.
#
# Supports two modes:
# - NEW mode (default): Create a fresh bundle in a new directory
# - UPDATE mode: Update an existing bundle with incremental changes
#
# Execution model:
# - APP_REPO is read-only input.
# - BUNDLE_DIR is the output working directory (and becomes an infra repo).
# - Claude is launched from BUNDLE_DIR and MUST write only there.
#
# Github integration:
# - GitHub Actions live in the app repo (added as new deploy workflows; no overwrites).
# - Deploy workflows clone the infra bundle repo (bundle) and run its deploy scripts.
#
# Requirements:
# - claude CLI installed and authenticated
# - git installed
#
# Usage:
#   chmod +x run/run_hetzner_deployer_agent.sh
#
#   # Create new bundle (interactive)
#   ./run/run_hetzner_deployer_agent.sh
#
#   # Create new bundle (explicit)
#   ./run/run_hetzner_deployer_agent.sh --new
#
#   # Update existing bundle
#   ./run/run_hetzner_deployer_agent.sh --update /path/to/existing/bundle
#
#   # Dry-run update (preview changes)
#   ./run/run_hetzner_deployer_agent.sh --update /path/to/bundle --dry-run
#
#   # Force update (overwrite user modifications)
#   ./run/run_hetzner_deployer_agent.sh --update /path/to/bundle --force
#
#   # Update specific components only
#   ./run/run_hetzner_deployer_agent.sh --update /path/to/bundle --only=ci,terraform

set -euo pipefail

# --- Helper functions ---
bold() { printf "\033[1m%s\033[0m\n" "$*"; }
warn() { printf "\033[33m%s\033[0m\n" "$*"; }
info() { printf "\033[36m%s\033[0m\n" "$*"; }
success() { printf "\033[32m%s\033[0m\n" "$*"; }
die()  { printf "\033[31mERROR: %s\033[0m\n" "$*"; exit 1; }

# Resolve agent repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source library functions
source "${AGENT_ROOT}/lib/manifest.sh"
source "${AGENT_ROOT}/lib/diff.sh"
source "${AGENT_ROOT}/lib/validate.sh"

PROMPT_FILE="${AGENT_ROOT}/prompts/HETZNER_DEPLOYER_PROMPT.md"
RUNS_DIR="${AGENT_ROOT}/runs"

# --- Parse arguments ---
MODE=""
BUNDLE_DIR=""
DRY_RUN="false"
FORCE="false"
ONLY_COMPONENTS=""
APP_REPO=""
MODEL=""
INTERACTIVE="false"
ENVIRONMENTS="dev,staging,prod"

print_usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Modes:
  --new                     Create a new bundle (default if no existing bundle)
  --update <bundle_path>    Update an existing bundle

Options:
  --app-repo <path>         Path to application repo (required)
  --output <path>           Output directory for new bundle (new mode only)
  --environments <list>     Environments to generate (default: dev,staging,prod)
                            Options: dev, staging, prod (comma-separated)
  --model <model>           Claude model to use (e.g., sonnet, opus, haiku)
  --interactive             Run Claude interactively (paste instruction when CLI opens)
  --dry-run                 Preview changes without making them (update mode only)
  --force                   Overwrite user-modified files (update mode only)
  --only <components>       Only regenerate specific components (comma-separated)
                            Components: ci, terraform, compose, scripts, docs
  -h, --help                Show this help message

Note: In --interactive mode, the instruction is copied to clipboard. Paste (Cmd+V)
      when Claude opens and press Enter to start generation.

Examples:
  # Interactive mode (prompts for paths)
  $(basename "$0")

  # Create new bundle with explicit output
  $(basename "$0") --new --app-repo /path/to/app --output /path/to/infra-bundle

  # Production only (single VPS)
  $(basename "$0") --app-repo /path/to/app --output /path/to/bundle --environments prod

  # Update existing bundle
  $(basename "$0") --update /path/to/bundle --app-repo /path/to/app

  # Preview update changes
  $(basename "$0") --update /path/to/bundle --app-repo /path/to/app --dry-run
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --new)
      MODE="new"
      shift
      ;;
    --update)
      MODE="update"
      BUNDLE_DIR="$2"
      shift 2
      ;;
    --app-repo)
      APP_REPO="$2"
      shift 2
      ;;
    --output)
      BUNDLE_DIR="$2"
      shift 2
      ;;
    --model)
      MODEL="$2"
      shift 2
      ;;
    --interactive)
      INTERACTIVE="true"
      shift
      ;;
    --environments)
      ENVIRONMENTS="$2"
      shift 2
      ;;
    --environments=*)
      ENVIRONMENTS="${1#*=}"
      shift
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    --force)
      FORCE="true"
      shift
      ;;
    --only)
      ONLY_COMPONENTS="$2"
      shift 2
      ;;
    --only=*)
      ONLY_COMPONENTS="${1#*=}"
      shift
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      die "Unknown option: $1. Use --help for usage."
      ;;
  esac
done

# --- Validate dependencies ---
command -v claude >/dev/null 2>&1 || die "claude CLI not found. Install Claude Code CLI and ensure 'claude' is on PATH."
command -v git >/dev/null 2>&1 || die "git not found."
[[ -f "$PROMPT_FILE" ]] || die "Missing prompt: ${PROMPT_FILE}"
mkdir -p "$RUNS_DIR"

# --- Validate environments ---
VALID_ENVS="dev staging prod"
IFS=',' read -ra ENV_ARRAY <<< "$ENVIRONMENTS"
for env in "${ENV_ARRAY[@]}"; do
  env_trimmed="$(echo "$env" | tr -d ' ')"
  if [[ ! " $VALID_ENVS " =~ " $env_trimmed " ]]; then
    die "Invalid environment: '$env_trimmed'. Valid options: dev, staging, prod"
  fi
done
ENVIRONMENTS="$(IFS=','; echo "${ENV_ARRAY[*]}" | tr -d ' ')"

bold "Hetzner Deployer Agent"
echo

# --- Interactive mode if no arguments ---
if [[ -z "$MODE" ]] && [[ -z "$APP_REPO" ]]; then
  read -r -p "Path to the application repo to deploy (read-only scan): " APP_REPO_INPUT
  APP_REPO="$(cd "$APP_REPO_INPUT" 2>/dev/null && pwd)" || die "App repo path not found."

  read -r -p "Create NEW bundle or UPDATE existing? [new/update]: " MODE_INPUT
  MODE_INPUT="${MODE_INPUT:-new}"

  if [[ "$MODE_INPUT" == "update" ]]; then
    MODE="update"
    read -r -p "Path to existing bundle to update: " BUNDLE_DIR_INPUT
    BUNDLE_DIR="$(cd "$BUNDLE_DIR_INPUT" 2>/dev/null && pwd)" || die "Bundle path not found."

    if ! has_manifest "$BUNDLE_DIR"; then
      warn "Warning: No manifest found in bundle. This bundle may not have been generated by this agent."
      read -r -p "Continue anyway? [y/N]: " CONTINUE
      [[ "$CONTINUE" =~ ^[Yy] ]] || exit 0
    fi
  else
    MODE="new"
    read -r -p "Where should the infra bundle (new infra repo) be created? " BUNDLE_PARENT_INPUT
    BUNDLE_PARENT="$(cd "$BUNDLE_PARENT_INPUT" 2>/dev/null && pwd)" || die "Bundle parent directory not found."

    DEFAULT_BUNDLE_NAME="infra-hetzner-$(basename "$APP_REPO")-$(date +%Y%m%d-%H%M%S)"
    read -r -p "Infra bundle directory name [${DEFAULT_BUNDLE_NAME}]: " BUNDLE_NAME
    BUNDLE_NAME="${BUNDLE_NAME:-$DEFAULT_BUNDLE_NAME}"
    BUNDLE_DIR="${BUNDLE_PARENT}/${BUNDLE_NAME}"
  fi
elif [[ -z "$APP_REPO" ]]; then
  die "App repo path required. Use --app-repo or run in interactive mode."
fi

# Default MODE to "new" if --output was provided without --new/--update
if [[ -z "$MODE" ]] && [[ -n "$BUNDLE_DIR" ]]; then
  MODE="new"
fi

# Default MODE to "new" if still not set (non-interactive with --app-repo only)
if [[ -z "$MODE" ]]; then
  MODE="new"
fi

# Validate app repo
APP_REPO="$(cd "$APP_REPO" 2>/dev/null && pwd)" || die "App repo path not found: $APP_REPO"

# --- Mode-specific setup ---
if [[ "$MODE" == "new" ]]; then
  # NEW MODE
  if [[ -z "$BUNDLE_DIR" ]]; then
    die "Bundle directory not set. Use --output <path> or run in interactive mode."
  fi

  if [[ -e "$BUNDLE_DIR" ]]; then
    if has_manifest "$BUNDLE_DIR"; then
      warn "Bundle already exists with manifest. Use --update mode instead."
      read -r -p "Switch to update mode? [Y/n]: " SWITCH
      if [[ ! "$SWITCH" =~ ^[Nn] ]]; then
        MODE="update"
      else
        die "Bundle dir already exists: $BUNDLE_DIR"
      fi
    else
      die "Bundle dir already exists: $BUNDLE_DIR (choose a different name or use --update)"
    fi
  fi

  if [[ "$MODE" == "new" ]]; then
    mkdir -p "$BUNDLE_DIR"
    # Initialize a git repo for the bundle (infra repo)
    (
      cd "$BUNDLE_DIR"
      git init -q
    )
    info "Created new bundle directory: $BUNDLE_DIR"
  fi
fi

if [[ "$MODE" == "update" ]]; then
  # UPDATE MODE
  [[ -d "$BUNDLE_DIR" ]] || die "Bundle directory not found: $BUNDLE_DIR"
  BUNDLE_DIR="$(cd "$BUNDLE_DIR" && pwd)"

  info "Update mode: $BUNDLE_DIR"

  # Refresh manifest hashes to detect user modifications
  if has_manifest "$BUNDLE_DIR"; then
    info "Refreshing manifest hashes..."
    refresh_manifest_hashes "$BUNDLE_DIR"

    # Analyze update requirements
    ANALYSIS="$(analyze_update_requirements "$BUNDLE_DIR" "$APP_REPO" "$PROMPT_FILE")"
    print_update_summary "$ANALYSIS"
    echo

    if [[ "$DRY_RUN" == "true" ]]; then
      bold "DRY RUN - No changes will be made"
      echo
      info "Would regenerate bundle with current prompt and app repo state."

      # Show what would be preserved
      MODIFIED_FILES="$(get_user_modified_files "$BUNDLE_DIR")"
      if [[ -n "$MODIFIED_FILES" ]]; then
        info "User-modified files that would generate .new alongside:"
        echo "$MODIFIED_FILES" | while read -r f; do
          [[ -n "$f" ]] && echo "  • $f"
        done
      fi

      exit 0
    fi

    # Archive current manifest before update
    info "Archiving current manifest to history..."
    ARCHIVE_PATH="$(archive_current_manifest "$BUNDLE_DIR")"
    [[ -n "$ARCHIVE_PATH" ]] && info "Archived to: $ARCHIVE_PATH"

    # Handle user-modified files
    if [[ "$FORCE" != "true" ]]; then
      MODIFIED_FILES="$(get_user_modified_files "$BUNDLE_DIR")"
      if [[ -n "$MODIFIED_FILES" ]]; then
        warn "User-modified files detected. New versions will be generated as .new files."
        warn "Use --force to overwrite them instead."
      fi
    else
      warn "FORCE mode: User-modified files will be overwritten (backups created as .bak)"
    fi
  else
    warn "No manifest found. Treating as initial generation with existing directory."
  fi
fi

# --- Run logging setup ---
APP_BASENAME="$(basename "$APP_REPO")"
TS="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="${RUNS_DIR}/${APP_BASENAME}/${TS}"
mkdir -p "$RUN_DIR"

# --- Repo detection heuristics (lightweight hints for Claude) ---
bold "Scanning app repo for signals (hints only)..."
echo

find_first() { find "$APP_REPO" -maxdepth 6 -type f -name "$1" 2>/dev/null | head -n 1; }

PKG_JSON="$(find_first package.json || true)"
POM_XML="$(find_first pom.xml || true)"
GO_MOD="$(find_first go.mod || true)"
PYPROJECT="$(find_first pyproject.toml || true)"
REQ_TXT="$(find_first requirements.txt || true)"
COMPOSE="$(find_first docker-compose.yml || true)"
DOCKERFILES="$(find "$APP_REPO" -maxdepth 7 -type f -iname "Dockerfile*" 2>/dev/null | head -n 50 || true)"
LOCKFILES="$(find "$APP_REPO" -maxdepth 7 -type f \
    \( -name "pnpm-lock.yaml" -o -name "package-lock.json" -o -name "yarn.lock" -o -name "bun.lockb" \
       -o -name "poetry.lock" -o -name "Pipfile.lock" -o -name "uv.lock" \) \
    2>/dev/null | head -n 30 || true)"

# GitHub Actions signals (existing workflows)
WORKFLOWS_DIR="${APP_REPO}/.github/workflows"
WORKFLOWS_LIST=""
if [[ -d "$WORKFLOWS_DIR" ]]; then
  WORKFLOWS_LIST="$(find "$WORKFLOWS_DIR" -maxdepth 1 -type f \( -name "*.yml" -o -name "*.yaml" \) 2>/dev/null | sort || true)"
fi

# DB signals (very lightweight hints; Claude must do full scan)
DB_SIGNAL_FILES="$(find "$APP_REPO" -maxdepth 8 -type f \( \
        -iname "*.env.example" -o -iname "*.env.sample" -o -name ".env.example" -o -name ".env.sample" -o -name ".env.template" \
        -o -path "*/prisma/schema.prisma" -o -name "alembic.ini" -o -path "*/config/database.yml" -o -name "database.yml" \
      \) 2>/dev/null | head -n 50 || true)"

FRONTEND_HINTS=()
BACKEND_HINTS=()
DB_HINTS=()

if [[ -n "$PKG_JSON" ]]; then
  if grep -qE "\"next\"|\"react\"|\"vite\"|\"nuxt\"|\"svelte\"|\"astro\"" "$PKG_JSON" 2>/dev/null; then
    FRONTEND_HINTS+=("package.json suggests frontend frameworks (next/react/vite/nuxt/svelte/astro)")
  fi
  if grep -qE "\"express\"|\"fastify\"|\"nestjs\"|\"koa\"|\"hono\"|\"prisma\"|\"typeorm\"|\"sequelize\"" "$PKG_JSON" 2>/dev/null; then
    BACKEND_HINTS+=("package.json suggests backend frameworks/tools (express/fastify/nest/koa/prisma/typeorm/sequelize)")
  fi
  if grep -qE "\"pg\"|\"postgres\"|\"prisma\"|\"knex\"" "$PKG_JSON" 2>/dev/null; then
    DB_HINTS+=("package.json suggests DB dependencies (pg/postgres/prisma/knex)")
  fi
fi

[[ -n "$PYPROJECT" || -n "$REQ_TXT" ]] && BACKEND_HINTS+=("Python backend detected (pyproject/requirements.txt)")
[[ -n "$GO_MOD" ]] && BACKEND_HINTS+=("Go backend detected (go.mod)")
[[ -n "$POM_XML" ]] && BACKEND_HINTS+=("JVM backend detected (pom.xml)")
[[ -n "$DB_SIGNAL_FILES" ]] && DB_HINTS+=("Found common DB signal files (env examples/prisma/alembic/database.yml)")

# --- Write run metadata ---
cat > "${RUN_DIR}/meta.txt" <<EOF
timestamp: ${TS}
agent_root: ${AGENT_ROOT}
app_repo: ${APP_REPO}
bundle_dir: ${BUNDLE_DIR}
prompt_file: ${PROMPT_FILE}
mode: ${MODE}
environments: ${ENVIRONMENTS}
dry_run: ${DRY_RUN}
force: ${FORCE}
only_components: ${ONLY_COMPONENTS}
EOF

# Save repo facts (hints)
cat > "${RUN_DIR}/repo_facts.txt" <<EOF
Signals:
- package.json: ${PKG_JSON:-none}
- lockfiles:
${LOCKFILES:-none}

- pyproject.toml: ${PYPROJECT:-none}
- requirements.txt: ${REQ_TXT:-none}
- go.mod: ${GO_MOD:-none}
- pom.xml: ${POM_XML:-none}
- docker-compose.yml: ${COMPOSE:-none}

- Dockerfiles (first 50):
${DOCKERFILES:-none}

Existing GitHub Actions workflows in APP_REPO:
${WORKFLOWS_LIST:-none}

DB signal files (first 50):
${DB_SIGNAL_FILES:-none}

Heuristic hints:
- Frontend hints: ${FRONTEND_HINTS[*]:-none}
- Backend hints: ${BACKEND_HINTS[*]:-none}
- DB hints: ${DB_HINTS[*]:-none}
EOF

# --- Build update mode context if applicable ---
UPDATE_MODE_CONTEXT=""
if [[ "$MODE" == "update" ]]; then
  MODIFIED_FILES_LIST="$(get_user_modified_files "$BUNDLE_DIR" 2>/dev/null || true)"

  UPDATE_MODE_CONTEXT="$(cat <<EOF

# UPDATE MODE CONTEXT
This is an UPDATE to an existing bundle, not a fresh generation.

EXISTING_BUNDLE_DIR: ${BUNDLE_DIR}
FORCE_OVERWRITE: ${FORCE}
ONLY_COMPONENTS: ${ONLY_COMPONENTS:-all}

## User-Modified Files (DO NOT OVERWRITE unless FORCE=true)
${MODIFIED_FILES_LIST:-none}

## Update Mode Rules
- If FORCE_OVERWRITE is false and a file is in the user-modified list:
  - Generate the new version as <filename>.new alongside the original
  - Do NOT overwrite the original file
  - Generate <filename>.diff showing changes if possible
- If FORCE_OVERWRITE is true:
  - Create <filename>.bak backup of user-modified files before overwriting
  - Then overwrite with new content
- If ONLY_COMPONENTS is set (not "all"):
  - Only regenerate files for those components
  - Leave other files untouched
- After generation, update the manifest at .hetzner-deployer/manifest.json
- Generate UPDATE_REPORT.md summarizing all changes made
EOF
)"
fi

# --- Build the EXACT prompt that will be sent (prompt + context) and snapshot it ---
CONTEXT_BLOCK="$(cat <<EOF
# CONTEXT (DO NOT IGNORE)
APP_REPO (read-only scan): ${APP_REPO}
BUNDLE_DIR (write here ONLY): ${BUNDLE_DIR}
GENERATION_MODE: ${MODE}
ENVIRONMENTS: ${ENVIRONMENTS}

Rules:
- Do NOT modify APP_REPO.
- Create ALL generated files under BUNDLE_DIR.
- ONLY generate infrastructure for these environments: ${ENVIRONMENTS}
  - Skip Terraform, workflows, and env files for environments not in this list.
  - If only "prod" is specified, generate only production infrastructure (single VPS).
- Existing workflows in APP_REPO MUST NOT be modified automatically (generate new deploy workflows + an install plan).
- The bundle MUST detect database needs and wire BE↔DB (Postgres) properly; FE must never talk directly to DB.
- After generating files, create/update .hetzner-deployer/manifest.json with file hashes.
- Save detection results to .hetzner-deployer/detected-snapshot.json as well as config/detected.json.

Repo facts (hints only; you must still scan APP_REPO thoroughly):
$(cat "${RUN_DIR}/repo_facts.txt")
${UPDATE_MODE_CONTEXT}
EOF
)"

FINAL_PROMPT="$(cat "${PROMPT_FILE}")"$'\n\n'"${CONTEXT_BLOCK}"

# Snapshot the exact prompt used
PROMPT_SNAPSHOT_PATH="${RUN_DIR}/prompt_${TS}.md"
printf "%s\n" "$FINAL_PROMPT" > "$PROMPT_SNAPSHOT_PATH"
ln -sf "$PROMPT_SNAPSHOT_PATH" "${RUN_DIR}/prompt_latest.md" 2>/dev/null || true

# Save prompt snapshot to bundle manifest dir
if [[ "$MODE" == "update" ]] || [[ "$MODE" == "new" ]]; then
  MANIFEST_DIR="$(init_manifest_dir "$BUNDLE_DIR")"
  save_prompt_snapshot "$BUNDLE_DIR" "$PROMPT_FILE"
fi

echo
bold "Bundle (infra repo): ${BUNDLE_DIR}"
bold "Mode: ${MODE}"
bold "Environments: ${ENVIRONMENTS}"
bold "Run log: ${RUN_DIR}"
echo
bold "Launching Claude Code..."
echo "Claude must write ONLY into: ${BUNDLE_DIR}"
echo

# Run Claude from bundle directory so any writes naturally land there.
cd "$BUNDLE_DIR"

# --- Agent Loop: Generate with retry on validation failure ---
MAX_ATTEMPTS=3
ATTEMPT=1
VALIDATION_ERRORS=""
GENERATION_SUCCESS=false

# Store original prompt for retries
ORIGINAL_PROMPT="$FINAL_PROMPT"

while [[ $ATTEMPT -le $MAX_ATTEMPTS ]]; do
  bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  bold "Generation Attempt ${ATTEMPT} of ${MAX_ATTEMPTS}"
  bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo

  # Build prompt (add retry context if this is a retry)
  if [[ $ATTEMPT -gt 1 ]] && [[ -n "$VALIDATION_ERRORS" ]]; then
    RETRY_CONTEXT="$(format_errors_for_retry "$VALIDATION_ERRORS" "$ATTEMPT")"
    CURRENT_PROMPT="${ORIGINAL_PROMPT}${RETRY_CONTEXT}"
    warn "Adding ${#VALIDATION_ERRORS} validation errors to prompt for retry..."
  else
    CURRENT_PROMPT="$ORIGINAL_PROMPT"
  fi

  # Save prompt for this attempt
  PROMPT_INPUT_FILE="${RUN_DIR}/prompt_attempt_${ATTEMPT}_${TS}.md"
  printf "%s\n" "$CURRENT_PROMPT" > "$PROMPT_INPUT_FILE"

  info "Prompt saved to: ${PROMPT_INPUT_FILE}"
  info "Starting Claude Code (this may take several minutes)..."
  echo

  # Clean bundle directory for retry (keep .git and .hetzner-deployer)
  if [[ $ATTEMPT -gt 1 ]]; then
    info "Cleaning bundle directory for retry..."
    find "$BUNDLE_DIR" -mindepth 1 -maxdepth 1 \
      ! -name ".git" \
      ! -name ".hetzner-deployer" \
      -exec rm -rf {} \; 2>/dev/null || true
  fi

  # Run Claude with the prompt
  CLAUDE_OUTPUT_FILE="${RUN_DIR}/claude_output_attempt_${ATTEMPT}_${TS}.log"

  # Build Claude command arguments
  CLAUDE_ARGS=(
    --add-dir "$APP_REPO"
    --add-dir "$BUNDLE_DIR"
  )

  # Add --dangerously-skip-permissions only for non-interactive mode
  if [[ "$INTERACTIVE" != "true" ]]; then
    CLAUDE_ARGS+=(--dangerously-skip-permissions)
  fi

  if [[ -n "$MODEL" ]]; then
    CLAUDE_ARGS+=(--model "$MODEL")
    info "Using model: $MODEL"
  fi

  if [[ "$INTERACTIVE" == "true" ]]; then
    # Interactive mode: start Claude and tell user to paste the command
    info "Running in interactive mode - you can respond to prompts"
    warn "Note: In interactive mode, output capture is limited. Check the bundle directory for results."
    echo

    # Prepare the command for the user
    CLAUDE_INSTRUCTION="Read ${PROMPT_INPUT_FILE} and execute all instructions in it. Generate all required infrastructure files."

    # Try to copy to clipboard (macOS)
    if command -v pbcopy >/dev/null 2>&1; then
      echo "$CLAUDE_INSTRUCTION" | pbcopy
      success "Command copied to clipboard! Just paste (Cmd+V) when Claude starts."
    else
      info "When Claude starts, paste this command:"
      echo
      echo "  $CLAUDE_INSTRUCTION"
    fi
    echo
    bold "Starting Claude Code..."
    echo

    # Start Claude without a prompt - user will paste the instruction
    claude "${CLAUDE_ARGS[@]}"
    # After claude exits, capture what we can
    echo "Interactive session completed" > "$CLAUDE_OUTPUT_FILE"
  else
    # Non-interactive mode: use -p (print) flag with tee
    claude "${CLAUDE_ARGS[@]}" -p "$(cat "$PROMPT_INPUT_FILE")" 2>&1 | tee "$CLAUDE_OUTPUT_FILE"
  fi

  CLAUDE_EXIT_CODE=${PIPESTATUS[0]}
  if [[ $CLAUDE_EXIT_CODE -ne 0 ]]; then
    warn "Claude exited with code $CLAUDE_EXIT_CODE"
  fi

  # Symlink latest output
  ln -sf "$CLAUDE_OUTPUT_FILE" "${RUN_DIR}/claude_output_latest.log" 2>/dev/null || true

  echo
  bold "Validating generated bundle..."

  # Run validation (pass environments so it only checks relevant files)
  VALIDATION_ERRORS="$(validate_bundle_verbose "$BUNDLE_DIR" "$ENVIRONMENTS" 2>&1 | tee /dev/stderr | tail -n +1)"
  VALIDATION_ERRORS="$(validate_bundle "$BUNDLE_DIR" "$ENVIRONMENTS")"
  ERROR_COUNT="$(count_validation_errors "$VALIDATION_ERRORS")"

  if [[ "$ERROR_COUNT" -eq 0 ]]; then
    echo
    success "✓ Validation PASSED on attempt ${ATTEMPT}"
    GENERATION_SUCCESS=true
    break
  else
    echo
    warn "✗ Validation FAILED with ${ERROR_COUNT} error(s)"
    echo
    warn "Errors:"
    echo "$VALIDATION_ERRORS" | while read -r err; do
      [[ -n "$err" ]] && warn "  • $err"
    done

    if [[ $ATTEMPT -lt $MAX_ATTEMPTS ]]; then
      echo
      info "Will retry with errors fed back to Claude..."
      echo
    fi
  fi

  ATTEMPT=$((ATTEMPT + 1))
done

# Final status
echo
bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ "$GENERATION_SUCCESS" == "true" ]]; then
  success "GENERATION SUCCESSFUL after ${ATTEMPT} attempt(s)"
else
  warn "GENERATION FAILED after ${MAX_ATTEMPTS} attempts"
  warn "Manual intervention required. Check errors above."
  echo
  warn "You can:"
  warn "  1. Fix issues manually in: ${BUNDLE_DIR}"
  warn "  2. Run again with a modified prompt"
  warn "  3. Check Claude output logs in: ${RUN_DIR}"
fi
bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

# --- Post-generation: Update manifest with generated files ---
bold "Updating manifest with generated files..."

# Find all files in bundle (excluding .git and .hetzner-deployer internals except manifest.json)
GENERATED_FILES="$(find "$BUNDLE_DIR" -type f \
  ! -path "*/.git/*" \
  ! -path "*/.hetzner-deployer/history/*" \
  ! -path "*/.hetzner-deployer/prompt-version.md" \
  ! -name "*.bak" \
  ! -name "*.new" \
  ! -name "*.diff" \
  2>/dev/null || true)"

# Ensure manifest.json exists with basic structure
MANIFEST_PATH="$(get_manifest_path "$BUNDLE_DIR")"
if [[ ! -f "$MANIFEST_PATH" ]]; then
  PROMPT_HASH="$(compute_prompt_hash "$PROMPT_FILE")"
  APP_COMMIT="$(get_app_repo_commit "$APP_REPO")"
  create_manifest_json "$BUNDLE_DIR" "$PROMPT_HASH" "$APP_COMMIT" '{}' > "$MANIFEST_PATH"
fi

# Update manifest with each generated file
while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  REL_PATH="${file#$BUNDLE_DIR/}"
  update_manifest_file "$BUNDLE_DIR" "$REL_PATH" 2>/dev/null || true
done <<< "$GENERATED_FILES"

# Copy detected.json to manifest dir if it exists
if [[ -f "${BUNDLE_DIR}/config/detected.json" ]]; then
  save_detection_snapshot "$BUNDLE_DIR" "${BUNDLE_DIR}/config/detected.json"
fi

# Clean up old history (keep last 10)
cleanup_history "$BUNDLE_DIR" 10

success "Manifest updated successfully."
echo

# Save final validation report
VALIDATION_REPORT="${RUN_DIR}/validation_${TS}.txt"
{
  echo "Validation Report - ${TS}"
  echo "========================"
  echo ""
  echo "Attempts: ${ATTEMPT}"
  echo "Status: $([ "$GENERATION_SUCCESS" == "true" ] && echo "PASSED" || echo "FAILED")"
  echo ""
  if [[ -n "$VALIDATION_ERRORS" ]]; then
    echo "Final Errors:"
    echo "$VALIDATION_ERRORS"
  else
    echo "No errors."
  fi
} > "$VALIDATION_REPORT"

echo

# --- Generate update report if in update mode ---
if [[ "$MODE" == "update" ]]; then
  ANALYSIS="$(analyze_update_requirements "$BUNDLE_DIR" "$APP_REPO" "$PROMPT_FILE")"
  DETECTION_CHANGES='{"status": "regenerated"}'

  if [[ -f "${BUNDLE_DIR}/.hetzner-deployer/detected-snapshot.json" ]]; then
    OLD_DETECTION="${BUNDLE_DIR}/.hetzner-deployer/history/*/detected-snapshot.json"
    # Get most recent archived detection
    LATEST_ARCHIVE="$(find "${BUNDLE_DIR}/.hetzner-deployer/history" -name "detected-snapshot.json" 2>/dev/null | sort | tail -1 || true)"
    if [[ -n "$LATEST_ARCHIVE" ]]; then
      DETECTION_CHANGES="$(compare_detections "$LATEST_ARCHIVE" "${BUNDLE_DIR}/.hetzner-deployer/detected-snapshot.json")"
    fi
  fi

  REPORT_PATH="$(generate_update_report "$BUNDLE_DIR" "$ANALYSIS" "$DETECTION_CHANGES")"
  success "Update report generated: $REPORT_PATH"
fi

echo
bold "Next steps (recommended):"

if [[ "$MODE" == "new" ]]; then
  cat <<EOF
1) Review generated bundle in:
   ${BUNDLE_DIR}

2) Commit the infra bundle repo:
   cd "${BUNDLE_DIR}"
   git add -A
   git commit -m "Initial Hetzner infra bundle for ${APP_BASENAME}"

3) Create a remote repo for this bundle (GitHub), then push:
   git remote add origin <YOUR_INFRA_REPO_GIT_URL>
   git push -u origin main

4) Follow bundle/README.md to:
   - copy deploy workflows into APP_REPO
   - set GitHub secrets (including INFRA_REPO_GIT_URL)
   - configure Hetzner tokens, DNS zone, and object storage
EOF
else
  cat <<EOF
1) Review changes in:
   ${BUNDLE_DIR}

2) Check for .new files that need manual merging:
   find "${BUNDLE_DIR}" -name "*.new" -type f

3) Review the update report:
   ${BUNDLE_DIR}/UPDATE_REPORT.md

4) After reviewing and merging, commit changes:
   cd "${BUNDLE_DIR}"
   git add -A
   git commit -m "chore(infra): update bundle for ${APP_BASENAME}"
   git push
EOF
fi
