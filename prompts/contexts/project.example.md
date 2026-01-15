# [Project Name] - Agent Context

Use this template to create project-specific context files.
Copy to `<project-name>.md` and fill in your project details.

---

## PROJECT OVERVIEW

**Application:** [Your App Name]
**Purpose:** [Brief description]
**Tech Stack:**
- Backend: [e.g., Python 3.11, FastAPI]
- Frontend: [e.g., React 18, TypeScript]
- Database: [e.g., PostgreSQL 15]
- Cache/Queue: [e.g., Redis 7]

---

## CRITICAL DEPLOYMENT REQUIREMENTS

### 1. Platform Architecture
- **Hetzner servers are AMD64**
- ALL Docker builds MUST use `--platform linux/amd64`

### 2. [Add project-specific requirements]
- ...

---

## BACKEND STRUCTURE

```
backend/
├── app/
│   ├── main.py
│   ├── api/
│   ├── models/
│   └── ...
```

### Key Models and Their Columns

**users:**
- id, email, ...

---

## KNOWN ISSUES AND FIXES

### Issue 1: [Title]
**Symptom:** [What you see]
**Cause:** [Why it happens]
**Fix:** [How to fix it]

---

## ENVIRONMENT VARIABLES

### Backend Required Variables
```bash
DATABASE_URL=postgresql://user:pass@host:5432/db
SECRET_KEY=<your-secret>
# Add all required vars...
```

---

## AGENT INSTRUCTIONS

When generating or updating infrastructure:

1. [Specific instruction for this project]
2. [Another instruction]
3. ...
