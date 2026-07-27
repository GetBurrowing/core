defmodule Platform.Roles.Seeds do
  @moduledoc """
  Seeds the six platform-fixed roles + their responsibility bundles on
  first boot (M4 stage 4 of task `019ef65b-a361-7873-871b-3375bf60ead7`;
  `meeting_producer` added in task `019f2451-6728` stage 2;
  `security_guard` added in task `019f3e8e-4406` stage 1).

  Per Decision 2 from the M4 stack — the role roster is fixed by the
  platform, not user-extensible. The closed list:

    * `architect` — cross-task architectural coherence checks (added
      in ADR-0044 stage 1, task `019f3da3`)
    * `designer` — visual design, critique, brand alignment
    * `historian` — long-term memory accretion + recall
    * `meeting_producer` — watches meeting transcript in real time;
      classifies intent and delegates to specialist agents
    * `meeting_scribe` — capture, summarize, follow up after meetings
    * `triage_officer` — task hygiene: sort, unblock, weekly rollup
    * `security_guard` — periodic scans for CVEs, code patterns,
      deploy config drift, and leaked secrets (see ADR-0043 for the
      runtime design; the four bundled keys register as placeholders
      here and are driven by `Platform.Security.Sweeper`, not the
      Router)

  Responsibility keys here are aligned with the **v2 design canvas
  `019e0fb8-d87d-72b2-aab4-205b84fe23aa` rev 3** that Rowan signed off on,
  NOT the planner's earlier sketch-level pseudocode (which used
  speculative keys like `inbox.triage` / `meetings.transcribe` that
  predate the canvas).

  M8 registers these same keys in the Responsibilities registry; until
  M8 lands, `Platform.Roles.responsibilities_for/1` returns the bundle
  fine but `Platform.Responsibilities.get_by_key/1` won't resolve any of
  them — that's expected and not a defect.

  `seed_defaults/0` is idempotent. Both inserts use
  `on_conflict: :nothing` against the natural-key unique indexes
  (`roles_pkey` for roles, `role_responsibilities_pair_idx` for bundle
  rows), so re-running on a partially-seeded DB is safe.
  """

  alias Platform.Repo
  alias Platform.Roles.Role
  alias Platform.Roles.RoleResponsibility

  @default_roles [
    %{
      key: "designer",
      name: "Designer",
      description: "Visual design, critique, brand alignment",
      icon: "hero-paint-brush",
      bundle: [
        "design.critique",
        "design.spec_writer",
        "design.brand_check",
        # ADR-0046 stack member 7 (task 019f9b29-5ecd stage 3). Existing
        # DBs pick this up from
        # `20260726051346_seed_design_task_direction.exs`, which re-runs
        # `seed_defaults/0` — the pair index makes that safe.
        "design.task_direction"
      ]
    },
    %{
      key: "historian",
      name: "Historian",
      description: "Long-term memory accretion + recall",
      icon: "hero-book-open",
      bundle: [
        "memory.daily_summary",
        "memory.propose_long_term",
        "memory.dream_consolidation"
      ]
    },
    %{
      key: "meeting_producer",
      name: "Meeting Producer",
      description:
        "Watches meeting transcript in real time; classifies intent and delegates to specialist agents",
      icon: "hero-signal",
      bundle: ["meetings.intent_classify"]
    },
    %{
      key: "meeting_scribe",
      name: "Meeting Scribe",
      description: "Capture, summarize, follow up after meetings",
      icon: "hero-calendar-days",
      bundle: [
        "meetings.summarize",
        "meetings.action_items",
        "meetings.attendance_followup"
      ]
    },
    %{
      key: "triage_officer",
      name: "Triage Officer",
      description: "Task hygiene: sort, unblock, weekly rollup",
      icon: "hero-clipboard-document-check",
      bundle: ["tasks.triage", "tasks.unblock", "tasks.weekly_review"]
    },
    %{
      key: "security_guard",
      name: "Security Guard",
      description: "Periodic scans for CVEs, code patterns, deploy config, and leaked secrets",
      icon: "hero-shield-check",
      bundle: [
        "security.cve_scan",
        "security.code_audit",
        "security.deploy_audit",
        "security.secret_leak"
      ]
    },
    %{
      key: "architect",
      name: "Architect",
      description: "Cross-task architectural coherence: plan review, drift audit, weekly sweep",
      icon: "hero-cube-transparent",
      bundle: [
        "architecture.review_plan",
        "architecture.audit_diff",
        "architecture.cron_sweep"
      ]
    }
  ]

  @doc """
  Returns the canonical default role roster as raw data. Exposed so
  tests (and the eventual M7 UI) can introspect the seed list without
  hitting the DB.
  """
  def default_roles, do: @default_roles

  @doc """
  Seed the platform-fixed roles and their responsibility bundles.

  Idempotent — re-running against a DB that already has the rows is a
  no-op. Returns `:ok` on success.

  ## Options

    * `:only_keys` — a list of role keys to restrict the seed to. When
      omitted, seeds every row in `@default_roles`. This is a bootstrap
      escape hatch for the older
      `20260624013500_seed_default_roles.exs` migration: at that
      timestamp the `roles_key_check` CHECK constraint only permits the
      four original keys, so an unqualified call to `seed_defaults/0`
      on a fresh DB would blow up trying to insert `meeting_producer`.
      The dedicated re-seed migration
      (`20260702200500_seed_meeting_producer_role.exs`) runs after
      `20260702000000_add_meeting_producer_to_roles_check.exs` extends
      the CHECK, so it calls `seed_defaults/0` unqualified.
  """
  def seed_defaults(opts \\ []) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    only_keys = Keyword.get(opts, :only_keys)

    @default_roles
    |> Enum.filter(fn role_attrs ->
      only_keys == nil or role_attrs.key in only_keys
    end)
    |> Enum.each(fn role_attrs ->
      role_row = %Role{
        key: role_attrs.key,
        name: role_attrs.name,
        description: role_attrs.description,
        icon: role_attrs.icon,
        inserted_at: now,
        updated_at: now
      }

      Repo.insert!(role_row, on_conflict: :nothing, conflict_target: :key)

      Enum.each(role_attrs.bundle, fn responsibility_key ->
        bundle_row = %RoleResponsibility{
          role_key: role_attrs.key,
          responsibility_key: responsibility_key,
          inserted_at: now,
          updated_at: now
        }

        Repo.insert!(bundle_row,
          on_conflict: :nothing,
          conflict_target: [:role_key, :responsibility_key]
        )
      end)
    end)

    :ok
  end
end
