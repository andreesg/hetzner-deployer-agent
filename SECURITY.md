# Security Policy

## Scope

This project generates infrastructure code that will manage servers, credentials, and deployments. Security matters.

### What Counts as a Security Issue

- Vulnerabilities in generated Terraform/scripts that could expose credentials
- Flaws that could allow unauthorized access to deployed infrastructure
- Issues where secrets might be committed to git
- Bugs in the runner that could execute unintended commands
- SOPS/age encryption weaknesses in generated bundles

### What Does NOT Count as a Security Issue

- Bugs in detection logic (those are regular bugs)
- Missing features
- Documentation errors
- Hetzner Cloud vulnerabilities (report those to Hetzner)

## Reporting a Vulnerability

**Do not open a public issue for security vulnerabilities.**

Instead, email the maintainer directly or use GitHub's private vulnerability reporting feature if available.

Include:
1. Description of the vulnerability
2. Steps to reproduce
3. Potential impact
4. Suggested fix (if you have one)

You should receive a response within 48 hours. If the vulnerability is confirmed, we will:
1. Work on a fix
2. Credit you in the release notes (unless you prefer anonymity)
3. Release a patched version

## Security Considerations for Users

When using this tool, remember:

1. **Review generated code** — Don't blindly deploy AI-generated infrastructure
2. **Protect your secrets** — Use GitHub Secrets, not committed files
3. **Limit SSH access** — Configure allowed CIDRs in the generated Terraform
4. **Rotate credentials** — Especially Hetzner API tokens and database passwords
5. **Check audit logs** — Review `runs/` directory for what was generated

## Supported Versions

Only the latest version on `main` receives security updates. There are no LTS versions.
