defmodule Platform.Repo.Migrations.AddMeetingSpaceToIntentPromptTemplatesTest do
  @moduledoc """
  Regression coverage for
  `20260801040000_add_meeting_space_to_intent_prompt_templates`.

  Migrations run to `:up` before ExUnit boots, so the post-state of the
  LIVE rows is directly assertable — which is the whole point of testing
  here rather than in the handlers. Asserting that a handler's
  `@fallback_prompt` gained a section proves nothing about production:
  `PromptTemplates.render_template/2` renders the ROW, and every migrated
  environment already had all six rows from `20260801001500`. That is
  PR #658's lesson restated — a list changed only in code never reaches an
  already-migrated database.

  Mirrors `update_action_items_prompt_for_live_meeting_test.exs` in shape,
  including the force-update control, which is the assertion this file
  exists for: an INSERT-only implementation (`nil -> create`,
  `_existing -> :skip`, which is what `seed_defaults/0` does) would leave
  all six old bodies sitting there while every content assertion below
  still passed on rows the 20260801001500 seed happened to leave behind.
  """
  use Platform.DataCase, async: false

  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo.Migrations.AddMeetingSpaceToIntentPromptTemplates
  alias Platform.Responsibilities.Handlers

  @slugs [
    "meetings.action_items.v1",
    "meetings.open_question.v1",
    "meetings.brief_worthy.v1",
    "meetings.decision_recorded.v1",
    "meetings.visual_adjust.v1",
    "meetings.interaction_design.v1"
  ]

  # Migration source lives under `priv/repo/migrations/` and is not on the
  # compile path — walk up from `test/platform/repo/migrations/<this>.exs`
  # to `apps/platform/` and back down. `mix test` runs `ecto.migrate` in
  # the same BEAM, so the module is usually already loaded; requiring it
  # unconditionally would emit a redefinition warning, and not requiring
  # it at all would make this file depend on that scheduling detail.
  @migration_path Path.join([
                    __ENV__.file
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname(),
                    "priv/repo/migrations/20260801040000_add_meeting_space_to_intent_prompt_templates.exs"
                  ])

  setup_all do
    unless Code.ensure_loaded?(AddMeetingSpaceToIntentPromptTemplates) do
      Code.require_file(@migration_path)
    end

    :ok
  end

  describe "the live rows after the migration" do
    test "all six name the space and declare the variable" do
      for slug <- @slugs do
        assert %{content: content, variables: variables} =
                 PromptTemplates.get_template_by_slug(slug),
               "#{slug} is missing entirely"

        assert content =~ "{{meeting_space_id}}", "#{slug} names no space"
        assert "meeting_space_id" in variables, "#{slug} does not declare meeting_space_id"
      end
    end

    test "nothing else in the bodies was lost to the re-seed" do
      # A force-update rewrites the whole body, so the risk is not that
      # the marker is missing but that the rewrite silently reverted the
      # rest to an older draft. Each anchor below is a line the
      # 20260801001500 seed established and that this migration must have
      # carried forward verbatim.
      anchors = %{
        "meetings.action_items.v1" => "Changing nothing is a correct outcome",
        "meetings.open_question.v1" => "Check first whether it was already answered",
        "meetings.brief_worthy.v1" => "A brief accretes; it does not append",
        "meetings.decision_recorded.v1" => "Your artifact is org memory, not a canvas",
        "meetings.visual_adjust.v1" => "Meeting-speed means one adjustment, visible now",
        "meetings.interaction_design.v1" =>
          "You are working on states, transitions and affordances"
      }

      for {slug, anchor} <- anchors do
        assert %{content: content} = PromptTemplates.get_template_by_slug(slug)
        assert content =~ anchor, "#{slug} lost #{inspect(anchor)} in the re-seed"
      end
    end

    test "the row and the handler's rollout fallback agree, marker for marker" do
      # They are separately authored copies of one body — the migration
      # carries a literal so a replay years from now does not depend on
      # the module, and the handler carries the heredoc so a missing row
      # degrades visibly. Content is allowed to drift (an operator retunes
      # the row live, which is the point); the MARKER SET is not, because
      # `prompt_assigns/1` feeds one set to both and an extra marker on
      # either side renders as `""` on the DB path and literally on the
      # fallback path.
      handlers = [
        Handlers.MeetingActionItems,
        Handlers.MeetingOpenQuestion,
        Handlers.MeetingBriefWorthy,
        Handlers.MeetingDecisionRecorded,
        Handlers.MeetingVisualAdjust,
        Handlers.MeetingInteractionDesign
      ]

      for handler <- handlers do
        slug = handler.template_slug()
        assert %{content: content} = PromptTemplates.get_template_by_slug(slug)

        assert markers(content) == markers(handler.fallback_prompt()),
               "#{slug}: row markers #{inspect(MapSet.to_list(markers(content)))} != " <>
                 "fallback markers #{inspect(MapSet.to_list(markers(handler.fallback_prompt())))}"
      end
    end
  end

  describe "force-update control" do
    test "up/0 overwrites rows that already hold a space-less body" do
      # Put the pre-migration shape back on every row — exactly what a
      # migrated environment has before this migration runs — then call
      # up/0 directly and assert each row moved.
      for slug <- @slugs do
        template = PromptTemplates.get_template_by_slug(slug)
        assert template, "the row must exist for this control to mean anything"

        {:ok, reverted} =
          PromptTemplates.update_template(template, %{
            content: "PRE-SPACE BODY for #{slug}\n\n{{meeting_canvases}}\n",
            variables: ["meeting_intent", "transcript_window", "meeting_canvases", "org_identity"]
          })

        # Positive control on the setup itself: the rows really are in the
        # old shape before up/0 runs, so a green result below cannot come
        # from the revert having quietly failed.
        refute reverted.content =~ "{{meeting_space_id}}"
        refute "meeting_space_id" in reverted.variables
      end

      assert :ok = AddMeetingSpaceToIntentPromptTemplates.up()

      for slug <- @slugs do
        assert %{content: content, variables: variables} =
                 PromptTemplates.get_template_by_slug(slug)

        assert content =~ "{{meeting_space_id}}", "#{slug} was skipped rather than updated"
        assert "meeting_space_id" in variables
        refute content =~ "PRE-SPACE BODY"
      end
    end

    test "up/0 CREATES a row that is missing rather than skipping it" do
      # A fresh database whose `up/0` runs before any `seed_defaults/0`.
      # The sibling `20260801001500` raises on a missing slug because it
      # was force-updating a row an EARLIER migration owned; these six are
      # owned by the migration immediately before this one, so "not there"
      # is honestly answered by inserting.
      slug = "meetings.brief_worthy.v1"
      template = PromptTemplates.get_template_by_slug(slug)
      {:ok, _} = PromptTemplates.delete_template(template)
      refute PromptTemplates.get_template_by_slug(slug)

      assert :ok = AddMeetingSpaceToIntentPromptTemplates.up()

      assert %{content: content} = PromptTemplates.get_template_by_slug(slug)
      assert content =~ "{{meeting_space_id}}"
    end
  end

  defp markers(content) do
    ~r/\{\{(\w+)\}\}/
    |> Regex.scan(content, capture: :all_but_first)
    |> List.flatten()
    |> MapSet.new()
  end
end
