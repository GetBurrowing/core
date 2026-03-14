# Vault Architecture — ADR 0006

Secure Credential Vault: encrypted storage, scoped access control, append-only audit log, and OAuth lifecycle management.

```mermaid
graph TB
  subgraph Callers["Callers"]
    Platform["platform scope<br/>{:platform, nil}"]
    Workspace["workspace scope<br/>{:workspace, uuid}"]
    Agent["agent scope<br/>{:agent, uuid}"]
    Integration["integration scope<br/>{:integration, id}"]
  end

  subgraph VaultAPI["Platform.Vault — Public API"]
    Put["put/4<br/>slug, type, value, opts"]
    Get["get/2<br/>slug, accessor: {type, id}"]
    Rotate["rotate/3<br/>slug, new_value, opts"]
    List["list/1<br/>metadata only — no decrypted values"]
    ExpiringSoon["expiring_soon/1<br/>within: {n, unit}"]
    Delete["delete/2<br/>clears access_log rows first"]
  end

  subgraph Encryption["Encryption Layer"]
    Cloak["Cloak.Ecto<br/>AES-256-GCM per field"]
    MasterKey["VAULT_MASTER_KEY<br/>env var — required in prod"]
  end

  subgraph DB["Database Tables"]
    Credentials[("vault_credentials<br/>UUID PK<br/>encrypted_data, scope, type<br/>expires_at")]
    Grants[("vault_access_grants<br/>on_delete: :delete_all<br/>grantee_type, grantee_id")]
    AccessLog[("vault_access_log<br/>bigserial PK (monotonic)<br/>append-only audit trail")]
  end

  subgraph OAuth["OAuth Lifecycle"]
    OAuthMod["Platform.Vault.OAuth<br/>PKCE flow (S256)<br/>ETS state store"]
    AuthURL["authorize_url/2<br/>state + code_challenge"]
    Callback["handle_callback/2<br/>token exchange via Req.post"]
    Refresh["refresh/1<br/>refresh_token → rotate in Vault"]
    RefreshWorker["Platform.Vault.RefreshWorker<br/>GenServer<br/>polls every 5 min"]
  end

  subgraph Telemetry["Observability"]
    TelHandler["Platform.Vault.TelemetryHandler<br/>[:platform, :vault, :*] events"]
    AuditStream["Platform.Audit<br/>Event Stream"]
  end

  Callers --> Put & Get & Delete & List & ExpiringSoon
  Put --> Cloak
  Get --> Cloak
  Rotate --> Cloak
  Cloak <--> MasterKey
  Cloak <--> Credentials
  Get --> Grants
  Put & Get & Rotate & Delete --> AccessLog
  TelHandler -->|telemetry| AuditStream
  RefreshWorker --> ExpiringSoon
  RefreshWorker --> Refresh
  OAuthMod --> AuthURL & Callback & Refresh
  Callback --> Put
  Refresh --> Rotate
```

## Credential Types
| Type | Usage |
|------|-------|
| `api_key` | Static API keys (GitHub PAT, etc.) |
| `oauth2` | OAuth tokens (access + refresh JSON) |
| `token` | Bearer tokens |
| `keypair` | Public/private key material |
| `custom` | Arbitrary encrypted blobs |

## Scope Hierarchy
`platform` → `workspace` → `agent` → `integration`

- A `platform`-scoped credential is readable by any accessor.
- An `agent`-scoped credential is only readable by that specific agent UUID.
- `vault_access_grants` override the default scope rules for explicit sharing.
