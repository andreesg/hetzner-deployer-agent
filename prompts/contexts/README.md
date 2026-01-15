# Project Context Files

This directory contains project-specific context files that can be used when regenerating or updating infrastructure bundles.

## Purpose

When running the agent to update an existing bundle, you can provide additional context about the project to help the agent make better decisions. These files capture:

- Project-specific deployment requirements
- Known issues and their solutions
- Schema/model details
- Environment variable documentation

## Usage

When updating a bundle, include the relevant context file in your prompt:

```bash
# Example: Include context when updating bulir-booking-system bundle
./run/run_hetzner_deployer_agent.sh \
  --update /path/to/bulir-booking-system_infra \
  --app-repo /path/to/bulir-booking-system \
  --context prompts/contexts/bulir-booking-system.md
```

Or manually paste the relevant sections into your conversation with the agent.

## Available Contexts

| File | Project | Description |
|------|---------|-------------|
| `bulir-booking-system.md` | Bulir Booking System | Property booking platform with FastAPI backend, React frontend |

## Creating New Contexts

When deploying a new project and encountering issues, document them in a context file following this structure:

1. Project overview and tech stack
2. Critical deployment requirements
3. Backend/frontend structure
4. Known issues and fixes
5. Environment variables
6. Troubleshooting commands
