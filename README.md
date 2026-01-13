# Hetzner Deployer Agent (Universal Infra Bundle Generator)

This repo contains an opinionated **agent runner + prompt** that generates a **separate, app-specific infra repo**
(Terraform + cloud-init + docker-compose + deploy scripts + runbooks) to deploy **any application repo** onto
**Hetzner Cloud** in a production-grade way.

## Key principles

- **APP_REPO is read-only**: the agent scans it but never modifies it.
- The agent generates a **new infra bundle folder** *outside* the app repo.
- The infra bundle folder is initialized as its **own git repo** (your infra repo).
- CI/CD follows **Pattern A**:
  - GitHub Actions live in the **app repo** (added as new deploy workflows; no overwrites).
  - Deploy workflows **clone the infra repo** and run its deploy scripts.
- The agent produces an **audit trail** under `runs/<app>/<timestamp>/` including:
  - exact prompt sent
  - detected repo facts
  - Claude output log

## Quickstart

### Create a New Bundle (Interactive)

```bash
chmod +x run/run_hetzner_deployer_agent.sh
./run/run_hetzner_deployer_agent.sh
```

You'll be asked for:
- the application repo path (read-only scan)
- whether to create NEW bundle or UPDATE existing
- where to create the new infra bundle repo on your filesystem
- the bundle repo name (optional)

### Create a New Bundle (CLI)

```bash
./run/run_hetzner_deployer_agent.sh --new --app-repo /path/to/your/app
```

### Update an Existing Bundle

When your app changes or the prompt evolves, update your existing infra bundle:

```bash
# Preview what would change (dry-run)
./run/run_hetzner_deployer_agent.sh --update /path/to/bundle --app-repo /path/to/app --dry-run

# Perform the update (preserves your modifications)
./run/run_hetzner_deployer_agent.sh --update /path/to/bundle --app-repo /path/to/app

# Force overwrite user modifications (creates .bak backups)
./run/run_hetzner_deployer_agent.sh --update /path/to/bundle --app-repo /path/to/app --force

# Update only specific components
./run/run_hetzner_deployer_agent.sh --update /path/to/bundle --app-repo /path/to/app --only=ci,terraform
```

### After Generation

- review the generated infra repo
- commit and push it to GitHub
- follow `bundle/README.md` to install deploy workflows into the app repo and set secrets

### After Update

- check for `.new` files that need manual merging: `find /path/to/bundle -name "*.new"`
- review `UPDATE_REPORT.md` for a summary of changes
- merge `.new` files into your customized versions
- delete `.new` and `.diff` files after merging
- commit and push changes

## Requirements

- `claude` CLI installed and authenticated
- `git`
- (later, for applying infra) `terraform`

## Repository layout

- `run/` runner scripts
- `lib/` library functions (manifest, diff utilities)
- `prompts/` versioned prompt(s)
- `runs/` prompt run logs (audit trail)
- `templates/` examples and reusable snippets

## Update Mode Architecture

The update mode enables incremental, non-destructive updates to existing bundles.

### State Tracking

Each generated bundle contains a `.hetzner-deployer/` directory:

```
.hetzner-deployer/
├── manifest.json          # File hashes and metadata
├── prompt-version.md      # Prompt snapshot used
├── detected-snapshot.json # App detection at generation time
└── history/               # Previous generations for rollback
    └── 2024-01-15T10-30-00/
```

### Conflict Resolution

| Scenario | Default Behavior | With --force |
|----------|-----------------|--------------|
| File unchanged | Overwrite | Overwrite |
| File user-modified | Generate `.new` alongside | Backup as `.bak`, overwrite |

### Components

Use `--only` to update specific components:

| Component | Files Affected |
|-----------|----------------|
| `ci` | `ci/github-actions/workflows/*` |
| `terraform` | `infra/terraform/*` |
| `compose` | `deploy/compose/*` |
| `scripts` | `deploy/scripts/*` |
| `docs` | `docs/*`, `README.md` |
| `env` | `config/envs/*`, `secrets/*` |

