defmodule Platform.Responsibilities.ClosedRosterTemplateCoverageTest do
  @moduledoc """
  Drift alarm for the closed roster's prompt-template coverage.

  ## What this file proves

  Every responsibility key referenced by the closed roster
  (`Platform.Roles.Seeds.default_roles/0`) resolves to a
  `Platform.Responsibilities.Responsibility` row, that row carries a
  `default_prompt_template` slug, and that slug is OWNED BY A REAL
  SEEDER — either `Platform.Orchestration.PromptTemplates.default_templates/0`
  or a migration under `priv/repo/migrations/` that actually inserts it.

  Ownership is then cross-checked against the migrated test database,
  so the static scan below cannot quietly disagree with what a real
  environment holds.

  ## What it used to claim, and why that claim was false

  The moduledoc used to say this file "fails loudly if a new
  role/responsibility ever lands without an accompanying handler +
  prompt-template seed". It could not. `setup` called
  `seed_test_templates/0`, which INSERTED every slug in
  `@closed_roster_template_slugs`; the coverage assertion then checked
  that those exact slugs resolved. The assertion was satisfied by its
  own setup — delete a seed migration and the test stayed green.

  Task `019fb8ed` stage 2 made the native dispatch path resolve
  `default_prompt_template` as a real `prompt_templates` slug, so a
  missing row is now a silently empty prompt on the wire rather than a
  cosmetic gap. That is what this test guards, so it had to start
  telling the truth.

  ## Why "a migration mentions the slug" is not the ownership rule

  `20260703120200_seed_prompt_templates_meeting_scribe.exs` names
  `meetings.summarize.v1` in its moduledoc — "The pre-existing
  `meetings.summarize.v1` template (seeded by ...)" — and no migration
  in the tree ever inserts it. A file-level substring scan would report
  that slug as covered on the strength of a comment that is simply
  wrong. So ownership requires the slug to appear in a seed-descriptor
  position (`slug: "<slug>"`) in a file that also carries a creation
  call. Force-update migrations, `down/0` deletions, and prose
  references do not confer ownership.

  ## Known gaps are pinned exactly, not tolerated

  `@unseeded_roster_slugs` is an EXACT pin, not an allowlist to grow.
  The sweep asserts equality, so both directions redden: a new
  unseeded slug fails, and seeding one of the two known gaps also
  fails until the pin is updated. `sweep_unowned/1` itself knows
  nothing about the pin — the mutation control drives the same
  function over a key on each side of it and asserts they come back
  different.

  ## Setup pattern

  Mirrors `Platform.Responsibilities.BuiltInsTest`: DataCase sandbox,
  roles seeded via `Seeds.seed_defaults/0`, every built-in provider
  registered via `Responsibilities.register/1`. Prompt-template rows
  are NOT inserted here — they come from the migrations `mix test`
  runs, which is the whole point.

  ## Strict identity — no alias map

  Every seed bundle key must equal a registered `Handler.key/0` value
  exactly. This file used to carry a `@known_seed_key_aliases` map
  tolerating `memory.dream_consolidation` (seed) → `memory.dreaming`
  (handler); task `019fa230` stage 2 renamed the seed and deleted the
  map. Do not reinstate it: an alias here silently permits a bundle key
  that the Control Center panel offers and
  `Responsibilities.Router.fire_trigger/3` never resolves, which is
  precisely the defect that task fixed.
  """
  use Platform.DataCase, async: false

  alias Platform.Orchestration.PromptTemplates
  alias Platform.Responsibilities
  alias Platform.Responsibilities.BuiltIns
  alias Platform.Roles.Seeds

  # The 26 prompt-template slugs the closed roster depends on. Kept as
  # a literal list here (rather than derived from the responsibility
  # rows) so a stale expected list forces an intentional edit alongside
  # the code change that introduced a new template. ADR-0044 stage 1
  # (task 019f3da3) added the three `architecture.*` placeholders.
  #
  # The four `security.*.v1` slugs mirror the stage-1 seed migration
  # (`20260708130000_seed_prompt_templates_security_guard`) — task
  # `019f3e8e-4406` v2 stage 2 flipped the four security responsibility
  # rows to point at them, so the enrichment path is required-by-default
  # for the whole roster now.
  #
  # 21 → 26 on 2026-07-31: the five mid-meeting intent keys
  # (`meetings.{brief_worthy,decision_recorded,interaction_design,
  # open_question,visual_adjust}`) each declare a `.v1` slug, all five
  # seeded by
  # `20260731234500_seed_meeting_intent_prompt_templates.exs`. They are
  # therefore OWNED, and must NOT be added to `@unseeded_roster_slugs`
  # below — putting them there would pin a render gap that does not
  # exist and would go red the moment anyone read the migration.
  @closed_roster_template_slugs [
    "agents.goal_heartbeat.v1",
    "architecture.audit_diff.v1",
    "architecture.cron_sweep.v1",
    "architecture.review_plan.v1",
    "design.brand_check.v1",
    "design.critique.v1",
    "design.spec_writer.v1",
    "design.task_direction.v1",
    # Task 01a0d415 stage 3: `experiments.label_signal` (the scientist
    # role's blind labeler) points at this slug, seeded by
    # `20260924190000_seed_experiments_labeler_prompt.exs`.
    "experiments.labeler.v1",
    # Task 01a0d415 stage 5: `experiments.scientist` (the goal loop), seeded
    # by `20260924210000_seed_experiments_scientist_prompt.exs`.
    "experiments.scientist.v1",
    # Task 01a11ec3 stage 3: `feedback.intake` (triage officer) points at
    # this slug, seeded by `20261010160100_seed_feedback_intake_prompt.exs`.
    "feedback.intake.v1",
    # Task 019fa1ac-6685 stage 1: `janitor.cron_drain` (janitor role) points
    # at this slug; descriptor in `default_templates/0`, row seeded by
    # `20261009060918_add_janitor_role.exs`.
    "janitor.cron_drain.v1",
    "meetings.action_items.v1",
    "meetings.attendance_followup.v1",
    "meetings.brief_synthesis.v1",
    "meetings.brief_worthy.v1",
    "meetings.decision_recorded.v1",
    "meetings.intent_classify.v1",
    "meetings.interaction_design.v1",
    "meetings.open_question.v1",
    "meetings.summarize.v1",
    "meetings.visual_adjust.v1",
    "memory.daily_summary.v1",
    "memory.dreaming.v1",
    "memory.propose_long_term.v1",
    "security.code_audit.v1",
    "security.cve_scan.v1",
    "security.deploy_audit.v1",
    "security.secret_leak.v1",
    "tasks.triage.v1",
    "tasks.unblock.v1",
    "tasks.weekly_review.v1"
  ]

  # The roster slugs NO seeder owns today. Measured, not assumed: it is
  # named by a live handler (`Handlers.MeetingSummarize.register/0`) and
  # has no row in `default_templates/0` and no inserting migration, so a
  # native fire on that key ships `prompt_status: :render_gap` with
  # `template_missing:meetings.summarize.v1` rather than a body.
  #
  # Task `019fb8ed` stage 2 deliberately did not invent bodies for the two
  # slugs that were here: a named absence that says which row to seed beats
  # prompt content nobody authored reaching a live model. Seeding one is
  # what retires it from this list — and the equality assertion below makes
  # that removal mandatory rather than optional. Task `01a0a74d` stage 2
  # did exactly that for `memory.daily_summary.v1` (descriptor in
  # `default_templates/0` + `20260916103000_seed_memory_daily_summary_prompt.exs`),
  # so it came off this pin in the same commit that seeded it.
  #
  # `meetings.summarize.v1` was NOT swept in with it, and the difference is
  # measured rather than aesthetic: its trigger is `event`
  # (`meeting_finished`), not a clock, so it does not fire unattended the
  # way the 23:00 UTC daily summary does, and it carries a legacy fallback
  # MFA (`Platform.Meetings.Summarizer:run_summary:1`) so a render gap there
  # degrades to the legacy path instead of to an empty prompt.
  @unseeded_roster_slugs [
    "meetings.summarize.v1"
  ]

  # Creation calls. A migration that only force-updates an existing row
  # (`update_template`) or deletes one (`delete_template`) does not put
  # the row on a fresh database and therefore does not own the slug.
  @creation_markers ["create_template", "Repo.insert"]

  setup do
    # Seed the closed roster of roles + responsibility bundles.
    Seeds.seed_defaults()

    # Register every built-in responsibility provider so the
    # `responsibilities` table carries the rows the roster points at.
    Enum.each(BuiltIns.providers(), fn provider_module ->
      {:ok, _rows} = Responsibilities.register(provider_module)
    end)

    :ok
  end

  describe "closed-roster coverage" do
    test "every closed-roster responsibility key resolves to a row carrying a template slug" do
      responsibility_keys = roster_keys()

      # Belt-and-braces: the roster must be non-empty; a zero-length
      # sweep would silently pass.
      assert responsibility_keys != [], "closed roster produced no responsibility keys"

      Enum.each(responsibility_keys, fn seed_key ->
        responsibility = Responsibilities.get_by_key(seed_key)

        assert responsibility,
               "seed bundle key \"#{seed_key}\" is not registered — no row in the " <>
                 "responsibilities table under that exact key. The Control Center " <>
                 "panel offers this key but Responsibilities.Router would never " <>
                 "resolve it; rename the seed to match Handler.key/0 rather than " <>
                 "reinstating an alias map."

        assert responsibility.default_prompt_template,
               "responsibility \"#{seed_key}\" has no default_prompt_template slug"
      end)

      # Gives the literal list its stated teeth: a new roster
      # responsibility (or a renamed slug) now forces an intentional
      # edit here instead of drifting.
      assert Enum.sort(roster_slugs()) == Enum.sort(@closed_roster_template_slugs)
    end

    test "every closed-roster template slug is owned by a real seeder" do
      migration_files = migration_files()

      assert migration_files != [],
             "no migration files found under #{migrations_dir()} — the ownership " <>
               "scan would report every slug as unowned for the wrong reason"

      unowned = sweep_unowned(roster_keys())

      assert Enum.sort(Enum.map(unowned, & &1.slug)) == Enum.sort(@unseeded_roster_slugs),
             """
             closed-roster template coverage changed.

             Slugs with no seeder right now:
             #{format_unowned(unowned)}
             Pinned in @unseeded_roster_slugs:
               #{Enum.join(@unseeded_roster_slugs, "\n  ")}

             A slug appearing here that is not pinned means a responsibility
             ships a `default_prompt_template` nothing seeds: every native fire
             on that key leaves as `prompt_status: :render_gap`. Add a seed
             migration (pattern: 20260703120300_seed_prompt_templates_triage_officer.exs)
             — editing `do_default_templates/0` alone is a no-op on every
             already-migrated environment, because `seed_defaults/0` is
             INSERT-only and skips slugs that exist.

             A pinned slug NOT appearing here means it finally got a seeder:
             delete it from @unseeded_roster_slugs.
             """
    end

    test "the sweep names a slug no seeder owns (mutation control)" do
      # Drives the SAME `sweep_unowned/1` the assertion above uses, over
      # one key on each side of the ownership line. A parallel
      # reimplementation here could not catch a bug in the real path;
      # deleting the sweep body reddens both tests.
      control_key = "closedrostersweep.unowned"
      control_slug = "closedrostersweep.unowned.v1"

      {:ok, _row} =
        Responsibilities.upsert_by_key(%{
          key: control_key,
          feature: "closedrostersweep",
          trigger_kind: "cron",
          trigger_config: %{"expression" => "*/5 * * * *"},
          scope: "global",
          context_provided: [],
          output_contract: %{"summary" => "string"},
          default_prompt_template: control_slug,
          cost_profile: "low_freq_capable"
        })

      # `tasks.triage` is on the owned side (seeded by
      # 20260703120300_seed_prompt_templates_triage_officer.exs).
      owned_key = "tasks.triage"
      assert Responsibilities.get_by_key(owned_key).default_prompt_template == "tasks.triage.v1"

      unowned = sweep_unowned([owned_key, control_key])

      assert Enum.map(unowned, & &1.key) == [control_key],
             "sweep did not separate the two sides: #{inspect(unowned)}"

      reported = hd(unowned)
      assert reported.slug == control_slug
      assert reported.cause == :no_seeder

      # And the two sides really are different — an ownership check that
      # returned the same verdict for both would satisfy neither of the
      # per-side assertions above once someone "simplified" them.
      assert sweep_unowned([owned_key]) != sweep_unowned([control_key])
    end

    test "seeder ownership agrees with the migrated database" do
      # Anchors the static scan in reality. Rows come from the
      # migrations `mix test` runs, never from this file.
      Enum.each(roster_slugs(), fn slug ->
        owned? = seeder_for(slug) != :none
        row? = PromptTemplates.get_template_by_slug(slug) != nil

        assert owned? == row?,
               "\"#{slug}\": seeder ownership says #{owned?} but the migrated " <>
                 "database says #{row?}. Either the ownership scan is wrong " <>
                 "(a seeder it cannot see, or one it credited from a comment), " <>
                 "or this database does not match the repo's migrations."
      end)
    end

    test "closed roster reaches every built-in provider (drift alarm)" do
      # If a new provider ships in BuiltIns without a matching Seeds
      # bundle entry, the roster stops being closed and this test
      # catches it. Strict identity match — a seed key that differs
      # from the handler key it means to reference now fails here
      # instead of being absorbed by an alias map.
      registered_keys =
        BuiltIns.providers()
        |> Enum.map(fn mod -> mod.key() end)
        |> MapSet.new()

      roster = MapSet.new(roster_keys())

      unreferenced = MapSet.difference(registered_keys, roster)

      assert MapSet.size(unreferenced) == 0,
             "built-in provider keys not referenced by any role's bundle " <>
               "(closed-roster drift): #{Enum.join(unreferenced, ", ")}"
    end
  end

  # ── The sweep ────────────────────────────────────────────────────────────

  # Single implementation shared by the real assertion and the mutation
  # control. Returns one entry per key whose prompt template no seeder
  # owns, naming the slug.
  defp sweep_unowned(keys) do
    keys
    |> Enum.map(fn key ->
      case Responsibilities.get_by_key(key) do
        nil ->
          %{key: key, slug: nil, cause: :no_responsibility_row}

        %{default_prompt_template: slug} when slug in [nil, ""] ->
          %{key: key, slug: slug, cause: :no_slug}

        %{default_prompt_template: slug} ->
          case seeder_for(slug) do
            :none -> %{key: key, slug: slug, cause: :no_seeder}
            _owner -> nil
          end
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  # `:none`, `:default_templates`, or `{:migration, filename}`.
  defp seeder_for(slug) when is_binary(slug) do
    cond do
      slug in default_template_slugs() ->
        :default_templates

      file = migration_seeding(slug) ->
        {:migration, Path.basename(file)}

      true ->
        :none
    end
  end

  defp seeder_for(_slug), do: :none

  defp default_template_slugs do
    Enum.map(PromptTemplates.default_templates(), & &1.slug)
  end

  # A migration owns a slug only if it names it in a seed-descriptor
  # position AND carries a creation call. See the moduledoc for the
  # moduledoc-mention false positive this rules out.
  defp migration_seeding(slug) do
    descriptor = ~r/slug:\s*"#{Regex.escape(slug)}"/

    Enum.find(migration_files(), fn file ->
      source = File.read!(file)

      Regex.match?(descriptor, source) and
        Enum.any?(@creation_markers, &String.contains?(source, &1))
    end)
  end

  defp migration_files do
    migrations_dir()
    |> Path.join("*.exs")
    |> Path.wildcard()
  end

  defp migrations_dir do
    Application.app_dir(:platform, "priv/repo/migrations")
  end

  defp roster_keys do
    Seeds.default_roles()
    |> Enum.flat_map(& &1.bundle)
    |> Enum.uniq()
  end

  defp roster_slugs do
    roster_keys()
    |> Enum.map(fn key ->
      case Responsibilities.get_by_key(key) do
        nil -> nil
        row -> row.default_prompt_template
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp format_unowned([]), do: "  (none)\n"

  defp format_unowned(unowned) do
    Enum.map_join(unowned, "\n", fn %{key: key, slug: slug, cause: cause} ->
      "  #{key} → #{inspect(slug)} (#{cause})"
    end) <> "\n"
  end
end
