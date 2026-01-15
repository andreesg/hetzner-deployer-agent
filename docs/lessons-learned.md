# LESSONS LEARNED ADDENDUM
# This addendum contains critical fixes derived from real-world deployment issues.
# MUST be applied to HETZNER_DEPLOYER_PROMPT.md to prevent common failures.

---

## CRITICAL FIX 1: Server Type Naming (Case Sensitivity)

**Problem:** Hetzner server types are LOWERCASE. Using `CX32` causes "server type not found" errors.

**Fix required in prompt:**

Replace ALL server type references:
- `CX22` → `cx22`
- `CX32` → `cx32`
- `CX42` → `cx42`

**Update the defaults table:**

| Environment | VPS Type | vCPU | RAM | Volume |
|-------------|----------|------|-----|--------|
| dev | cx22 | 2 | 4GB | 20GB |
| staging | cx22 | 2 | 4GB | 20GB |
| prod | cx32 | 4 | 8GB | 40GB |

---

## CRITICAL FIX 2: Docker Platform Architecture

**Problem:** Images built on Apple Silicon (ARM64) fail on Hetzner servers (AMD64).

**Add this new section to the prompt:**

```markdown
## DOCKER BUILD REQUIREMENTS (MANDATORY)

Hetzner Cloud servers run AMD64 architecture. ALL Docker build commands MUST specify the platform explicitly.

### In CI/CD workflows:
```yaml
- name: Build backend
  run: docker build --platform linux/amd64 -f docker/backend/Dockerfile -t $IMAGE .
```

### In deploy scripts:
```bash
docker build --platform linux/amd64 -f docker/backend/Dockerfile -t $IMAGE .
```

### In docker-compose.yml for local builds:
```yaml
services:
  backend:
    build:
      context: .
      dockerfile: docker/backend/Dockerfile
      platforms:
        - linux/amd64
```

This is NON-NEGOTIABLE. Omitting `--platform linux/amd64` causes "exec format error" failures.
```

---

## CRITICAL FIX 3: Migration Validation Infrastructure

**Problem:** Schema mismatches between SQLAlchemy models and Alembic migrations cause production failures.

**Add this new section to the prompt:**

```markdown
## PRE-DEPLOYMENT VALIDATION (MANDATORY)

The bundle MUST include infrastructure for validating migrations BEFORE deployment.

### Required: docker-compose.dev.yml in APP_REPO

Generate a development compose file that includes:

1. **PostgreSQL service** for local testing
2. **Migration validation service** (profile: check)
3. **Test runner service** (profile: test)

Example structure:
```yaml
# docker-compose.dev.yml
services:
  postgres:
    image: postgres:15-alpine
    environment:
      POSTGRES_DB: app_db
      POSTGRES_USER: app_user
      POSTGRES_PASSWORD: dev_password
    ports:
      - "5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U app_user -d app_db"]
      interval: 5s
      timeout: 5s
      retries: 5

  migration-check:
    build:
      context: .
      dockerfile: docker/backend/Dockerfile
    environment:
      - DATABASE_URL=postgresql://app_user:dev_password@postgres:5432/app_db
    depends_on:
      postgres:
        condition: service_healthy
    command: |
      sh -c "
        alembic upgrade head &&
        python -c '
from alembic.config import Config
from alembic.script import ScriptDirectory
from alembic.runtime.migration import MigrationContext
from sqlalchemy import create_engine
import os

