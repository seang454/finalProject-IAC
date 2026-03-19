# PostgreSQL User Types & Privileges

## Overview

PostgreSQL controls access through **users** (also called roles). Each user has a different set
of privileges depending on what they need to do. There are 5 common types used in production.

---

## 1. Superuser

```sql
CREATE USER name WITH SUPERUSER PASSWORD 'password';
```

The most powerful user — bypasses **all** permission checks in the database.

**Can do:**
- Create, drop, modify any database
- Create, drop, modify any user
- Read any table in any database
- Change server configuration (`ALTER SYSTEM`)
- See encrypted passwords (`pg_shadow`)
- Grant any privilege to anyone
- Bypass Row Level Security (RLS)

**Cannot do:**
- Nothing — superuser has no restrictions

**Use case:** DBA maintenance and emergency access only. Never use this user
in your application code. If this password leaks, an attacker has full control
of your entire database server.

**In your cluster:** `postgres` / password: `SecurePostgresPassword123!`

---

## 2. Admin / Power User

```sql
CREATE USER name WITH CREATEDB CREATEROLE LOGIN PASSWORD 'password';
```

Can manage databases and users but **cannot** bypass system-level restrictions.

**Can do:**
- Create and drop databases
- Create and drop other users
- Grant privileges on objects they own
- Read/write data (if explicitly granted on specific tables)

**Cannot do:**
- See system passwords (`pg_shadow`)
- Change server configuration (`ALTER SYSTEM`)
- Access databases they don't own
- Drop users with more privileges than themselves

**Use case:** Team leads or deployment scripts that need to set up databases
and users but should not have full superuser access. Use this for CI/CD
pipelines that run database migrations.

**In your cluster:** `admin` / password: `SecureAdminPassword123!`

---

## 3. Application User

```sql
CREATE USER name WITH LOGIN PASSWORD 'password';
GRANT CONNECT ON DATABASE mydb TO name;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO name;
```

A regular user with only the specific permissions your application needs.

**Can do:**
- Only what you explicitly `GRANT` them
- Read/write specific tables
- Call specific functions

**Cannot do:**
- Create databases or users
- Access tables they were not granted
- See other users' data
- Modify any schema or structure

**Use case:** Your application backend. This is the user your Node.js, Python,
or Java app connects with. If this password leaks, the attacker can only access
your app's data — nothing else in the database is exposed.

**In your cluster:** Not created yet. Create one per application:

```sql
CREATE USER appuser WITH LOGIN PASSWORD 'AppPassword123!';
GRANT CONNECT ON DATABASE mydb TO appuser;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO appuser;
```

---

## 4. Read-Only User

```sql
CREATE USER name WITH LOGIN PASSWORD 'password';
GRANT CONNECT ON DATABASE mydb TO name;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO name;
```

Can only read data — never write.

**Can do:**
- `SELECT` from tables they are granted access to
- Run reports and queries
- Connect to the database

**Cannot do:**
- `INSERT`, `UPDATE`, `DELETE`
- Create any database objects
- Modify any data or schema

**Use case:** Reporting tools, dashboards, data analysts, and BI tools like
Metabase or Grafana. Give this to anyone who needs to query data but should
never be able to modify it.

**In your cluster:** Not created yet. Create one like this:

```sql
CREATE USER readonly WITH LOGIN PASSWORD 'ReadOnly123!';
GRANT CONNECT ON DATABASE mydb TO readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO readonly;
```

---

## 5. Replication User

```sql
CREATE USER name WITH REPLICATION LOGIN PASSWORD 'password';
```

A special-purpose user that can only open replication connections.
Cannot interact with data at all.

**Can do:**
- Stream WAL (Write Ahead Log) data between cluster nodes
- Open and use replication slots

**Cannot do:**
- `SELECT`, `INSERT`, `UPDATE`, `DELETE`
- Create databases or users
- Login to a normal database session
- Read any table data

**Use case:** Used internally between pg-node1, pg-node2, and pg-node3 to keep
data in sync. Patroni configures this automatically. You never use this user
from your application.

**In your cluster:** `replicator` / password: `SecureReplicatorPassword123!`

---

## Privilege Comparison Table

| Privilege | superuser | admin | application | read-only | replication |
|-----------|:---------:|:-----:|:-----------:|:---------:|:-----------:|
| Login | ✅ | ✅ | ✅ | ✅ | ✅ |
| Read data | ✅ | ✅ | ✅ granted only | ✅ granted only | ❌ |
| Write data | ✅ | ✅ | ✅ granted only | ❌ | ❌ |
| Create database | ✅ | ✅ | ❌ | ❌ | ❌ |
| Create users | ✅ | ✅ | ❌ | ❌ | ❌ |
| Change server config | ✅ | ❌ | ❌ | ❌ | ❌ |
| See all passwords | ✅ | ❌ | ❌ | ❌ | ❌ |
| Stream replication | ✅ | ❌ | ❌ | ❌ | ✅ |
| Bypass Row Level Security | ✅ | ❌ | ❌ | ❌ | ❌ |

---

## Users in Your Cluster

| User | Type | Password | Status |
|------|------|----------|--------|
| `postgres` | Superuser | `SecurePostgresPassword123!` | ✅ exists |
| `admin` | Admin | `SecureAdminPassword123!` | ✅ exists |
| `replicator` | Replication | `SecureReplicatorPassword123!` | ✅ exists |
| `appuser` | Application | set by you | ❌ not created |
| `readonly` | Read-only | set by you | ❌ not created |

---

## How to Connect as Each User

```bash
# Superuser — full access
psql -h 34.13.12.181 -p 5000 -U postgres -d postgres

# Admin — manage databases and users
psql -h 34.13.12.181 -p 5000 -U admin -d postgres

# Application user — read/write your app data only
psql -h 34.13.12.181 -p 5000 -U appuser -d mydb

# Read-only — reports and queries only
psql -h 34.13.12.181 -p 5001 -U readonly -d mydb

# Replication — used internally by Patroni, not for manual login
# (cannot connect to a normal database session)
```

> **Tip:** The prompt tells you who you are connected as:
> - `postgres=#` — the `#` means superuser
> - `postgres=>` — the `>` means regular user

---

## How to Check Existing Users

```sql
-- List all users and their attributes
\du

-- Or query the system table directly
SELECT usename, usesuper, usecreatedb, usecreaterole, userepl
FROM pg_user;
```

---

## Best Practice — Least Privilege

Always give each user the **minimum privileges they need** and nothing more:

```
Patroni internals  →  replicator  (replication only)
Database setup     →  admin       (createdb, createrole)
Your application   →  appuser     (select, insert, update, delete on specific tables)
Reporting/BI tool  →  readonly    (select only)
Emergency/DBA      →  postgres    (superuser — use rarely)
```

Never connect your application with the `postgres` superuser. If the app is
compromised, the attacker gets superuser access to your entire database server.