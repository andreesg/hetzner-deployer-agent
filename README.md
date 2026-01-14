# Hetzner Deployer Agent

An AI-powered tool that scans your application repository and generates a complete, production-ready infrastructure bundle for deploying to Hetzner Cloud.

You give it your app repo. It gives you back a separate infra repo with Terraform, Docker Compose, deploy scripts, CI/CD workflows, and runbooks. Your app repo is never modified.

## What Problem This Solves

Setting up production infrastructure is tedious and error-prone. You need Terraform, Docker configs, deploy scripts, secrets management, backups, monitoring, and CI/CD—all wired together correctly.

This tool automates that entire process. Point it at any app repo, and it generates a complete infrastructure bundle tailored to your stack. The bundle is yours to own, customize, and version control separately from your application.

## What This Does NOT Solve

- **Multi-cloud deployments** — Hetzner Cloud only, by design
- **Kubernetes** — Uses Docker Compose for simplicity
- **Complex microservices architectures** — Optimized for monoliths and simple multi-service apps
- **Managed databases** — Uses containerized Postgres (Hetzner doesn't offer managed DB)
- **Zero-touch magic** — You still need to review, configure secrets, and understand what's deployed

This is not a PaaS. It's a DevOps automation tool for people who want to own their infrastructure.

## How It Works

```
┌─────────────────┐      ┌─────────────────┐      ┌─────────────────┐
│   YOUR APP      │      │  THIS AGENT     │      │  INFRA BUNDLE   │
│   (read-only)   │ ───► │  (scans + AI)   │ ───► │  (new git repo) │
└─────────────────┘      └─────────────────┘      └─────────────────┘
                                                          │
                                                          ▼
                                                  ┌─────────────────┐
                                                  │  HETZNER CLOUD  │
                                                  │  (your VPS)     │
                                                  └─────────────────┘
```

1. **Agent scans your app repo** — Detects language, framework, database needs, build commands
2. **AI generates infrastructure** — Terraform, Docker Compose, deploy scripts, CI/CD workflows
3. **Agent validates and self-corrects** — Checks output, retries with error feedback if needed (up to 3 attempts)
4. **You get a separate infra repo** — Review it, commit it, push it to GitHub
5. **CI/CD deploys to Hetzner** — GitHub Actions in your app repo trigger deploys via the infra repo

The agent never modifies your application code. It only reads.

## The Stack (Opinionated Defaults)

| Component | Choice |
|-----------|--------|
| Cloud | Hetzner Cloud |
| IaC | Terraform |
| Runtime | Docker + Docker Compose |
| Reverse Proxy | Caddy (auto TLS) |
| Database | PostgreSQL (containerized) |
| Secrets | SOPS + age |
| Registry | GitHub Container Registry |
| CI/CD | GitHub Actions |
| Monitoring | Prometheus + Grafana |
| Backups | restic to Hetzner Object Storage |

The infrastructure stack is fixed. What adapts is how the agent configures it based on your application's needs.

## What Gets Auto-Detected

The agent scans your app repo and tailors the Hetzner deployment to your application:

| What It Detects | What It Configures |
|-----------------|-------------------|
| **Language/Framework** | Dockerfile, build commands, runtime settings |
| **Database signals** (alembic, prisma, psycopg2) | Postgres wiring, migration commands |
| **Background workers** (Celery, Bull, Sidekiq) | Worker containers, Redis service |
| **Existing Dockerfiles** | Reuses yours instead of generating new ones |
| **Capacity hints** ("MVP", worker counts, etc.) | VPS size, volume size, Postgres tuning |

See `config/detected.json` in the generated bundle for exactly what was detected.

**Note**: Existing infrastructure configs in your app repo (Terraform for AWS, Kubernetes manifests, etc.) are ignored. This tool generates a fresh Hetzner-specific bundle—it doesn't migrate or adapt existing infra.

## Customization

The target (Hetzner Cloud) and stack (Docker, Postgres, Caddy) are fixed. What's flexible is sizing and application-specific configuration:

**Automatic (via detection)**:
- VPS size based on app complexity (CX22 for MVPs → CX32 for larger apps)
- Services included based on dependencies (Redis added if Celery detected)
- Migration commands based on framework (alembic, prisma, etc.)

**Manual (via prompt modification)**:
- Edit `prompts/HETZNER_DEPLOYER_PROMPT.md` to change default VPS sizes, Postgres tuning, or detection rules
- The prompt is the source of truth—version it with your changes

**Post-generation (edit the bundle)**:
- The generated bundle is yours to modify
- Terraform, Compose files, and scripts can all be customized
- Update mode preserves your changes (generates `.new` files instead of overwriting)

## Quickstart

### Prerequisites

- [Claude CLI](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated
- `git`

### Generate an Infra Bundle

```bash
# Clone this repo
git clone https://github.com/andreesg/hetzner-deployer-agent.git
cd hetzner-deployer-agent

# Make the runner executable
chmod +x run/run_hetzner_deployer_agent.sh

# Run interactively
./run/run_hetzner_deployer_agent.sh
```

You'll be prompted for:
- Path to your application repo
- Where to create the infra bundle
- Bundle name (optional)

### CLI Mode

```bash
# Create new bundle (autonomous mode - no prompts)
./run/run_hetzner_deployer_agent.sh --app-repo /path/to/your/app --output /path/to/infra-bundle

# Create with specific model (sonnet, opus, haiku)
./run/run_hetzner_deployer_agent.sh --model sonnet --app-repo /path/to/app --output /path/to/bundle

# Interactive mode (can respond to permission prompts)
./run/run_hetzner_deployer_agent.sh --interactive --app-repo /path/to/app --output /path/to/bundle

# Update existing bundle
./run/run_hetzner_deployer_agent.sh --update /path/to/bundle --app-repo /path/to/app

# Preview changes without modifying
./run/run_hetzner_deployer_agent.sh --update /path/to/bundle --app-repo /path/to/app --dry-run
```

**Flags:**
- `--app-repo` — Path to your application repository (required)
- `--output` — Where to create the infrastructure bundle
- `--model` — Claude model to use (default: your CLI default)
- `--interactive` — Run with permission prompts (copies instruction to clipboard)
- `--dry-run` — Preview update changes without modifying files
- `--force` — Overwrite user-modified files during update

### After Generation

1. Review the generated bundle
2. Commit and push the bundle to its own GitHub repo
3. Follow the bundle's `README.md` to:
   - Copy deploy workflows to your app repo
   - Set GitHub secrets
   - Configure Hetzner API tokens and DNS

## Safety Guarantees

- **App repo is read-only** — The agent scans but never writes to your application repository
- **No secrets committed** — Credentials go in `.env` files and GitHub Secrets, not in git
- **Audit trail** — Every run is logged under `runs/<app>/<timestamp>/` with the exact prompt and output
- **Self-validation** — Output is validated; errors are fed back to Claude for automatic correction (up to 3 attempts)
- **Incremental updates** — When updating, user-modified files are preserved (generates `.new` files instead of overwriting)
- **No remote execution** — The agent runs locally; nothing is sent to Hetzner until you explicitly deploy

## Repository Layout

```
hetzner-deployer-agent/
├── run/                    # Runner script
├── lib/                    # Bash libraries (manifest, diff, validation)
├── prompts/                # Versioned AI prompts
├── templates/              # Examples and templates
└── runs/                   # Audit logs (gitignored except .gitkeep)
```

## Generated Bundle Layout

```
your-infra-bundle/
├── config/                 # Detected app config, env templates
├── infra/terraform/        # Infrastructure as code
├── infra/cloud-init/       # VPS provisioning scripts
├── deploy/compose/         # Docker Compose files
├── deploy/scripts/         # Deployment automation
├── ci/github-actions/      # Workflow files to copy to app repo
├── secrets/                # SOPS-encrypted env files
├── docs/runbooks/          # Operational documentation
└── .hetzner-deployer/      # Manifest for update tracking
```

## Who Should Use This

**Good fit:**
- Solo founders deploying side projects
- Indie hackers who want proper infrastructure without the AWS bill
- Small teams (1-5 engineers) shipping MVPs
- Engineers who understand Docker and want to own their infra

**Not a good fit:**
- Teams requiring multi-region or multi-cloud
- Organizations with strict compliance requirements (SOC2, HIPAA)
- Apps that need Kubernetes-level orchestration
- People who want a managed PaaS experience

## Project Status

**Early stage / Experimental**

This project works, but expect rough edges. The core flow (scan → generate → deploy) is functional. Error handling and edge cases are still being improved.

Current limitations:
- Best support for Python, Node.js, Go, and JVM apps (other languages work with manual Dockerfile)
- Single-VPS per environment (no built-in load balancing yet)
- PostgreSQL only for primary database (Redis supported for caching/queues)
- Requires Claude CLI authentication

## Roadmap

Near-term:
- [ ] Better error messages when detection fails
- [ ] Load balancer support for horizontal scaling
- [ ] More framework detection (Rails, Laravel, Phoenix)
- [ ] MySQL/MariaDB as alternative to Postgres

Completed:
- [x] Auto-detection of language, framework, database
- [x] Capacity planning based on app signals
- [x] Update mode with user modification preservation
- [x] Redis support for Celery/Bull/caching
- [x] Post-generation validation
- [x] Self-correction loop (validate → retry with error feedback)

Not planned:
- Kubernetes support
- Multi-cloud providers
- GUI or web interface

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on proposing changes.

## Security

See [SECURITY.md](SECURITY.md) for how to report vulnerabilities.

## License

MIT License. See [LICENSE](LICENSE) for details.

---

Built for developers who want production infrastructure without the complexity.
