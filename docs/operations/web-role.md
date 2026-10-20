# Web role: a preview node against the production database

Operator runbook for the switch-over that core task `01a155a6` makes
possible: a preview node (the "exp" node) that serves a branch against
**prod's** database on its own public hostname, behind prod's OIDC, without
a second TaskRouter, scheduler, sweeper or migration. The code side (the
`:web` role, the boot gate, the cluster bridge, the peer reads) is described
in `Platform.Role` and its submodules. This page covers what an operator
changes outside core.

Install-specific values (hostnames, hosts, paths, the OIDC client's name)
are deliberately absent: an open-source checkout carries no install
identity (`test/platform/regression/install_identity_guard_test.exs`).
They live in the install's ops repository. Placeholders below are written
`<like this>`. Every secret is named by its variable only.

| Placeholder | Meaning |
|---|---|
| `<web host>` | the exp node's public hostname, e.g. a sibling of prod's `PHX_HOST` |
| `<prod container>` | prod's platform container name |
| `<prod db container>` | prod's Postgres container name |
| `<exp container>` | the exp node's container name |
| `<prod database>` | the database in prod's `DATABASE_URL` |
| `<exp port>` | the host port the exp container publishes |

## What a web node is, and what it trusts

* It runs `PLATFORM_ROLE=web`: only the children in `Platform.Role`'s
  `@web` list start. No TaskRouter, AttentionRouter, scheduler, sweeper,
  purger or seed. `Platform.Role.effects/0` and `node_local/0` list every
  side effect and every node-local read, with where each one fires.
* It runs `MIX_ENV=prod`. `Platform.Role.validate!/2` refuses the web role in
  any other environment, because a dev build compiles `/dev/login` (sign in
  as anyone) and the debug error pages. That is what makes public exposure
  behind prod's OIDC acceptable.
* It never migrates. `Platform.Role.BootGate` refuses to boot when the
  database lacks one of the branch's migrations, and lists them. A branch
  that needs schema ships its expand-only migration to main first.
* It joins prod's BEAM over distributed Erlang (`PLATFORM_CLUSTER_PEER`),
  so PubSub, Presence and the telemetry relay reach prod's background
  consumers once.

**Trust (stage 3 architecture review): the exp node is exactly as trusted as
prod code.** The shared Erlang cookie lets code on the exp node run
arbitrary code inside prod's BEAM, which holds prod's superuser database
connection and every prod secret. The DML-only `burrow_web` role below does
not bound this: a branch that wants DDL can call prod's `Repo` over the
cluster. Only deploy a branch to exp that you would merge to main.

## 1. The exp entrypoint (ops repository)

The ops repository's exp entrypoint script (`exp-entrypoint.sh`, run inside
the Elixir container against a source checkout mounted at `/app`) gains one
block. Under `PLATFORM_ROLE=web` it:

* refuses to start unless `MIX_ENV=prod` and `RELEASE_COOKIE` is set;
* builds prod assets (`mix assets.deploy`) instead of the dev build;
* writes `~/.erlang.cookie` from `RELEASE_COOKIE`, mode 400, so the cookie
  is never on a command line and never visible in `ps`;
* skips `mix ecto.create` and `mix ecto.migrate`;
* `exec`s `elixir --sname platform_exp -S mix phx.server`, which in prod has
  no code reloader and no asset watchers. The script's dev
  `exec mix phx.server` (code reloader, watchers) is never reached under the
  web role.

The dev branch-preview path (no `PLATFORM_ROLE`) is unchanged.