engine = create_engine(os.environ[\"DATABASE_URL\"])
with engine.connect() as conn:
    context = MigrationContext.configure(conn)
    current_rev = context.get_current_revision()

config = Config(\"alembic.ini\")
script = ScriptDirectory.from_config(config)
head_rev = script.get_current_head()

if current_rev == head_rev:
    print(f\"Schema is up to date (revision: {current_rev})\")
else:
    print(f\"ERROR: Schema mismatch! Current: {current_rev}, Head: {head_rev}\")
    exit(1)
'
      "
    profiles:
      - check

  test:
    build:
      context: .
      dockerfile: docker/backend/Dockerfile
    environment:
      - DATABASE_URL=postgresql://app_user:dev_password@postgres:5432/app_db_test
    depends_on:
      postgres:
        condition: service_healthy
    command: pytest -v --tb=short
    profiles:
      - test
```

### Required: pre-deploy-check.sh in INFRA_REPO

Generate a validation script at `deploy/scripts/pre-deploy-check.sh` that:
1. Validates migrations against PostgreSQL
2. Runs test suite
3. Builds Docker images with correct platform
4. Validates environment configuration
5. Scans for hardcoded secrets
```

---

## CRITICAL FIX 4: ALLOWED_HOSTS Format

**Problem:** JSON array environment variables get mangled by shell quoting.

**Add this documentation requirement:**

```markdown
## ENVIRONMENT VARIABLE FORMATS

### JSON Arrays in Environment Variables

When environment variables contain JSON arrays (like `ALLOWED_HOSTS`), document the exact format:

**In .env files:**
```bash
ALLOWED_HOSTS=["https://api.example.com","https://app.example.com"]
```

**In docker-compose.yml:**
```yaml
environment:
  - ALLOWED_HOSTS=["https://api.example.com","https://app.example.com"]
```

**NEVER use shell variable expansion with JSON arrays.** The quotes will be stripped.

### Common Variables Requiring JSON Format
- `ALLOWED_HOSTS` - List of allowed origins for CORS
- `CORS_ORIGINS` - Same as above in some frameworks
```

---

## CRITICAL FIX 5: Password Hash Shell Escaping

**Problem:** bcrypt password hashes contain `$` characters that shell escaping corrupts.

**Add to deploy scripts:**

```markdown
## USER CREATION IN CONTAINERS

When creating users or setting passwords programmatically, NEVER pass bcrypt hashes through shell variables.

**Wrong approach:**
```bash
HASH='$2b$12$...'
docker exec backend python -c "set_password('$HASH')"  # $ gets interpreted
```

**Correct approach:**
```bash
# Generate hash INSIDE the container
docker exec -it backend python -c "
from passlib.context import CryptContext
pwd_context = CryptContext(schemes=['bcrypt'])
hash = pwd_context.hash('your_password')
# Use hash directly in Python, don't export to shell
"
```
```

---

## CRITICAL FIX 6: Terraform Path Resolution

**Problem:** Relative paths in Terraform fail when running from envs/ subdirectories.

**Fix in generated Terraform:**

```markdown
## TERRAFORM PATH HANDLING

All file references in Terraform modules MUST use proper path resolution:

**Correct:**
```hcl
user_data = file("${path.module}/../../cloud-init/user-data.yaml")
```

**Wrong:**
```hcl
user_data = file("../cloud-init/user-data.yaml")  # Fails from envs/prod/
```

Always use `path.module` or `path.root` for file references.
```

---

## CRITICAL FIX 7: Container Naming Conflicts

**Problem:** Generic container names cause conflicts with other projects.

**Add to docker-compose.yml generation:**

```markdown
## CONTAINER NAMING

All containers MUST use project-specific prefixes to avoid conflicts:

```yaml
services:
  backend:
    container_name: ${PROJECT_NAME:-myapp}-backend
  postgres:
    container_name: ${PROJECT_NAME:-myapp}-postgres
```

Or set `name:` at the compose file level:
```yaml
name: myapp
services:
  backend:  # Will be named myapp-backend
```
```

---

## CRITICAL FIX 8: Alembic Model-Migration Consistency

**Problem:** Migrations hand-written or auto-generated don't match actual SQLAlchemy models.

**Add validation requirement:**

```markdown
## MIGRATION VALIDATION CHECKLIST

When detecting database schemas, the bundle MUST warn about potential mismatches:

1. **Detect column naming patterns:**
   - Models use `token_hash` but migration creates `token`
   - Models use `custom_config` but migration creates `theme`, `primary_color`

2. **Generate validation queries:**
   Add to migration-check service:
   ```python
   # Compare SQLAlchemy model columns to actual database columns
   from sqlalchemy import inspect
   inspector = inspect(engine)

   for table in Base.metadata.tables:
       model_cols = set(c.name for c in Base.metadata.tables[table].columns)
       db_cols = set(c['name'] for c in inspector.get_columns(table))

       if model_cols != db_cols:
           print(f"MISMATCH in {table}:")
           print(f"  Model has: {model_cols - db_cols}")
           print(f"  DB has: {db_cols - model_cols}")
   ```

3. **Document in runbooks:**
   Include specific commands for diagnosing schema drift.
```

---

## PROMPT MODIFICATIONS SUMMARY

Apply these changes to `HETZNER_DEPLOYER_PROMPT.md`:

1. **Line ~240-250:** Change server type defaults from uppercase to lowercase
2. **Line ~330-340:** Change capacity defaults table to lowercase server types
3. **After line ~390:** Add new "DOCKER BUILD REQUIREMENTS" section
4. **After line ~300:** Add new "PRE-DEPLOYMENT VALIDATION" section
5. **In DEFAULTS section (~443):** Update server types to lowercase
6. **In CI/CD section:** Ensure all docker build commands include `--platform linux/amd64`
7. **Add new section:** "ENVIRONMENT VARIABLE FORMATS"
8. **Add new section:** "USER CREATION IN CONTAINERS"

---

## CHECKLIST FOR AGENT VALIDATION

Before completing bundle generation, verify:

- [ ] All server types are lowercase (`cx22`, not `CX22`)
- [ ] All docker build commands include `--platform linux/amd64`
- [ ] docker-compose.dev.yml includes migration-check service
- [ ] pre-deploy-check.sh script is generated
- [ ] ALLOWED_HOSTS documentation shows correct JSON format
- [ ] Terraform file() references use path.module
- [ ] Container names include project prefix
- [ ] Runbooks include schema mismatch diagnosis commands
