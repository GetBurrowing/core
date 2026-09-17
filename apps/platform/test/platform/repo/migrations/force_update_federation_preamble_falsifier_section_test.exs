defmodule Platform.Repo.Migrations.ForceUpdateFederationPreambleFalsifierSectionTest do
  @moduledoc """
  Coverage for `20260916234500_force_update_federation_preamble_falsifier_section`
  (task 01a0a5f5 stage 4).

  READ THIS BEFORE ADDING AN ASSERTION — the obvious migration test is vacuous
  by construction. In the test database the `federation.preamble` row is
  created by the seed migration running `PromptTemplates.seed_defaults/0`
  against the CURRENT code, so it already equals this branch's default before
  anything here runs; `assert row.content =~ "state its falsifier"` passes
  with the migration file deleted. Worse, the migration reads its own
  comparand from the descriptor, so `row.content ==
  default_content_for_slug/1` is an identity after `up/0` and can never go
  red. Every migration test below therefore STALES THE ROW FIRST, asserts the
  absence of the section by query, and only then reads the delta.

  A second trap specific to this stack: `PromptTemplates.federation_preamble/0`
  READS THE ROW. Once the row is stale it returns the stale text, so it cannot
  serve as the expected value inside a migration test. The reference here is
  `default_content_for_slug/1` — the descriptor, i.e. the
  `@federation_preamble` constant.
  """

  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Platform.Orchestration.PromptTemplates

  @moduletag :regression

  @slug "federation.preamble"

  @migration_module Platform.Repo.Migrations.ForceUpdateFederationPreambleFalsifierSection

  @migration_path Path.join([
                    __ENV__.file
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname(),
                    "priv/repo/migrations/20260916234500_force_update_federation_preamble_falsifier_section.exs"
                  ])

  @falsifier_heading "## Filing a ticket — state its falsifier"
  @falsifier_sentence "**State what would show this ticket is wrong.**"
  @placement_instruction "**Put it ABOVE the prescriptive content, not at the end.**"

  # The pre-change shape: a preamble with the old sections and no falsifier
  # section at all.
  @stale_content """
  ## Execution posture — close the ticket

  STALE PREAMBLE BODY — this row predates task 01a0a5f5 stage 4.

  ## Subagent-spawn discipline

  Spawn a subagent for task-scoped work.

  ## Tool-name conventions (dot vs underscore)

  Dots on the HTTP endpoint, underscores in the wrapper.
  """

  setup do
    unless Code.ensure_loaded?(@migration_module) do
      Code.require_file(@migration_path)
    end

    :ok
  end

  # Drives the row STALE and asserts the before-state BY QUERY. This is the
  # demonstrated red the whole file rests on: without it every assertion below
  # would hold with `up/0` replaced by `:ok`.
  defp stale_the_row! do
    template = PromptTemplates.get_template_by_slug(@slug)
    refute is_nil(template), "#{@slug} must be seeded before this test can stale it"

    {:ok, _} = PromptTemplates.update_template(template, %{content: @stale_content})

    # Re-read from the database rather than trusting the changeset's return.
    requeried = PromptTemplates.get_template_by_slug(@slug)

    assert requeried.content == @stale_content
    refute requeried.content =~ @falsifier_heading
    refute requeried.content =~ @falsifier_sentence
    refute requeried.content =~ @placement_instruction

    requeried
  end

  describe "the stale-first setup itself" do
    test "the row genuinely lacks the falsifier section before up/0 runs" do
      # Named on its own so the demonstrated red is a result, not a side
      # effect of some other test's setup. Edit that turns this red: making
      # @stale_content contain the section.
      staled = stale_the_row!()

      refute staled.content =~ "falsifier"
      assert staled.content =~ "STALE PREAMBLE BODY"
    end
  end

  describe "up/0 against a deployed-shaped (stale) row" do
    test "rewrites content to the shipped default, adding the falsifier section" do
      stale_the_row!()

      assert :ok = @migration_module.up()

      reloaded = PromptTemplates.get_template_by_slug(@slug)

      refute reloaded.content == @stale_content
      assert reloaded.content =~ @falsifier_heading
      assert reloaded.content =~ @falsifier_sentence
      assert reloaded.content =~ @placement_instruction
      assert reloaded.content == PromptTemplates.default_content_for_slug(@slug)
    end

    test "the migrated row keeps every pre-existing section header, in order" do
      stale_the_row!()
      assert :ok = @migration_module.up()

      content = PromptTemplates.get_template_by_slug(@slug).content

      headers = [
        "## Execution posture — close the ticket",
        @falsifier_heading,
        "## Subagent-spawn discipline",
        "## Organization Context",
        "## Writing to Org Memory",
        "## Skill discovery",
        "## Submitting evidence for a manual_approval validation",
        "## Tool-name conventions (dot vs underscore)"
      ]

      indexes =
        Enum.map(headers, fn header ->
          assert {index, _} = :binary.match(content, header),
                 "missing stable anchor #{inspect(header)} in the MIGRATED ROW"

          index
        end)

      assert indexes == Enum.sort(indexes),
             "the served row must not reorder the header anchors downstream stack " <>
               "members (scribe_completion, triage_dispatch) reference"

      refute content =~ ~r/\{\{\w+\}\}/
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

      refute after_seed.content =~ @falsifier_heading,
             "which is exactly why a deployed environment would never read the new section"

      assert :ok = @migration_module.up()
      assert PromptTemplates.get_template_by_slug(@slug).content =~ @falsifier_heading
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

  describe "down/0" do
    test "is an explicit no-op and leaves the migrated row in place" do
      stale_the_row!()
      assert :ok = @migration_module.up()
      migrated = PromptTemplates.get_template_by_slug(@slug).content

      assert :ok = @migration_module.down()

      assert PromptTemplates.get_template_by_slug(@slug).content == migrated
    end
  end

  describe "the render path — the row beats the constant" do
    @sentinel "## Sentinel row body\n\nROW CONTENT, not the constant.\n"

    test "federation_preamble/0 returns the ROW's content, not @federation_preamble" do
      # The acceptance-3 fact of this ticket, under test rather than under
      # assumption: seed a row that DIFFERS from the constant and read the
      # render path. Edit that turns this red: making `federation_preamble/0`
      # return the constant (that is precisely the regression this ticket's
      # migration exists to survive).
      template = PromptTemplates.get_template_by_slug(@slug)
      refute is_nil(template)

      {:ok, _} = PromptTemplates.update_template(template, %{content: @sentinel})

      constant = PromptTemplates.default_content_for_slug(@slug)
      refute constant == @sentinel, "the sentinel must differ from the constant to discriminate"

      rendered = PromptTemplates.federation_preamble()

      assert rendered == @sentinel
      refute rendered == constant
      refute rendered =~ @falsifier_heading

      # Bound, stated so nobody overstates this test: the row's content passes
      # through `resolve_content/3`, the experiment-variant resolver. The
      # accurate rule is *a variant beats the row, the row beats the
      # constant* — not "the row is what renders". With no subject in assigns
      # no experiment can apply, which is the case pinned here.
    end

    test "a blank row still falls back to the constant" do
      # Written through `Repo.update_all`, not `update_template/2`: the
      # changeset's `validate_required(:content)` trims, so a whitespace-only
      # body cannot be produced through the context at all. The fallback
      # guards against a row that got blanked some other way (a script, a
      # direct SQL edit), which is exactly the shape written here.
      {1, _} =
        Platform.Repo.update_all(
          from(t in "prompt_templates", where: t.slug == ^@slug),
          set: [content: "   \n  "]
        )

      assert PromptTemplates.federation_preamble() ==
               PromptTemplates.default_content_for_slug(@slug)
    end

    test "after up/0 the render path serves the falsifier section" do
      stale_the_row!()

      refute PromptTemplates.federation_preamble() =~ @falsifier_heading,
             "the stale row must reach the render path — otherwise the assertion below " <>
               "is about the constant, not about the migration"

      assert :ok = @migration_module.up()

      assert PromptTemplates.federation_preamble() =~ @falsifier_heading
    end
  end
end
