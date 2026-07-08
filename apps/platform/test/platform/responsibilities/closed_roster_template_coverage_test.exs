defmodule Platform.Responsibilities.ClosedRosterTemplateCoverageTest do
  @moduledoc """
  Safety-net regression: every responsibility key referenced by the
  closed roster (`Platform.Roles.Seeds.default_roles/0`) must resolve to
  a `Platform.Responsibilities.Responsibility` row whose
  `default_prompt_template` slug in turn resolves to a real
  `Platform.Orchestration.PromptTemplate` row.

  This test fails loudly if a new role/responsibility ever lands
  without an accompanying handler + prompt-template seed. It is the
  final safety net behind the ADR-0041 M8 closed-roster contract: the
  Seeds bundle, the `BuiltIns` provider list, and the migrated prompt
  templates must all agree.

  ## Known seed-key aliases

  `Platform.Roles.Seeds` names one bundle key that doesn't match the
  shipped `Handler.key/0` value. We tolerate that here via a small
  alias map so this coverage test does not fail on a naming mismatch
  that is tracked as a separate follow-up. Do NOT rename Seeds inside
  this test's scope — that's a distinct commit.

    * `memory.dream_consolidation` (seed) → `memory.dreaming` (handler)

  ## Sweeper-driven exemption

  The Security Guard bundle (task `019f3e8e-4406` stage 1 — see
  ADR-0043) registers four responsibility keys whose runtime is
  `Platform.Security.Sweeper`, not the Router. They intentionally
  have `default_prompt_template: nil` because deterministic filesystem
  + OSV.dev scans don't route through an LLM. This test exempts any
  responsibility row whose `metadata["executor"]` names a non-Router
  runtime — the exemption is narrow enough that a future non-executor
  key with `default_prompt_template: nil` still fails loudly.

  ## Setup pattern

  Mirrors `Platform.Responsibilities.BuiltInsTest`: uses the DataCase
  sandbox, seeds roles via `Seeds.seed_defaults/0`, and registers every
  built-in provider via `Responsibilities.register/1`. Prompt templates
  are inserted via `PromptTemplates.create_template/1` inside a
  get-then-create idempotence guard so per-test setup is safe.
  """
  use Platform.DataCase, async: false

  alias Platform.Orchestration.PromptTemplates
  alias Platform.Responsibilities
  alias Platform.Responsibilities.BuiltIns
  alias Platform.Roles.Seeds

  # SEEDS ↔ HANDLER alias map. Keyed by the seed bundle key; value is
  # the effective handler key that the responsibility row is registered
  # under. Only one alias today.
  @known_seed_key_aliases %{"memory.dream_consolidation" => "memory.dreaming"}

  # The 13 prompt-template slugs the closed roster depends on. Kept as
  # a literal list here (rather than derived from the responsibility
  # rows) so a stale expected list forces an intentional edit alongside
  # the code change that introduced a new template.
  @closed_roster_template_slugs [
    "design.brand_check.v1",
    "design.critique.v1",
    "design.spec_writer.v1",
    "meetings.action_items.v1",
    "meetings.attendance_followup.v1",
    "meetings.intent_classify.v1",
    "meetings.summarize.v1",
    "memory.daily_summary.v1",
    "memory.dreaming.v1",
    "memory.propose_long_term.v1",
    "tasks.triage.v1",
    "tasks.unblock.v1",
    "tasks.weekly_review.v1"
  ]

  setup do
    # Seed the closed roster of roles + responsibility bundles.
    Seeds.seed_defaults()

    # Register every built-in responsibility provider so the
    # `responsibilities` table carries the 13 rows the roster points at.
    Enum.each(BuiltIns.providers(), fn provider_module ->
      {:ok, _rows} = Responsibilities.register(provider_module)
    end)

    # Insert the prompt-template rows the migrations would carry on a
    # freshly-migrated prod DB. In the test sandbox we insert directly
    # for the slugs the closed roster owns.
    seed_test_templates()

    :ok
  end

  # Idempotent inserts — skip anything already present. Mirrors the
  # migration seed pattern in
  # `20260703120000_seed_designer_prompt_templates.exs` et al.
  defp seed_test_templates do
    Enum.each(@closed_roster_template_slugs, fn slug ->
      case PromptTemplates.get_template_by_slug(slug) do
        nil ->
          {:ok, _} =
            PromptTemplates.create_template(%{
              slug: slug,
              name: "Test seed — #{slug}",
              content:
                "Placeholder content for #{slug} inserted by closed-roster coverage test setup."
            })

        _existing ->
          :ok
      end
    end)
  end

  describe "closed-roster coverage" do
    test "every closed-roster responsibility key resolves to a responsibility row + template row" do
      responsibility_keys =
        Seeds.default_roles()
        |> Enum.flat_map(& &1.bundle)
        |> Enum.uniq()

      # Belt-and-braces: the roster must be non-empty; a zero-length
      # sweep would silently pass.
      assert responsibility_keys != [], "closed roster produced no responsibility keys"

      Enum.each(responsibility_keys, fn seed_key ->
        effective_key = Map.get(@known_seed_key_aliases, seed_key, seed_key)
        responsibility = Responsibilities.get_by_key(effective_key)

        assert responsibility,
               "responsibility \"#{effective_key}\" (from seed key \"#{seed_key}\") " <>
                 "not registered — no row in responsibilities table"

        # Sweeper-driven rows (ADR-0043) do not have prompt templates
        # because they don't route through an LLM. Skip the template
        # assertion for them; the responsibility row's presence is
        # sufficient. Everything else must have a template + row.
        executor = get_in(responsibility.metadata, ["executor"])

        if executor in ["platform.security.sweeper"] do
          assert responsibility.default_prompt_template == nil,
                 "responsibility \"#{effective_key}\" is Sweeper-driven " <>
                   "(executor=#{executor}) but declared a default_prompt_template — " <>
                   "Sweeper rows must not route through the LLM path"
        else
          assert responsibility.default_prompt_template,
                 "responsibility \"#{effective_key}\" has no default_prompt_template slug"

          slug = responsibility.default_prompt_template

          assert PromptTemplates.get_template_by_slug(slug),
                 "responsibility \"#{effective_key}\" → template slug \"#{slug}\" " <>
                   "has no PromptTemplate row"
        end
      end)
    end

    test "closed roster reaches every built-in provider (drift alarm)" do
      # If a new provider ships in BuiltIns without a matching Seeds
      # bundle entry, the roster stops being closed and this test
      # catches it. Uses the alias map in reverse so seed-side
      # renames don't false-flag the drift alarm.
      registered_keys =
        BuiltIns.providers()
        |> Enum.map(fn mod -> mod.key() end)
        |> MapSet.new()

      roster_effective_keys =
        Seeds.default_roles()
        |> Enum.flat_map(& &1.bundle)
        |> Enum.map(fn seed_key -> Map.get(@known_seed_key_aliases, seed_key, seed_key) end)
        |> MapSet.new()

      unreferenced = MapSet.difference(registered_keys, roster_effective_keys)

      assert MapSet.size(unreferenced) == 0,
             "built-in provider keys not referenced by any role's bundle " <>
               "(closed-roster drift): #{Enum.join(unreferenced, ", ")}"
    end
  end
end
