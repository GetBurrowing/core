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

  # SUPERSEDED THE SAME NIGHT, and these assertions record the reversal
  # rather than being deleted for having gone red.
  #
  # `20260731194500` gave this row a body asking the recipient to return
  # a JSON `operations` object, which an 801-line server-side
  # reconciler then applied. Traced hours later:
  # `Router.invoke_handle_output/3` is reachable only from
  # `run_external_dispatch/5` and this key's assignee is native, so the
  # reconciler had never executed and the JSON was produced for nobody —
  # while the recipient, an agent holding canvas tools, was being told
  # not to use them. `20260801001500_seed_meeting_intent_prompt_templates`
  # force-updates the row to a body that asks for the work instead of
  # for a payload.
  #
  # Both migrations run to `:up` before ExUnit boots, so what is
  # assertable here is the LATER row. The earlier migration's own
  # behaviour is still covered, in isolation, by the force-update
  # control below — that describe reverts the row and calls its `up/0`
  # directly, so it is unaffected by the supersession and is left alone.
  describe "the meetings.action_items.v1 row after the supersession" do
    test "still frames the work as happening during a live meeting" do
      assert %{content: content} = PromptTemplates.get_template_by_slug(@slug)

      # The one thing `20260731194500` established that survived intact.
      # Mid-meeting framing was never the defect; the payload contract was.
      for anchor <- ["on a live call", "still talking", "as it happens"] do
        assert content =~ anchor,
               "body missing mid-meeting anchor #{inspect(anchor)}"
      end

      refute content =~ "A meeting just ended"
      refute content =~ "finished meeting transcript"
    end

    test "asks for the canvas work itself, not for a JSON payload" do
      assert %{content: content} = PromptTemplates.get_template_by_slug(@slug)

      # THE reversal. Asserted as a refutation pair rather than by
      # deleting the old assertions: "the body no longer asks for
      # operations" and "the body asks for the edit" are different
      # claims, and only the second one fails if the body is emptied.
      refute content =~ ~s({"operations"),
             "the recipient holds canvas tools; nothing parses a JSON payload from it"

      for op <- [~s("op": "add"), ~s("op": "update"), ~s("op": "remove")] do
        refute content =~ op, "operation verb #{inspect(op)} outlived the contract that used it"
      end

      assert content =~ "patch it"
      assert content =~ "create it"
      assert content =~ "Reconcile, do not append"
    end

    test "reads the meeting's canvas inventory, not a resolved single canvas" do
      assert %{content: content} = PromptTemplates.get_template_by_slug(@slug)

      # `action_items_canvas` was a server-resolved slot that no longer
      # exists. An unfed marker renders to "" on the DB path, which
      # leaves a heading with nothing under it — read by a model as a
      # section that was truncated rather than one that is empty. So its
      # absence matters as much as the new marker's presence.
      refute content =~ "{{action_items_canvas}}"
      assert content =~ "{{meeting_canvases}}"
      assert content =~ "ONE running action-items canvas"
    end

    test "makes the excerpt the ground truth and the classifier's label a guess" do
      assert %{content: content} = PromptTemplates.get_template_by_slug(@slug)

      assert content =~ "Read the excerpt, not the label"
      assert content =~ "ground truth"

      # Rowan's constraint, unchanged across both bodies: item identity
      # must never hang off the classifier's dedupe key. It is the
      # reason the classifier is allowed to stay cheap.
      refute content =~ "dedupe_key",
             "the body must not reference the classifier's dedupe_key"
    end

    test "names declining as a correct outcome" do
      assert %{content: content} = PromptTemplates.get_template_by_slug(@slug)

      # New in the superseding body and load-bearing: most classified
      # utterances should change nothing, and a recipient that feels
      # obliged to act produces a list nobody trusts.
      assert content =~ "Changing nothing is a correct outcome"
    end

    test "declares exactly the variables its body interpolates" do
      assert %{content: content, variables: variables} =
               PromptTemplates.get_template_by_slug(@slug)

      # Derived, not listed: the declared set must equal the set of
      # markers actually present, in both directions. A listed variable
      # the body never uses is as much a defect as a marker nothing
      # declares. This is the assertion that would have caught the
      # `{{action_items_canvas}}` marker being orphaned by the slot's
      # removal, had the row not been rewritten at the same time.
      declared = MapSet.new(variables)
      present = markers(content)

      assert MapSet.size(present) > 0, "body interpolates nothing"
      assert declared == present, "variables #{inspect(variables)} != markers #{inspect(present)}"
    end

    test "the slug the handler renders is the slug these migrations update" do
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
