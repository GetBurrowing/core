# Install Manifest (schema v1)

This document is the field-by-field reference for the **install manifest** defined by
[ADR 0053](../../docs/decisions/0053-install-manifest-and-renderers.md). It sits next to
[`platform-target-contract.md`](platform-target-contract.md), which it extends: that contract
names the runtime values core-platform needs, and the manifest is what now produces them.

One manifest describes **one Suite install for one customer**. It covers infrastructure only:
domain, TLS, service set, model endpoints, auth, backup, size, GPU and images. Per-install
behaviour (orgs, agents, prompts, feature settings) stays in the admin panel.

- Format: TOML. `tomllib` parses it with the Python standard library, so no pip step is needed.
- Validator: `PYTHONPATH=deployment/installer python3 -m suite_install validate <manifest>`
- Service set: `PYTHONPATH=deployment/installer python3 -m suite_install services <manifest>`
- Example: [`deployment/examples/moon-equivalent.install.toml`](../examples/moon-equivalent.install.toml)

Every key the manifest may contain is listed below. Any other key, at any depth, is an error
(`unknown_key`, or `unknown_service` under `[services]`). This means a misspelled knob fails
validation instead of silently keeping its default.

---

## Top level

| Key | Type | Required | Notes |
|---|---|---|---|
| `schema_version` | integer | yes | Must be `1`. Anything else, or a missing value, gives `unsupported_schema_version`, and nothing else is checked. |

## `[install]`

| Key | Type | Default | Notes |
|---|---|---|---|
| `name` | string | required | `[a-z][a-z0-9-]{0,62}`. Names the install; becomes `DEPLOY_TARGET`. |
| `size_tier` | `small` \| `medium` \| `large` | `small` | Sizing hint for renderers (VM size, pool sizes). |
| `modules` | array of strings | `[]` | Build-time modules ([ADR 0055](../../docs/decisions/0055-extension-contract-and-build-time-modules.md)). Each entry must be a known module (`unknown_module`), listed once (`invalid_value`). Known modules: `play`. The set picks the core image flavour: `[]` runs `suite-core:core`, `["play"]` runs `suite-core:play`. A module is compiled into the core image, so this changes nothing else in the render. See [`install-modules.md`](install-modules.md). |

## `[domain]`

| Key | Type | Default | Notes |
|---|---|---|---|
| `primary` | string | required | Public FQDN of the install. Missing gives `missing_domain`. A value that is not a DNS name (IP literal, single label, trailing dot, bad label) gives `invalid_domain`. Auth is served at `auth.<primary>`. |
| `tls` | `acme` \| `internal` | `acme` | `acme` uses a public CA. `internal` uses a private root generated on the host, for throwaway or LAN installs. |
| `acme_email` | string | none | Required iff `tls = "acme"` (`acme_email_required`). Rejected with `tls = "internal"` (`field_not_applicable`). |

## `[host]`

| Key | Type | Default | Notes |
|---|---|---|---|
| `gpu` | bool | `false` | The host has an NVIDIA GPU usable by containers. |

## `[services]`

core-platform, postgres and the Caddy edge are implicit and cannot be turned off. The four keys
below are the whole vocabulary. Any other key gives `unknown_service`.

| Key | Type | Default | Container | Notes |
|---|---|---|---|---|
| `files` | bool | `false` | `files-service` | File storage and extraction. |
| `memory` | bool | `false` | `memory-service` | Needs `embeddings = true` (`memory_requires_embeddings`). |
| `voice` | bool | `false` | `speaches` | Speech-to-text and text-to-speech. See `[voice]`. |
| `embeddings` | bool | `false` | `embeddings` (only in `mode = "local"`) | The embeddings capability. See `[embeddings]`. |

A table for a service that is off (`[voice]` while `voice = false`) is allowed and ignored. Its
internal consistency is still checked, so turning the service on later is a one-field change.

## `[voice]`

| Key | Type | Default | Notes |
|---|---|---|---|
| `accelerator` | `cpu` \| `cuda` | `cpu` | `cuda` with `services.voice = true` needs `host.gpu = true` (`gpu_required`). |

## `[embeddings]`

| Key | Type | Default | Notes |
|---|---|---|---|
| `mode` | `local` \| `endpoint` | `local` | `local` runs the embeddings container. `endpoint` uses a remote OpenAI-compatible embeddings API and runs no container. |
| `base_url` | string | none | http(s) URL. Required iff `mode = "endpoint"` (`embeddings_endpoint_required`). Otherwise `field_not_applicable`. |
| `api_key_ref` | string | none | Secret ref (see below). Only with `mode = "endpoint"`. |

