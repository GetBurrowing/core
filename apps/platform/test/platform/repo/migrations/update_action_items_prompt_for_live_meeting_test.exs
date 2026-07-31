defmodule Platform.Repo.Migrations.UpdateActionItemsPromptForLiveMeetingTest do
  @moduledoc """
  Regression coverage for
  `20260731194500_update_action_items_prompt_for_live_meeting`
  (task 019fb90f-36e3 stage 3).

  Migrations run to `:up` before ExUnit boots, so the post-state of the
  LIVE row is directly assertable — which is the whole point of testing
  here rather than in the handler. Asserting that a seed FILE contains
  new wording proves nothing: `PromptTemplates.seed_defaults/0` is
  INSERT-only and the `meetings.action_items.v1` row has existed since
  `20260703120200`, so a seed edit is a guaranteed no-op on every
  migrated environment.

  Mirrors `seed_prompt_template_intent_classify_test.exs` in shape, and
  adds the force-update control that file has no need of: this
  migration's entire job is overwriting a row that already exists, and
  an INSERT-only implementation would leave the old body in place while
  every content assertion below still passed on the body the 20260703
  seed happened to leave there.
  """
  use Platform.DataCase, async: false

  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo.Migrations.UpdateActionItemsPromptForLiveMeeting
  alias Platform.Responsibilities.Handlers.MeetingActionItems

  @slug "meetings.action_items.v1"

  # Migration source lives under `priv/repo/migrations/` and is not on
  # the compile path — walk up from
  # `test/platform/repo/migrations/<this>.exs` to `apps/platform/` and
  # back down. `mix test` runs `ecto.migrate` in the same BEAM, so the
  # module is usually already loaded; requiring it unconditionally would
  # emit a redefinition warning, and not requiring it at all would make
  # this file depend on that scheduling detail.
  # Five levels: test/platform/repo/migrations/<this>.exs -> apps/platform.
  @migration_path Path.join([
                    __ENV__.file
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname(),
                    "priv/repo/migrations/20260731194500_update_action_items_prompt_for_live_meeting.exs"
                  ])

  setup_all do
    unless Code.ensure_loaded?(UpdateActionItemsPromptForLiveMeeting) do
      Code.require_file(@migration_path)
    end

    :ok
  end

  describe "the migrated meetings.action_items.v1 row" do
    test "frames the work as happening during a live meeting" do
      assert %{content: content} = PromptTemplates.get_template_by_slug(@slug)

      for anchor <- [
            "DURING a live meeting",
            "A meeting is happening right now",
            "still talking"
          ] do
        assert content =~ anchor,
               "migrated body missing mid-meeting anchor #{inspect(anchor)}"
      end
    end

    test "instructs create-when-absent, modify-when-present, and reconcile" do
      assert %{content: content} = PromptTemplates.get_template_by_slug(@slug)

      assert content =~ "{{action_items_canvas}}"
      assert content =~ "CURRENT contents"
      assert content =~ "the items you add create it"
      assert content =~ "you are MODIFYING it"
      assert content =~ "rather than appending blindly"

      # The three reconciliation moves, not just the word "reconcile".
      assert content =~ "mark that item complete"
      assert content =~ "amend that item"
      assert content =~ "remove it"
    end

    test "makes the excerpt the ground truth and the classifier's label a guess" do
      assert %{content: content} = PromptTemplates.get_template_by_slug(@slug)

      assert content =~ "Read the excerpt before the label"
      assert content =~ "cheap fast model's label"
      assert content =~ "ground truth"

      # Item identity must not hang off the classifier's dedupe key —
      # Rowan's constraint, and the reason the classifier stays dumb.
      refute content =~ "dedupe_key",
             "the body must not reference the classifier's dedupe_key"
    end

    test "emits the operations shape stage 4 consumes" do
      assert %{content: content} = PromptTemplates.get_template_by_slug(@slug)

      assert content =~ ~s({"operations")

      for op <- [~s("op": "add"), ~s("op": "update"), ~s("op": "remove")] do
        assert content =~ op, "migrated body missing operation #{inspect(op)}"
      end

      assert content =~ ~s("match"), "update/remove need a match field"
      assert content =~ ~s({"operations": []}), "an empty operation list must be named as valid"
    end

    test "no longer describes a finished meeting" do
      assert %{content: content, description: description} =
               PromptTemplates.get_template_by_slug(@slug)

      refute content =~ "A meeting just ended"
      refute content =~ "finished meeting transcript"
      refute description =~ "finished"
    end

    test "declares exactly the variables its body interpolates" do
      assert %{content: content, variables: variables} =
               PromptTemplates.get_template_by_slug(@slug)

      # Derived, not listed: the declared set must equal the set of
      # markers actually present, in both directions. A listed variable
      # the body never uses is as much a defect as a marker nothing
      # declares.
      declared = MapSet.new(variables)
      present = markers(content)

      assert MapSet.size(present) > 0, "migrated body interpolates nothing"
      assert declared == present, "variables #{inspect(variables)} != markers #{inspect(present)}"
    end

    test "the slug the handler renders is the slug this migration updates" do
      assert MeetingActionItems.template_slug() == @slug
      assert PromptTemplates.get_template_by_slug(@slug)
    end
  end

  describe "force-update control" do
    test "up/0 overwrites a row that already holds the old body" do
      # The control this whole file exists for. Put the pre-stage-3 body
      # back on the live row — exactly what a migrated environment has
      # before this migration runs — then run the migration's up/0
      # directly and assert the row moved. An INSERT-only implementation
      # (`nil -> create`, `_existing -> :skip`, which is what
      # `seed_defaults/0` does and what the 20260703 seed did) leaves the
      # old body sitting there and turns this red.
      old_content = """
      You are the Meeting Scribe's `meetings.action_items` responsibility. A meeting just ended; you extract concrete action items.
      Input: the meeting transcript + org identity, both in your context.
      Output: a JSON object matching {"action_items": ["<owner>: <verb-first item> (<due when known>)", ...]}.
      """

      template = PromptTemplates.get_template_by_slug(@slug)
      assert template, "the row must exist for this control to mean anything"

      {:ok, reverted} =
        PromptTemplates.update_template(template, %{
          content: old_content,
          description:
            "Meeting Scribe extracts concrete action items from a finished meeting transcript.",
          variables: ["meeting_transcript", "org_identity"]
        })

      # Positive control on the setup itself: the row really is in the
      # old shape before up/0 runs, so a green result below cannot come
      # from the revert having quietly failed.
      assert reverted.content =~ "A meeting just ended"
      assert reverted.description =~ "finished"

      assert :ok = UpdateActionItemsPromptForLiveMeeting.up()

      assert %{content: content, description: description, variables: variables} =
               PromptTemplates.get_template_by_slug(@slug)

      refute content =~ "A meeting just ended"
      refute description =~ "finished"
      assert content =~ "DURING a live meeting"
      assert content =~ "{{action_items_canvas}}"
      assert "action_items_canvas" in variables
      refute "meeting_transcript" in variables
    end

    test "up/0 is a no-op rather than a crash when the row is absent" do
      # The `nil -> :skip` guard: an operator who deleted the row must
      # not fail the whole migration run.
      template = PromptTemplates.get_template_by_slug(@slug)
      {:ok, _} = PromptTemplates.delete_template(template)

      assert :ok = UpdateActionItemsPromptForLiveMeeting.up()
      assert PromptTemplates.get_template_by_slug(@slug) == nil
    end
  end

  defp markers(content) do
    ~r/\{\{(\w+)\}\}/
    |> Regex.scan(content)
    |> Enum.map(fn [_full, marker] -> marker end)
    |> MapSet.new()
  end
end
