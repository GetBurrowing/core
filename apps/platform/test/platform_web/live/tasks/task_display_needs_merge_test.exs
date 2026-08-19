defmodule PlatformWeb.Tasks.TaskDisplayNeedsMergeTest do
  @moduledoc """
  Task 01a01a4a stage 4 — the Deploy column's "needs you" chip.

  Pure-function half of the coverage. `task_display_status/2` is the single
  edit that feeds all four card call sites (`board_component.ex:462, 563,
  971, 1194`), so the label and the emitted classes are asserted here once,
  and the rendered-DOM consequences (one chip per card, no doubled chip)
  are asserted against the live board in `tasks_live_test.exs`.

  THE BOTH-CLASSES ASSERTION IS THE POINT OF THIS FILE. The design canvas
  ("Deploy column: the needs-you chip", rev 4) approves returning the chip
  component's own emitted classes into a `{label, class}` tuple, and names
  the price: `chip-warning` alone sets only `--chip-label` — no tint, no
  padding, no radius — so a half-pair renders as bare amber text in the
  right position, which photographs clean and survives a screenshot review.
  A tuple of class strings makes that a typo. Hence an assertion on BOTH
  class names, independent of any screenshot.
  """
  use ExUnit.Case, async: true

  alias Platform.Tasks.Task
  alias PlatformWeb.Tasks.TaskDisplay

  @stamp %{"awaiting_human_action" => "merge"}

  describe "task_display_status/2 — human-only merge gate" do
    test "a deploying task carrying the stamp renders the needs-merge label" do
      {label, _class} =
        TaskDisplay.task_display_status(
          %Task{status: "deploying", metadata: @stamp},
          :awaiting_human_merge
        )

      assert label == "needs merge"
    end

    test "the emitted class carries BOTH chip classes, not just the tone" do
      {_label, class} =
        TaskDisplay.task_display_status(
          %Task{status: "deploying", metadata: @stamp},
          :awaiting_human_merge
        )

      classes = String.split(class, " ", trim: true)

      # `chip-soft` carries the tint, padding and radius; `chip-warning`
      # carries only `--chip-label`. Either one alone is a rendering bug
      # that no screenshot catches. Assert each token independently so a
      # dropped half fails on the name of the half that was dropped.
      assert "chip-soft" in classes,
             "chip-soft is missing — the chip has no tint, padding or radius and " <>
               "renders as bare coloured text. Emitted: #{inspect(class)}"

      assert "chip-warning" in classes,
             "chip-warning is missing — the chip renders in the neutral fallback " <>
               "tone. Emitted: #{inspect(class)}"

      # Byte-identical to what `CoreComponents.chip/1` emits for tone="warning".
      assert class == "chip-soft chip-warning"
    end

    test "the chip is warning-toned, never error-toned" do
      # `--color-error` is deliberately unused on this state: red reads as a
      # FAILED deploy, and this is a healthy state waiting on a person.
      {_label, class} =
        TaskDisplay.task_display_status(
          %Task{status: "deploying", metadata: @stamp},
          :awaiting_human_merge
        )

      refute String.contains?(class, "chip-error")
      refute String.contains?(class, "chip-info")
    end

    test "a deploying task WITHOUT the stamp keeps the neutral deploying chip" do
      {label, class} =
        TaskDisplay.task_display_status(%Task{status: "deploying", metadata: %{}}, nil)

      assert label == "Deploying"
      assert class == "badge badge-outline"
      refute label == "needs merge"
    end

    test "a deploying task with a DIFFERENT awaiting_human_action value is not a merge gate" do
      {label, class} =
        TaskDisplay.task_display_status(
          %Task{status: "deploying", metadata: %{"awaiting_human_action" => "approve"}},
          nil
        )

      assert label == "Deploying"
      assert class == "badge badge-outline"
    end

    test "the stamp on a NON-deploying task does not produce the chip" do
      {label, _class} =
        TaskDisplay.task_display_status(%Task{status: "in_progress", metadata: @stamp}, nil)

      refute label == "needs merge"
    end

    test "precedence demotion silences the chip: the stamp alone cannot emit it" do
      # THE STAGE-5 REGRESSION, at the unit level. The task still carries
      # `metadata["awaiting_human_action"] == "merge"`, but a pending
      # review_request outranks the merge gate in
      # `Tasks.needs_human_action_reason/2`, so the resolved reason is
      # `:review_request_pending` and this render site must fall back to the
      # neutral chip. Before stage 5 this function re-derived the gate from
      # metadata and emitted "needs merge" regardless — a second decider that
      # disagreed with the resolver exactly here.
      {label, class} =
        TaskDisplay.task_display_status(
          %Task{status: "deploying", metadata: @stamp},
          :review_request_pending
        )

      assert label == "Deploying"
      assert class == "badge badge-outline"
      refute label == "needs merge"
    end

    test "the chip is keyed on the reason, not on metadata, for every other reason" do
      for reason <- [nil, :review_request_pending, :plan_pending_review, :validation_failed] do
        {label, _class} =
          TaskDisplay.task_display_status(%Task{status: "deploying", metadata: @stamp}, reason)

        refute label == "needs merge",
               "reason #{inspect(reason)} is not the merge gate but still emitted the chip — " <>
                 "the metadata stamp is deciding again"
      end
    end
  end

  describe "stack_member_action_label/1" do
    test "the stack row and the data-action-reason hook agree with the board" do
      assert PlatformWeb.Tasks.StackStyles.stack_member_action_label(:awaiting_human_merge) ==
               {"needs merge", "awaiting_human_merge"}
    end
  end
end