```diff
--- a/exp-entrypoint.sh
+++ b/exp-entrypoint.sh
@@ -32,10 +32,50 @@
 fi
 
 # --- elixir deps -----------------------------------------------------------
-log "mix deps.get / deps.compile"
+# MIX_ENV comes from the env file: dev for the branch-preview lane, prod under
+# PLATFORM_ROLE=web (below).
+log "mix deps.get / deps.compile (MIX_ENV=${MIX_ENV:-dev})"
 mix deps.get
 mix deps.compile
 
+# --- web role (core task 01a155a6) -----------------------------------------
+# PLATFORM_ROLE=web serves a branch against PROD's database. It must run
+# MIX_ENV=prod (Platform.Role.validate!/2 refuses anything else: dev compiles
+# /dev/login and the debug pages, and this lane is public behind prod's OIDC),
+# it never migrates (Platform.Role.BootGate refuses to boot on an unapplied
+# migration instead), and it joins prod's node over distributed Erlang.
+if [ "${PLATFORM_ROLE:-full}" = "web" ]; then
+    if [ "${MIX_ENV:-}" != "prod" ]; then
+        log "PLATFORM_ROLE=web requires MIX_ENV=prod; refusing to start"
+        exit 1
+    fi
+    if [ -z "${RELEASE_COOKIE:-}" ]; then
+        log "PLATFORM_ROLE=web needs RELEASE_COOKIE (the cookie of PLATFORM_CLUSTER_PEER); refusing to start"
+        exit 1
+    fi
+
+    log "npm install (assets)"
+    (cd assets && npm install --silent --no-audit --no-fund)
+    log "mix assets.deploy (MIX_ENV=prod)"
+    mix assets.setup
+    mix assets.deploy
+
+    # The cookie goes in a file, not on the command line, so it is not
+    # visible in `ps` on the host.
+    umask 077
+    rm -f "$HOME/.erlang.cookie"
+    printf '%s' "$RELEASE_COOKIE" > "$HOME/.erlang.cookie"
+    chmod 400 "$HOME/.erlang.cookie"
+
+    log "MIX_ENV=prod mix compile"
+    mix compile
+
+    # No ecto.create / ecto.migrate: the database is prod's and the web
+    # role's DB user cannot run DDL.
+    log "starting web node platform_exp (MIX_ENV=prod) on 0.0.0.0:${PORT:-4000}"
+    exec elixir --sname platform_exp -S mix phx.server
+fi
+
 # --- assets ----------------------------------------------------------------
 # Without these three steps priv/static/assets/app.js never gets written and
 # /assets/js/app.js 404s — LiveView then fails silently in the browser.
```

It ships as an ops-repository PR, then is copied to the host that runs the
exp container.

## 2. The `burrow_web` database role

If prod's application role is a superuser, the exp node must not share it.
Run as prod's application role against `<prod database>` in
`<prod db container>`. Pass the password as a psql variable you hold; do not
type it into a shell history.

```sql
-- psql -v web_password="..." -v dbname=<prod database> ...
CREATE ROLE burrow_web LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT
  PASSWORD :'web_password';

GRANT CONNECT ON DATABASE :"dbname" TO burrow_web;
GRANT USAGE ON SCHEMA public TO burrow_web;
-- No CREATE on schema public: the web role never runs DDL.
REVOKE CREATE ON SCHEMA public FROM burrow_web;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO burrow_web;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO burrow_web;

-- Tables and sequences prod's migrations create later are granted the same
-- way automatically. Replace core_platform with the role prod migrates as.
ALTER DEFAULT PRIVILEGES FOR ROLE core_platform IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO burrow_web;
ALTER DEFAULT PRIVILEGES FOR ROLE core_platform IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO burrow_web;
```

Checks:

```sql
SELECT has_table_privilege('burrow_web', 'schema_migrations', 'SELECT');  -- t
SELECT has_schema_privilege('burrow_web', 'public', 'CREATE');            -- f
SELECT rolsuper FROM pg_roles WHERE rolname = 'burrow_web';               -- f
```

If the CREATE check reads `t`, the privilege comes from `PUBLIC` (Postgres
before 15 grants it by default), and `REVOKE CREATE ON SCHEMA public FROM
PUBLIC` is a change to prod's database for every role: decide it, do not
run it as part of this step.

All of core's tables are in `public` (no migration creates another schema).
`Platform.Role.BootGate` reads `schema_migrations` with
`skip_table_creation: true, migration_lock: false`, so the gate itself needs
only SELECT.

## 3. Containers (quadlets)

### Prod

* `HostName=<prod container>`, so the release's node is
  `platform@<prod container>` and the exp node can name it. A release
  without `rel/env.sh.eex` runs `-sname platform`, so `platform@<hostname>`.
* `RELEASE_COOKIE` in prod's secrets file, unique to this install and shared
  only with its exp node. Until it is pinned the cookie is the one baked into
  each image build, so this needs one prod restart.
* Prod's chat-uploads volume switches from `:Z` to `:z`. The exp node mounts
  the same directory, and a second container mounting it with `:Z` relabels
  it private to itself, cutting prod off. Both mounts use the shared label.

### Exp

* `ContainerName=<exp container>` and `HostName=<exp container>`, so prod
  resolves the node's host on the network.
* The image matches prod's Elixir/OTP (`apps/platform/Dockerfile`:
  `elixir:1.20.4-otp-28`).
* `Network=` prod's network, so the exp node reaches `<prod db container>`
  and `<prod container>`. No separate exp Postgres.
* Prod's chat-uploads directory mounted with `:z` and without `:U` (prod
  owns it).
* Env files: prod's env file and prod's secrets file first, then the web
  overrides, then the exp secrets. podman applies `--env-file` in order and
  a later file wins. Any variable prod's quadlet sets with `Environment=`
  rather than a file (for example `FILES_SERVICE_URL`) is set the same way
  on exp.

