defmodule Platform.Roles.Seeds do
  @moduledoc """
  Seeds the four platform-fixed roles + their responsibility bundles on
  first boot (M4 stage 4 of task `019ef65b-a361-7873-871b-3375bf60ead7`).

  Per Decision 2 from the M4 stack — the role roster is fixed by the
  platform, not user-extensible. The closed list:

    * `designer` — visual design, critique, brand alignment
    * `historian` — long-term memory accretion + recall
    * `meeting_scribe` — capture, summarize, follow up after meetings
    * `triage_officer` — task hygiene: sort, unblock, weekly rollup

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
      bundle: ["design.critique", "design.spec_writer", "design.brand_check"]
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
    }
  ]

  @doc """
  Returns the canonical default role roster as raw data. Exposed so
  tests (and the eventual M7 UI) can introspect the seed list without
  hitting the DB.
  """
  def default_roles, do: @default_roles

  @doc """
  Seed the four platform-fixed roles and their responsibility bundles.

  Idempotent — re-running against a DB that already has the rows is a
  no-op. Returns `:ok` on success.
  """
  def seed_defaults do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Enum.each(@default_roles, fn role_attrs ->
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
