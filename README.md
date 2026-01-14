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
3. **You get a separate infra repo** — Review it, commit it, push it to GitHub
4. **CI/CD deploys to Hetzner** — GitHub Actions in your app repo trigger deploys via the infra repo

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

These are the defaults. The agent adapts based on what it detects in your app.

## What Gets Auto-Detected

The agent scans your app repo and adjusts the generated infrastructure:

| Detection | How It Adapts |
|-----------|---------------|
| **Language/Framework** | Python/FastAPI, Node/Express, Go, etc. → correct Dockerfile, build commands |
| **Database signals** | alembic, prisma, psycopg2 → wires Postgres with proper migrations |
| **Background workers** | Celery, Bull, Sidekiq → adds worker containers and Redis |
| **Existing Dockerfiles** | Reuses yours instead of generating new ones |
| **Capacity hints** | "MVP", "enterprise", worker counts → sizes VPS appropriately |

See `config/detected.json` in the generated bundle for exactly what was detected.

## Customization

While the stack choices are fixed, sizing and behavior are flexible:

**Via detection** (automatic):
- VPS type scales based on app complexity signals (CX22 → CX32 → CX42)
- Volume size adjusts based on storage hints
- Services added/removed based on dependencies (Redis, Celery, etc.)

**Via prompt modification** (advanced):
- Edit `prompts/HETZNER_DEPLOYER_PROMPT.md` to change defaults
- Adjust VPS types, Postgres tuning, or add new detection rules
- The prompt is the source of truth—version it with your changes

**Via generated bundle** (post-generation):
- The bundle is yours to customize after generation
- Modify Terraform, Compose files, or scripts as needed
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
# Create new bundle
./run/run_hetzner_deployer_agent.sh --new --app-repo /path/to/your/app

# Update existing bundle
./run/run_hetzner_deployer_agent.sh --update /path/to/bundle --app-repo /path/to/app

# Preview changes without modifying
./run/run_hetzner_deployer_agent.sh --update /path/to/bundle --app-repo /path/to/app --dry-run
```

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
- **Incremental updates** — When updating, user-modified files are preserved (generates `.new` files instead of overwriting)
- **No remote execution** — The agent runs locally; nothing is sent to Hetzner until you explicitly deploy

## Repository Layout

```
hetzner-deployer-agent/
├── run/                    # Runner script
├── lib/                    # Bash library functions
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
