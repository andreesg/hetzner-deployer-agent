# Contributing to Hetzner Deployer Agent

Thanks for considering a contribution. This document explains how to propose changes and what kinds of contributions are welcome.

## Project Philosophy

This project is **opinionated by design**. The goal is a single, well-tested path to production—not a configurable framework. Before proposing changes, understand what this project will and won't accept.

### What We Accept

- Bug fixes with clear reproduction steps
- Documentation improvements
- Better error messages and user feedback
- New language/framework detection (Node, Python, Go, etc.)
- Performance improvements to the runner
- Security hardening

### What We Reject

- **Alternative cloud providers** — This is Hetzner-only
- **Alternative orchestration** — No Kubernetes, Nomad, etc.
- **Alternative databases** — Postgres only (Redis may be added for caching)
- **Configuration options** for things that should be opinionated
- **Heavy dependencies** — No Node.js, Python runtimes, or complex tooling
- **CI/CD for this repo** — Bash scripts don't need CI
- **Vanity badges** — No "build passing" badges for a bash project

If you're unsure, open an issue to discuss before writing code.

## How to Propose Changes

### For Bug Fixes

1. Open an issue describing the bug
2. Include logs from `runs/<app>/<timestamp>/`
3. Describe your environment (OS, Hetzner region if applicable)
4. If you have a fix, open a PR referencing the issue

### For New Features

1. Open an issue first
2. Explain the use case and why it fits this project's philosophy
3. Wait for maintainer feedback before writing code
4. If approved, submit a PR

### For Documentation

Small fixes (typos, clarifications) can go directly to PR. Larger rewrites should be discussed in an issue first.

## Code Standards

### Bash Scripts

- Use `set -euo pipefail` at the top
- Quote all variables: `"$VAR"` not `$VAR`
- Use `[[ ]]` for conditionals, not `[ ]`
- Prefer long options: `--verbose` not `-v`
- Add comments for non-obvious logic
- Functions should be lowercase with underscores: `compute_file_hash`
- No external dependencies beyond standard Unix tools and `jq` (with fallbacks)

### Markdown

- Use ATX-style headers: `## Header` not `Header\n---`
- One sentence per line (for better diffs)
- Use fenced code blocks with language hints
- Tables should be readable in plain text

### Prompts

The AI prompt in `prompts/HETZNER_DEPLOYER_PROMPT.md` is versioned and sensitive. Changes to the prompt require:

1. Clear explanation of why the change is needed
2. Testing with at least 2-3 different app repos
3. Documentation of any behavioral changes
4. Backwards compatibility consideration (update mode must still work)

Prompt changes are high-risk and will be scrutinized carefully.

## Testing Changes Locally

There's no automated test suite. Testing is manual:

### Test the Runner

```bash
# Syntax check
bash -n run/run_hetzner_deployer_agent.sh
bash -n lib/manifest.sh
bash -n lib/diff.sh

# Help output
./run/run_hetzner_deployer_agent.sh --help
```

### Test Bundle Generation

```bash
# Create a test app (or use an existing project)
mkdir /tmp/test-app
cd /tmp/test-app
npm init -y
echo 'console.log("hello")' > index.js

# Generate a bundle
cd /path/to/hetzner-deployer-agent
./run/run_hetzner_deployer_agent.sh --new --app-repo /tmp/test-app
```

### Test Update Mode

```bash
# After generating a bundle, modify a file in it
echo "# custom" >> /path/to/bundle/README.md

# Run update
./run/run_hetzner_deployer_agent.sh --update /path/to/bundle --app-repo /tmp/test-app

# Check that your modification was preserved
# and a .new file was generated
```

## Pull Request Process

1. Fork the repo and create a branch from `main`
2. Make your changes
3. Test locally (see above)
4. Update documentation if needed
5. Submit PR with clear description

PRs should:
- Solve one problem
- Be small and focused
- Include context on why, not just what
- Not break backwards compatibility without discussion

## Commit Messages

Use clear, descriptive commit messages:

```
# Good
Add Python/Django detection to app scanner
Fix manifest hash computation on macOS
Update prompt to handle monorepos

# Bad
fix bug
update
wip
```

## Questions?

Open an issue with the "question" label. Don't be shy—asking questions helps improve documentation for everyone.

## Code of Conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). Be respectful and constructive.
