defmodule Platform.Repo.Migrations.SeedPromptTemplatesSecurityGuard do
  use Ecto.Migration

  @moduledoc """
  Seed the Security Guard bundle prompt templates for the four
  responsibilities added in task 019f3e8e-4406 v2 stage 1 — see
  ADR-0043.

    * `security.cve_scan.v1`
    * `security.code_audit.v1`
    * `security.deploy_audit.v1`
    * `security.secret_leak.v1`

  Each template is the LLM-facing enrichment layer for its matching
  deterministic scanner (Sweeper still produces the raw finding —
  the template refines summary + priority + remediation into the
  shape below).

  ## Closed-shape output contract

  Every Security Guard template instructs the model to emit exactly:

      {"summary": "<string>",
       "priority": "critical|high|medium|low",
       "remediation_steps": ["<string>"]}

  ## Idempotent

  Follows the pattern in `20260703120200_seed_prompt_templates_meeting_scribe.exs` —
  if the slug already exists we leave the row alone (matches
  `PromptTemplates.seed_defaults/0`). `down/0` deletes only the slugs
  this migration introduced.
  """

  @templates [
    %{
      slug: "security.cve_scan.v1",
      name: "Security: CVE Scan",
      description:
        "Security Guard enriches a raw CVE finding — refines exploitability, drafts upgrade command, adjusts priority.",
      variables: [
        "finding",
        "cve_id",
        "severity",
        "package",
        "version",
        "ecosystem",
        "fixed_version"
      ],
      content: """
      You are the Security Guard's `security.cve_scan` responsibility. A deterministic scanner surfaced a raw CVE finding; you enrich it into a triage-ready task description.

      Input variables:
        * `finding` — full JSON of the raw finding.
        * `cve_id` — the CVE identifier (e.g. `CVE-2026-1234`).
        * `severity` — raw scanner severity (`critical`, `high`, `medium`, `low`).
        * `package` — affected package name.
        * `version` — currently installed version.
        * `ecosystem` — package ecosystem (`hex`, `npm`, `cargo`, `pip`, `deb`, etc.).
        * `fixed_version` — the first upstream version that patches the CVE (may be empty if none is published yet).

      Take judgment on:
        * Whether the CVE is actually exploitable given typical usage of this package. Dev-only / build-time dependencies lower priority; production-facing HTTP/DB/crypto surfaces raise it.
        * The ecosystem-appropriate upgrade command. For example: `mix deps.update <package>` (hex), `npm update <package>` (npm), `cargo update -p <package>` (cargo), `pip install --upgrade <package>` (pip), `apt-get install --only-upgrade <package>` (deb).
        * Whether the patch is a version bump inside the same major/minor (safe) vs a breaking major upgrade (needs a migration plan).

      Output a single JSON object matching this exact shape — no prose, no wrapping:

          {"summary": "<one-sentence what + who + risk>",
           "priority": "critical|high|medium|low",
           "remediation_steps": ["<step 1>", "<step 2>", ...]}

      Rules:
        * `summary` must name the package, CVE id, and observed risk.
        * `priority` reflects your refined judgment — it MAY differ from the raw scanner severity.
        * `remediation_steps` is ordered: upgrade command first, then any follow-ups (redeploy, config toggle, migration).
      """
    },
    %{
      slug: "security.code_audit.v1",
      name: "Security: Code Audit",
      description:
        "Security Guard enriches a code-pattern hit — filters false positives, produces a targeted fix in the codebase's existing style.",
      variables: [
        "finding",
        "pattern_id",
        "severity",
        "file_path",
        "line",
        "snippet",
        "rubric_note"
      ],
      content: """
      You are the Security Guard's `security.code_audit` responsibility. A deterministic pattern scan produced a hit; you enrich it into a triage-ready task description.

      Input variables:
        * `finding` — full JSON of the raw finding.
        * `pattern_id` — the rubric pattern that matched (e.g. `unparameterized_sql`, `missing_hmac`, `hardcoded_secret`, `insecure_random`).
        * `severity` — raw scanner severity.
        * `file_path` — path to the file relative to the repo root.
        * `line` — 1-based line number of the hit.
        * `snippet` — the surrounding code snippet (already trimmed).
        * `rubric_note` — the rubric's suggested fix pattern (may be empty).

      Take judgment on:
        * Whether the hit is a real risk in context. Test files under `test/`, fixtures, and dev-only scripts lower priority; production controllers / contexts / migrations raise it.
        * A targeted fix that mirrors the codebase's existing patterns — do not invent new abstractions. For example: for unparameterized SQL, prefer `Repo.query/2` with `$1` placeholders; for missing HMAC, use `:crypto.mac(:hmac, :sha256, key, msg)`; for hardcoded secrets, move the value to a config env var and note the target env file.

      Output a single JSON object matching this exact shape — no prose, no wrapping:

          {"summary": "<one-sentence what + where + risk>",
           "priority": "critical|high|medium|low",
           "remediation_steps": ["<step 1>", "<step 2>", ...]}

      Rules:
        * `summary` must name the pattern, the file, and the risk in context.
        * `priority` reflects your refined judgment — production controllers should not sit at `low`, test-file hits should not sit at `critical`.
        * `remediation_steps` is ordered: the code edit first, then verify (test run / lint) and follow-ups.
      """
    },
    %{
      slug: "security.deploy_audit.v1",
      name: "Security: Deploy Audit",
      description:
        "Security Guard enriches a deploy-config gap — judges boot-crash likelihood, drafts rollout mitigation.",
      variables: [
        "finding",
        "gap_kind",
        "severity",
        "resource_path",
        "expected",
        "observed"
      ],
      content: """
      You are the Security Guard's `security.deploy_audit` responsibility. A deterministic deploy-config audit surfaced a gap; you enrich it into a triage-ready task description.

      Input variables:
        * `finding` — full JSON of the raw finding.
        * `gap_kind` — the class of gap (`missing_env_var`, `expired_tls`, `missing_chain_oauth2`, `weak_cipher`, `permissive_cors`, etc.).
        * `severity` — raw scanner severity.
        * `resource_path` — the config resource that fails (env-file path, TLS cert path, endpoint URL).
        * `expected` — what the audit expected to find.
        * `observed` — what the audit actually found (empty, expired, permissive value).

      Take judgment on:
        * Boot-crash likelihood. A missing required env var whose absence trips `System.fetch_env!/1` is `critical` (the release crash-loops on start). Expired TLS on a low-traffic subdomain is `medium` (users see a warning; not a crash). Weak cipher on internal-only endpoints is `low`.
        * Rollout mitigation ordering. Do NOT restart the service before the config gap is patched — that racecondition ships downtime. Prefer: (1) append to the core-ops secrets file first, (2) verify the value is present (e.g. `sudo cat /srv/dev/core-ops/secrets/moon-production/platform.secrets.env | grep <KEY>`), (3) then bounce with `systemctl --user restart core-platform.service`.

      Output a single JSON object matching this exact shape — no prose, no wrapping:

          {"summary": "<one-sentence what + which resource + risk>",
           "priority": "critical|high|medium|low",
           "remediation_steps": ["<step 1>", "<step 2>", ...]}

      Rules:
        * `summary` must name the gap kind and the resource path.
        * `priority` reflects your refined judgment — crash-loop candidates are `critical`, cosmetic gaps are `low`.
        * `remediation_steps` is ordered: config patch first, verification second, restart last.
      """
    },
    %{
      slug: "security.secret_leak.v1",
      name: "Security: Secret Leak",
      description:
        "Security Guard enriches a secret-leak finding — produces a credential-specific rotation checklist.",
      variables: [
        "finding",
        "credential_class",
        "severity",
        "file_path",
        "line",
        "in_git_history"
      ],
      content: """
      You are the Security Guard's `security.secret_leak` responsibility. A deterministic pattern scan matched a credential; you enrich it into a triage-ready task description with a rotation checklist keyed to the specific credential type.

      Input variables:
        * `finding` — full JSON of the raw finding.
        * `credential_class` — the matched credential type (`openai_api_key`, `github_pat`, `livekit_api_secret`, `aws_access_key`, `private_key_pem`, `generic_bearer_token`, etc.).
        * `severity` — raw scanner severity.
        * `file_path` — path to the file relative to the repo root.
        * `line` — 1-based line number of the match.
        * `in_git_history` — boolean; true if the secret is present in any prior commit, false if only in the working tree.

      Take judgment on:
        * The rotation flow specific to the credential class. Examples:
            * `openai_api_key` → OpenAI dashboard → API keys → revoke + create; update `OPENAI_API_KEY` in the target env file.
            * `github_pat` → GitHub → Settings → Developer settings → Personal access tokens → revoke + create with the same scopes; update `GITHUB_TOKEN` in the target env file.
            * `livekit_api_secret` → LiveKit Cloud console → Project → Settings → API keys → revoke + create; update `LIVEKIT_API_KEY` + `LIVEKIT_API_SECRET`.
            * `aws_access_key` → AWS IAM → Users → Security credentials → revoke + create; update `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY`.
            * `private_key_pem` → generate a new keypair, distribute the public key to accepting services, retire the old key.
        * Git-history handling. If `in_git_history == true`, the leaked secret is public regardless of removal from the working tree — a `git filter-repo` step must precede rotation. If `in_git_history == false`, a plain `git rm` (or edit + commit) plus rotation is sufficient.

      Output a single JSON object matching this exact shape — no prose, no wrapping:

          {"summary": "<one-sentence what credential + where + is-history>",
           "priority": "critical|high|medium|low",
           "remediation_steps": ["<step 1>", "<step 2>", ...]}

      Rules:
        * `summary` must name the credential class, the file, and whether history rewrite is needed.
        * `priority` is `critical` when `in_git_history == true` (public exposure), otherwise reflects the credential's blast radius.
        * `remediation_steps` is ordered: if `in_git_history == true` a `git filter-repo` step comes first, then revoke-and-rotate, then update env config, then verify.
      """
    }
  ]

  def up do
    alias Platform.Orchestration.PromptTemplates

    Enum.each(@templates, fn template ->
      case PromptTemplates.get_template_by_slug(template.slug) do
        nil ->
          {:ok, _} = PromptTemplates.create_template(template)

        _existing ->
          :skip
      end
    end)

    :ok
  end

  def down do
    alias Platform.Orchestration.PromptTemplates

    Enum.each(@templates, fn %{slug: slug} ->
      case PromptTemplates.get_template_by_slug(slug) do
        nil -> :ok
        template -> {:ok, _} = PromptTemplates.delete_template(template)
      end
    end)

    :ok
  end
end