## `[[models.endpoints]]`

An install has **no model endpoint unless its owner declares one**. There is no default endpoint
of ours. `local`, `hosted` and `byo` are equally first-class. Agent runtimes are not configured
here; they federate in through the admin panel and runtime registration.

| Key | Type | Required | Notes |
|---|---|---|---|
| `name` | string | yes | `[a-z][a-z0-9-]{0,62}`, unique across endpoints (`duplicate_endpoint_name`). |
| `kind` | `local` \| `hosted` \| `byo` | yes | `local`: runs on the customer's hardware. `hosted`: a provider API. `byo`: any endpoint the customer brings. |
| `base_url` | string | yes | http(s) URL. |
| `api_key_ref` | string | no | Secret ref. |

## `[auth]`

| Key | Type | Default | Notes |
|---|---|---|---|
| `mode` | `bundled-pocket-id` \| `external-oidc` | `bundled-pocket-id` | Bundled mode runs the `pocket-id` container at `auth.<primary>`. |
| `issuer` | string | none | https URL. For external mode. |
| `client_id` | string | none | For external mode. |
| `client_secret_ref` | string | none | Secret ref. For external mode. |

External mode needs all three of `issuer`, `client_id` and `client_secret_ref`. If any is missing, the result is one `external_oidc_incomplete` error listing them. In bundled mode, all three are `field_not_applicable`.

## `[backup]`

| Key | Type | Default | Notes |
|---|---|---|---|
| `target` | `none` \| `local-path` \| `s3-compatible` | `none` | |
| `path` | string | none | Absolute path. Required for `local-path`. |
| `bucket`, `endpoint`, `access_key_ref`, `secret_key_ref` | string | none | Required for `s3-compatible`. `endpoint` is an http(s) URL. |
| `region` | string | none | Optional, `s3-compatible` only. |

A missing required field gives one `backup_incomplete` error. A field the target does not use gives `field_not_applicable`.

## `[images]`

| Key | Type | Default | Notes |
|---|---|---|---|
| `source` | `registry` \| `preloaded` | `registry` | `preloaded`: images are loaded onto the host out of band, and nothing is pulled. |
| `refs.<container>` | string | registry default | Per-container image override. The keys are container names: `caddy`, `core-platform`, `core-postgres`, `embeddings`, `files-service`, `memory-service`, `pocket-id`, `speaches`. The `core-platform` default is the flavour `install.modules` selects; an override replaces it, so a pinned ref must be a build of the same flavour (for example `suite-core:play-<sha>` with `modules = ["play"]`). |

## `[day2]` (reserved)

These keys are validated but not yet acted on. ADR 0053 names the follow-up work that will use them.

| Key | Type | Default |
|---|---|---|
| `upgrade_channel` | `stable` \| `edge` \| `pinned` | `stable` |
| `phone_home` | bool | `false` |

---

## Secret refs

A field ending in `_ref` holds the **name** of a secret, never its value. The name is
`UPPER_SNAKE_CASE`, and a string that is not a name gives `invalid_value`. Customer-supplied values
are provided at render time, never in the manifest. Secrets the install generates itself
(`SECRET_KEY_BASE`, database password, service tokens) have no manifest field at all.

## Error codes

The CLI prints `error <code> at <toml.path>: <message>`, one line per problem, and exits `2`.
A valid manifest prints `ok` and exits `0`.

| Code | Raised when |
|---|---|
| `unsupported_schema_version` | `schema_version` is missing or not `1` |
| `unknown_key` | a key outside this schema, at any depth |
| `unknown_service` | a `[services]` key other than `files`, `memory`, `voice` or `embeddings` |
| `unknown_module` | an `install.modules` entry other than `play` |
| `invalid_type` | a value of the wrong TOML type |
| `invalid_enum` | an enum value outside its allowed set |
| `invalid_value` | a malformed name, URL, email, path, secret ref or empty image ref, or a module listed twice |
| `missing_required` | `install.name` or an endpoint's `name`/`kind`/`base_url` is missing |
| `missing_domain` | `domain.primary` is missing |
| `invalid_domain` | `domain.primary` is not a DNS name |
| `acme_email_required` | `tls = "acme"` without `acme_email` |
| `field_not_applicable` | a field that the selected mode or target does not use |
| `gpu_required` | voice on with `accelerator = "cuda"` and `host.gpu = false` |
| `memory_requires_embeddings` | `services.memory = true` with `services.embeddings = false` |
| `embeddings_endpoint_required` | `embeddings.mode = "endpoint"` without `base_url` |
| `external_oidc_incomplete` | `auth.mode = "external-oidc"` missing issuer, client_id or client_secret_ref |
| `backup_incomplete` | the backup target is missing a field it requires |
| `duplicate_endpoint_name` | two `[[models.endpoints]]` entries share a `name` |
| `invalid_toml` | the file does not parse as TOML (loader) |
| `unreadable_manifest` | the file cannot be read (loader) |