Web overrides (non-secret):

| Variable | Value |
|---|---|
| `MIX_ENV` | `prod` |
| `PLATFORM_ROLE` | `web` |
| `PLATFORM_CLUSTER_PEER` | `platform@<prod container>` |
| `PHX_HOST` | `<web host>` |
| `APP_URL` | `https://<web host>` |
| `PORT` | `4000` |
| `DNS_CLUSTER_QUERY` | empty: `PeerLink` is the only clustering |
| `DEPLOY_SKIP_NOTICE_SPACE_ID` | empty: prod posts those notices |

Exp secrets: `DATABASE_URL` pointing at `<prod db container>` as
`burrow_web`.

Inherited from prod's files, by name, and required to be prod's own values:
`SECRET_KEY_BASE`, `SESSION_COOKIE_DOMAIN` (so prod's `_platform_session`
cookie verifies on exp), `ATTACHMENT_SIGNING_KEY`,
`MEETING_GUEST_SIGNING_KEY`, `MEETING_CALENDAR_SIGNING_KEY`,
`VAULT_MASTER_KEY` (the boot gate decrypts a credential row with it),
`VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, `LIVEKIT_URL`, `LIVEKIT_API_KEY`,
`LIVEKIT_API_SECRET`, `FILES_SERVICE_URL`, `FILES_SERVICE_TOKEN`,
`MEMORY_SERVICE_URL`, `MEMORY_SERVICE_API_KEY`, `OIDC_ISSUER`,
`OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET`, `OIDC_PKCE_ENABLED`,
`EXTRA_ORIGIN_APEXES`, `CHAT_ATTACHMENTS_ROOT`, `RELEASE_COOKIE`. APNs
credentials are read from the shared database. Request-path effects on exp
(an inbox push, a LiveKit room, a file extraction) fire from exp with these,
once; see `Platform.Role.effects/0`.

Check names, never values:

```sh
podman exec <exp container> sh -c 'printenv | cut -d= -f1 | sort'
podman exec <exp container> sh -c 'test "$PLATFORM_ROLE" = web && test "$MIX_ENV" = prod && echo ROLE_OK'
```

## 4. Hostname, ingress and OIDC

**Hostname.** `<web host>`, as `PHX_HOST` above. `check_origin` allows
`https://<web host>` from `PHX_HOST` alone.

**Ingress.** Public, the same way prod's own hostname is served: a router on
the reverse proxy that fronts prod, matching `Host(<web host>)`, forwarding
to `<exp port>` on the host that runs the exp container, with TLS from the
certificate that already covers prod's apex, and a DNS record matching
prod's. No IP allowlist or LAN-only gate: that gate existed for the old dev
lane because it ran `MIX_ENV=dev`. The web role cannot
(`Platform.Role.validate!/2`), so `/dev/login` and the debug pages are not
compiled in.

**OIDC.** The exp node signs in through prod's provider and prod's client
(`OIDC_ISSUER`, `OIDC_CLIENT_ID`, inherited above). Core builds the redirect
URI from `APP_URL` (`Platform.OIDC.callback_url/0`), so one callback URL is
added to that client's allowed list:

```
https://<web host>/auth/oidc/callback
```

## 5. The Done-when check: 30 idle minutes, zero writes

Before exp boots, as prod's superuser role:

```sql
SHOW log_statement;                              -- expect: none (global)
ALTER ROLE burrow_web SET log_statement = 'mod';
```

With the global setting `none`, only `burrow_web` sessions log, so any
`statement: INSERT`, `UPDATE`, `DELETE` (or DDL) line in the Postgres log
during the window is the exp node's. Boot exp, sign in once to confirm it
serves, close every browser tab, then leave it idle for 30 minutes:

```sh
podman logs --since 30m <prod db container> 2>&1 \
  | grep -E 'statement: (INSERT|UPDATE|DELETE|CREATE|ALTER|DROP|TRUNCATE)' \
  | wc -l
# expect 0
```

`runtime_events` has no origin-node column, so a row count there cannot
tell exp's writes from prod's; the role-scoped statement log can. Turn the
logging off afterwards:

```sql
ALTER ROLE burrow_web RESET log_statement;
```

Also confirm, over the cluster from prod, that no background child runs on
the exp node: `Process.whereis/1` is nil there for
`Platform.Orchestration.TaskRouterWatcher`, `Platform.Chat.AttentionRouter`,
`Platform.Agents.SystemEventScheduler`, `Platform.Responsibilities.Router`,
`Platform.Mail.Outbox` and `Platform.Memory.Insights.Disseminator`.
