# ADR 0006: Secure Credential Vault

## Status

Accepted

## Context

The platform needs a general-purpose mechanism for storing and managing secrets:
API keys for AI model providers, OAuth tokens for provider authentication, GitHub
PATs for CI/CD integrations, webhook signing secrets, SSH keys, and arbitrary
credentials that agents or automations need to communicate with external systems.

This is a cross-cutting concern. Agents need model provider credentials. Integrations
need PATs and API keys. Automations need webhook secrets. Every domain that touches
the outside world needs secrets — and they all need the same guarantees:

- Encrypted at rest
- Scoped access (not every agent sees every secret)
- Audited (who used what, when)
- Convenient to update (rotation should be trivial, not a ceremony)
- OAuth token lifecycle managed automatically

Today, credentials are scattered: environment variables, JSON files in a
`.credentials/` directory, provider-specific config in `openclaw.json` auth
profiles. The platform needs a single, encrypted, auditable path for all of them.

### Design constraints

1. **One path for all secrets**. No special-casing per credential type.
2. **Encryption at rest**. Application-level, not just disk-level.
3. **Scoped and grantable**. A credential belongs to a scope (platform, workspace,
   agent) and access can be explicitly granted to other entities.
4. **Audited**. Every access, mutation, and rotation is logged via the event stream
   (ADR 0005).
5. **Convenient**. Adding or rotating a credential should be a single action in the
   Control Center UI or a single function call in code.
6. **OAuth as a first-class flow**. Not bolted on — the vault owns the full OAuth2
   lifecycle including background token refresh.

## Decision

### New platform domain: `Platform.Vault`

Vault is a top-level platform domain alongside Accounts, Audit, and others defined
in ADR 0002. It is not nested under Agents or Integrations because it serves all
of them equally.

```
Platform.Vault
├── Credential       — Schema, CRUD, scoping
├── Encryption       — Cloak-based AES-256-GCM field encryption
├── Access           — Grants and permission checks
├── OAuth            — OAuth2 flow management and background refresh
└── AuditIntegration — Telemetry emission for vault events
```

### Credential types

The vault stores five credential types, all behind the same encrypted storage
mechanism:

| Type | Contents | Example |
|------|----------|---------|
| `api_key` | Single encrypted string | Anthropic API key, GitHub PAT |
| `oauth2` | Access token + refresh token + expiry + provider config | Codex OAuth, Claude Code OAuth |
| `token` | Bearer token or signing secret | Webhook HMAC secret |
| `keypair` | Public + private key pair | SSH deploy keys |
| `custom` | Arbitrary encrypted JSON | Multi-field integration configs |

All types use the same schema, same encryption, same access control. The `credential_type`
field determines how the decrypted payload is interpreted and what lifecycle behaviors
apply (e.g., `oauth2` credentials get automatic refresh).

### Scoping model

Every credential has a scope that determines its default visibility:

- **Platform-wide** (`scope_type: "platform"`) — available to any entity in the
  platform. Use for shared infrastructure credentials.
- **Workspace-scoped** (`scope_type: "workspace"`) — available within a specific
  workspace. Use for team-level credentials.
- **Agent-scoped** (`scope_type: "agent"`) — available only to a specific agent.
  Use for agent-specific provider keys.
- **Integration-scoped** (`scope_type: "integration"`) — tied to a specific
  integration connector.

Scope defines the default boundary. Explicit access grants can widen visibility
within the platform (never beyond it).

### Access grants

An access grant allows an entity outside the credential's scope to use it:

```elixir
# Agent "planner" needs the workspace-level GitHub PAT
Vault.Access.grant("github-pat", {:agent, planner_id}, permissions: [:use])
```

Permissions:
- `:use` — can decrypt and use the credential value
- `:read_metadata` — can see the credential exists, its type, provider, and
  expiry, but cannot decrypt the value

Access checks are enforced at `Vault.get/2` time. No grant, no decryption.

### Encryption strategy

- **Cloak + Cloak.Ecto** — standard Elixir field-level encryption
- **AES-256-GCM** — authenticated encryption (confidentiality + integrity)
- **Master key from environment** — `VAULT_MASTER_KEY` environment variable.
  In production, this is the only secret that must be managed externally (env var,
  KMS, or sealed secret).
- **Key rotation** — Cloak supports multiple encryption keys with a "current"
  marker. Old data is decryptable with old keys; new writes use the current key.
  A background migration task can re-encrypt all credentials under the new key.
- **Automatic redaction** — Cloak fields are excluded from `inspect/2`, Logger
  output, and error reports. Credentials never appear in logs.

### Data model