A value that fails a type or enum check is treated as absent by the cross-field rules, and it
does not raise a second error. So one wrong field produces exactly one error line.

---

## Mapping from the platform target contract (ADR 0003)

| ADR 0003 contract field | Produced from |
|---|---|
| `PHX_SERVER` | Constant `true` (renderer). |
| `PHX_HOST` | `domain.primary` |
| `PORT` | Constant `4000` (renderer; internal only). |
| `DNS_CLUSTER_QUERY` | Blank: a single-host install is one node. |
| `SECRET_KEY_BASE` | Generated at render time; no manifest field. |
| `DEPLOY_TARGET` | `install.name` |
| `PUBLIC_FQDN` | `domain.primary` |
| `PUBLIC_SCHEME` | Constant `https`; both `tls` modes terminate TLS at Caddy. |
| `UPSTREAM_SERVICE` | Constant `core-platform` (registry). |
| `UPSTREAM_PORT` | Constant `4000`. |
| `HEALTHCHECK_URL` | `https://<domain.primary>/health` |
| `PLATFORM_IMAGE` | `images.refs.core-platform`, else the flavour of `install.modules` (`suite-core:core` or `suite-core:play`). |
| `PROMOTION_CHANNEL` | `day2.upgrade_channel` (reserved; not yet acted on). |
| `PROMOTION_REF` | Not produced: promotion state is private instance state (ADR 0003 §4). |

The manifest also produces values that ADR 0003 predates, and that the renderer (stage 2 of task
01a0d69d) records against their consumers:

- `MEMORY_SERVICE_URL` and `FILES_SERVICE_URL`. Core treats an unset value as the feature being
  off: `apps/platform/config/runtime.exs`, around the `System.get_env("MEMORY_SERVICE_URL")` and
  `System.get_env("FILES_SERVICE_URL")` reads.
- The `OIDC_*` values.

## Rendering

`python3 -m suite_install render <manifest> --out <dir>` writes one install. Run it with
`PYTHONPATH=deployment/installer`. `--target` defaults to `single-host`, which is the only target
today. The service semantics live in `suite_install/registry.py`, and each target adds its own
output layer.

`single-host` writes these files to `--out`:

| File | Mode | Notes |
|---|---|---|
| `compose.yaml` | 0644 | No secret literal. Containers that need secrets read `secrets.env` through `env_file`. |
| `Caddyfile` | 0644 | One site per route. `tls = "internal"` signs with a root that the host generates at first boot. |
| `secrets.env` | 0600 | Holds the generated secrets and the customer secrets that a container reads. |
| `customer-secrets.env` | 0600 | Written only when a customer secret is supplied that no container reads yet. |
| `services.txt` | 0644 | Same as `suite_install services`. |
| `postgres-init/*.sql` | 0644 | Init SQL declared by the enabled services. |
| `models.json` | 0644 | Written only when `[[models.endpoints]]` is declared. |
| `user-data` | 0600 | `#cloud-config` for Ubuntu 24.04. Carries every file above plus `suite-stack.service`. |
| `meta-data` | 0644 | NoCloud instance id. |
| `registry-auth.json` | 0600 | Written only with `--registry-auth`. |

Options:

- `--reuse-secrets <secrets.env>` keeps the values an earlier render generated, and drops the
  secrets of services that are now off.
- `--customer-secrets <file>` supplies each `*_ref` value, one `NAME=value` per line.
- `--registry-auth <config.json>` is required when `images.source = "registry"` pulls a private
  default image.

The renderer refuses in three cases:

- `--out` is inside a git work tree (`output_inside_git_worktree`);
- `--out` is not empty (`output_not_empty`);
- a customer secret is missing (`customer_secret_missing`) or shadows a generated name
  (`customer_secret_conflict`).

To compare two renders without printing a secret, run `suite_install redact <dir> --out <dir>` on
each and diff the copies. Do not diff the raw directories: `user-data` carries `secrets.env`.
