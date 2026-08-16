defmodule Platform.Repo.Migrations.ForceUpdateFederationPreambleContentTest do
  @moduledoc """
  Coverage for `20260816120000_force_update_federation_preamble_content`
  (task 01a00c99 stage 4) and for the posture section it ships.

  READ THIS BEFORE ADDING AN ASSERTION — the obvious migration test is vacuous
  by construction. In the test database the `federation.preamble` row is
  created by the seed migration running `PromptTemplates.seed_defaults/0`
  against the CURRENT code, so it already equals this branch's default before
  anything here runs; `assert row.content =~ "close the ticket"` passes with
  the migration file deleted. Every migration test below therefore stales the
  row first, asserts the before-state, and only then reads the delta.

  A second trap specific to this stack: since stage 2,
  `PromptTemplates.federation_preamble/0` READS THE ROW. Once the row is stale
  it returns the stale text, so it cannot serve as the expected value inside a
  migration test. The reference here is `default_content_for_slug/1` — the
  descriptor, i.e. the `@federation_preamble` constant.
  """

  use Platform.DataCase, async: false

  alias Platform.Orchestration.PromptTemplates

  @moduletag :regression

  @slug "federation.preamble"

  @migration_module Platform.Repo.Migrations.ForceUpdateFederationPreambleContent

  @migration_path Path.join([
                    __ENV__.file
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname(),
                    "priv/repo/migrations/20260816120000_force_update_federation_preamble_content.exs"
                  ])

  @posture_heading "## Execution posture — close the ticket"

  # The pre-change shape: a preamble with the old sections and no posture
  # section at all.
  @stale_content """
  ## Subagent-spawn discipline

  STALE PREAMBLE BODY — this row predates task 01a00c99 stage 4.

  ## Tool-name conventions (dot vs underscore)

  Dots on the HTTP endpoint, underscores in the wrapper.
  """

  setup do
    unless Code.ensure_loaded?(@migration_module) do
      Code.require_file(@migration_path)
    end

    :ok
  end

  defp stale_the_row! do
    template = PromptTemplates.get_template_by_slug(@slug)
    refute is_nil(template), "#{@slug} must be seeded before this test can stale it"

    {:ok, staled} = PromptTemplates.update_template(template, %{content: @stale_content})

    # Before-state, asserted rather than assumed.
    assert staled.content == @stale_content
    refute staled.content =~ @posture_heading

    staled
  end

  describe "the posture section in the shipped constant" do
    test "carries the close-the-ticket posture" do
      text = PromptTemplates.federation_preamble()

      assert text =~ @posture_heading
      assert text =~ "Close the ticket."
      assert text =~ "Do not dither"
      assert text =~ "do not fear breaking something"
      assert text =~ "a healthy pipeline fixes what gets broken"

      assert text =~ "Confidence in execution is expected of every agent here",
             "the ask is confidence across the federation, not only the orchestrator"
    end

    test "derives the confidence from the adversarial machinery" do
      text = PromptTemplates.federation_preamble()

      assert text =~ "That confidence is derived, not asserted."

      assert text =~ "You can move fast because the adversarial machinery catches you",
             "the load-bearing sentence: speed is a consequence of the checks, not a " <>
               "substitute for them"

      assert text =~
               "Speed is the dividend of that machinery, so weakening it is how you " <>
                 "lose the speed"

      assert text =~ "Never trade a check for pace."
    end

    test "names the four disciplines that stay, and does NOT license bypassing them" do
      text = PromptTemplates.federation_preamble()

      # Positive half. Asserted in the SAME test as the refutes below so that
      # deleting the whole section cannot make those refutes vacuously true.
      assert text =~ "Report a surviving mutant; do not patch it away."
      assert text =~ "Call a flake a flake; never record one as a pass."
      assert text =~ "Never self-approve a human gate."
      assert text =~ "Stop when a measurement says the work is unnecessary"

      # Refutes: nothing in the preamble may read as permission to bypass the
      # machinery it just told the agent to rely on.
      refute text =~ ~r/skip (the )?(check|test|validation|gate)/i
      refute text =~ ~r/(don'?t|do not|no need to) (bother )?(test|verify|run the (test|check))/i
      refute text =~ ~r/approve (it|the gate) yourself/i
      refute text =~ ~r/(ship|merge|land) (it )?(without|before) (a )?(test|review|verif)/i
    end

    test "targets dithering, not verification" do
      text = PromptTemplates.federation_preamble()

      assert text =~ "an assignment IS the authorization"
      assert text =~ "Re-deriving an established fact, or re-litigating a settled decision"
      assert text =~ "Reporting activity as if it were a result"
      assert text =~ "Hedging a call you are competent to make"

      assert text =~ "Raise a genuine blocker or a decision only a human can make",
             "escalation must stay explicitly legitimate, or the section reads as " <>
               "\"never escalate\""
    end

    test "keeps every existing section header, in order, and adds no placeholder" do
      text = PromptTemplates.federation_preamble()

      headers = [
        @posture_heading,
        "## Subagent-spawn discipline",
        "## Organization Context",
        "## Writing to Org Memory",
        "## Skill discovery",
        "## Submitting evidence for a manual_approval validation",
        "## Tool-name conventions (dot vs underscore)"
      ]

      indexes =
        Enum.map(headers, fn header ->
          assert {index, _} = :binary.match(text, header),
                 "missing stable anchor #{inspect(header)} — downstream stack members " <>
                   "(scribe_completion, triage_dispatch) reference these headers"

          index
        end)

      assert indexes == Enum.sort(indexes),
             "existing headers must not be reordered; the new section goes on top"

      # `interpolate/2` is a single pass, so any `{{x}}` here would ship
      # literally into every dispatch.
      refute text =~ ~r/\{\{\w+\}\}/
    end
  end

  describe "up/0 against a deployed-shaped (stale) row" do
    test "rewrites content to the shipped default, restoring the posture section" do
      stale_the_row!()

      assert :ok = @migration_module.up()

      reloaded = PromptTemplates.get_template_by_slug(@slug)

      assert reloaded.content == PromptTemplates.default_content_for_slug(@slug)
      refute reloaded.content == @stale_content
      assert reloaded.content =~ @posture_heading
    end

    test "the row and the fallback agree after up/0" do
      # The invariant this whole stack maintains: the served row and the
      # in-code fallback must be byte-identical, so no dispatch can depend on
      # which one it happened to read.
      stale_the_row!()

      assert :ok = @migration_module.up()

      row = PromptTemplates.get_template_by_slug(@slug)

      assert row.content == PromptTemplates.federation_preamble()

      # The equality above is TRUE BY CONSTRUCTION on its own: since stage 2
      # `federation_preamble/0` reads the row, so it agrees with a stale row
      # just as happily as with a migrated one (verified — a no-op `up/0`
      # leaves this pair equal). What makes the pair meaningful is that the
      # agreed-upon value is the shipped one.
      assert row.content == PromptTemplates.default_content_for_slug(@slug)
      assert PromptTemplates.federation_preamble() =~ @posture_heading
    end

    test "is idempotent — a second up/0 changes nothing" do
      stale_the_row!()

      assert :ok = @migration_module.up()
      first = PromptTemplates.get_template_by_slug(@slug).content

      assert :ok = @migration_module.up()
      assert PromptTemplates.get_template_by_slug(@slug).content == first
    end

    test "leaves the dispatch.planning row alone" do
      before = PromptTemplates.get_template_by_slug("dispatch.planning")
      refute is_nil(before)

      {:ok, _} =
        PromptTemplates.update_template(before, %{
          content: "PLANNING SENTINEL BODY {{federation_preamble}}"
        })

      stale_the_row!()
      assert :ok = @migration_module.up()

      assert PromptTemplates.get_template_by_slug("dispatch.planning").content ==
               "PLANNING SENTINEL BODY {{federation_preamble}}"
    end

    test "seed_defaults/0 does NOT repair the stale row — the migration is load-bearing" do
      staled = stale_the_row!()

      :ok = PromptTemplates.seed_defaults()

      after_seed = PromptTemplates.get_template_by_slug(@slug)

      assert after_seed.content == staled.content,
             "seed_defaults/0 must leave an existing row untouched (insert-only)"

      refute after_seed.content =~ @posture_heading,
             "which is exactly why a deployed environment would never read the new section"

      assert :ok = @migration_module.up()
      assert PromptTemplates.get_template_by_slug(@slug).content =~ @posture_heading
    end
  end

  describe "up/0 when the row is absent" do
    test "skips without raising and does not create the row" do
      template = PromptTemplates.get_template_by_slug(@slug)
      refute is_nil(template)
      {:ok, _} = PromptTemplates.delete_template(template)
      assert is_nil(PromptTemplates.get_template_by_slug(@slug))

      assert :ok = @migration_module.up()

      assert is_nil(PromptTemplates.get_template_by_slug(@slug)),
             "up/0 must skip an absent row, not insert one — seed_defaults/0 owns first boot"
    end
  end
end