```sql
-- Core credential storage
CREATE TABLE vault_credentials (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id UUID REFERENCES workspaces(id),  -- null = platform-wide
  slug VARCHAR NOT NULL,                         -- programmatic reference
  name VARCHAR NOT NULL,                         -- human label
  credential_type VARCHAR NOT NULL,              -- api_key|oauth2|token|keypair|custom
  provider VARCHAR,                              -- anthropic|openai|github|etc.
  encrypted_data BYTEA NOT NULL,                 -- Cloak-encrypted payload
  metadata JSONB DEFAULT '{}',                   -- non-sensitive: scopes, hints
  scope_type VARCHAR NOT NULL,                   -- platform|workspace|agent|integration
  scope_id UUID,                                 -- null for platform scope
  expires_at TIMESTAMPTZ,
  last_used_at TIMESTAMPTZ,
  rotated_at TIMESTAMPTZ,
  inserted_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL,

  CONSTRAINT unique_slug_per_scope UNIQUE (workspace_id, scope_type, scope_id, slug)
);

-- Access grants
CREATE TABLE vault_access_grants (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  credential_id UUID NOT NULL REFERENCES vault_credentials(id) ON DELETE CASCADE,
  grantee_type VARCHAR NOT NULL,     -- agent|integration|automation
  grantee_id UUID NOT NULL,
  permissions JSONB NOT NULL,        -- ["use", "read_metadata"]
  granted_by UUID REFERENCES users(id),
  inserted_at TIMESTAMPTZ NOT NULL,

  CONSTRAINT unique_grant UNIQUE (credential_id, grantee_type, grantee_id)
);

-- Access log (append-only, ADR 0005 pattern)
CREATE TABLE vault_access_log (
  id BIGSERIAL PRIMARY KEY,
  credential_id UUID NOT NULL REFERENCES vault_credentials(id),
  accessor_type VARCHAR NOT NULL,
  accessor_id UUID NOT NULL,
  action VARCHAR NOT NULL,           -- use|read|create|update|rotate|revoke
  metadata JSONB DEFAULT '{}',
  inserted_at TIMESTAMPTZ NOT NULL
);
```

The `vault_access_log` follows the append-only, bigserial pattern from ADR 0005.
It is a specialized audit log for credential operations, complementing the general
audit event stream.

### API surface

The public API is intentionally simple — store, get, rotate, list:

```elixir
# Store a new credential
Vault.put("github-pat", :api_key, encrypted_value,
  provider: "github",
  scope: :platform,
  name: "GitHub PAT"
)

# Retrieve and decrypt (access-checked, audit-logged)
{:ok, decrypted} = Vault.get("github-pat", accessor: {:agent, agent_id})

# Rotate (atomic replace, all references stay valid)
:ok = Vault.rotate("github-pat", new_encrypted_value)

# List credentials (metadata only — never decrypts)
credentials = Vault.list(scope: {:workspace, workspace_id})

# Check what's expiring
expiring = Vault.expiring_soon(within: {7, :days})
```

`Vault.get/2` is the only function that decrypts. It always:
1. Checks access (scope + grants)
2. Decrypts the value
3. Updates `last_used_at`
4. Emits `[:platform, :vault, :credential_used]` telemetry
5. Writes to `vault_access_log`

If access is denied, it returns `{:error, :access_denied}` and logs the attempt.

### OAuth lifecycle

For `oauth2` credentials, the vault manages the full token lifecycle:

```elixir
# Initiate OAuth flow (returns redirect URL for the user)
{:ok, authorize_url} = Vault.OAuth.authorize_url("anthropic",
  callback_uri: callback,
  scopes: ["read", "write"]
)

# Complete the flow (exchanges code for tokens, stores encrypted)
{:ok, credential} = Vault.OAuth.handle_callback("anthropic", %{code: code})

# Background refresh — no caller action needed
# Vault.OAuth.RefreshWorker monitors all oauth2 credentials
# and refreshes tokens before expiry
```

`Vault.OAuth.RefreshWorker` is a supervised GenServer that:
- Periodically scans for `oauth2` credentials approaching expiry
- Refreshes tokens using the provider's refresh endpoint
- Stores the new tokens (encrypted)
- Emits telemetry on success and failure
- On persistent failure: emits an alert-level telemetry event

### Import paths

Three ways to populate the vault, all funneling through `Vault.put/4`:

1. **Control Center UI** — form with type picker, value input, scope selector,
   OAuth "Connect" buttons
2. **`.openclaw` import** — parses `auth.profiles` from `openclaw.json`, maps
   each profile to a vault credential. `mode: "token"` → `api_key` type,
   `mode: "oauth"` → `oauth2` type. Actual secrets must be provided during
   import (the config file stores mode, not values).
3. **`.credentials/` directory import** — reads JSON credential files and stores
   each as a `custom` type credential with the full JSON payload encrypted.

### Telemetry events

All vault operations emit telemetry following ADR 0005 conventions:

```
[:platform, :vault, :credential_created]
[:platform, :vault, :credential_used]
[:platform, :vault, :credential_rotated]
[:platform, :vault, :credential_revoked]
[:platform, :vault, :access_granted]
[:platform, :vault, :access_denied]
[:platform, :vault, :oauth_refreshed]
[:platform, :vault, :oauth_refresh_failed]
```

These feed into both the general audit event stream and the vault-specific
`vault_access_log`.

## Consequences

- Every domain that needs external credentials uses `Vault.get/2`. No other path
  for secret access exists.
- The `VAULT_MASTER_KEY` environment variable is the single external secret the
  platform requires. All other secrets are encrypted under it.
- OAuth token refresh is automatic and invisible to consumers. Code that calls
  `Vault.get("anthropic-oauth", ...)` always gets a valid token.
- Credential rotation is a single call. No downstream changes required — the slug
  is the stable reference, the value behind it changes atomically.
- The `vault_access_log` is append-only. Combined with telemetry events, this
  provides full traceability for every credential operation.
- Adding a new credential type (e.g., mutual TLS client certs) requires only a
  new `credential_type` value and an interpretation function — no schema changes.

## Follow-up

1. Implement `Platform.Vault` module tree and Ecto schemas
2. Add Cloak encryption configuration and key management
3. Build migrations for `vault_credentials`, `vault_access_grants`, `vault_access_log`
4. Implement OAuth flow for initial provider set (Anthropic, OpenAI)
5. Build Control Center Vault UI (credential list, add/edit, OAuth connect, audit)
6. Implement `.openclaw` and `.credentials/` import paths
