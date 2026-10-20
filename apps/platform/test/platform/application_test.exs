defmodule Platform.ApplicationTest do
  @moduledoc """
  Regression assertions for the boot-time supervision tree.

  These tests guard the invariants the M8 stage 6 cutover-deletion
  checklist depends on. In particular, **`SystemEventScheduler` must
  still be in the supervision tree** through M8 — the cutover follow-up
  task (NOT this stage) is what removes it, gated on
  `mix responsibilities.cutover_report` showing zero divergence for
  seven days. Deleting it earlier breaks the dual-write signal and
  blinds operators to whether the router path agrees with the legacy
  one.

  Each test uses the live application children list. We don't start a
  second supervisor; we just inspect the spec to confirm the relevant
  children are declared.
  """
  use ExUnit.Case, async: true

  describe "supervision tree" do
    test "SystemEventScheduler is declared as a child (M8 cutover guard)" do
      # `:start_system_event_scheduler` is `false` in `config/test.exs`,
      # so the scheduler isn't actually started during the test suite —
      # but the application module still references it in the supervision
      # tree build. We re-run the build with the flag flipped on to
      # confirm the membership invariant.
      prev = Application.get_env(:platform, :start_system_event_scheduler)

      try do
        Application.put_env(:platform, :start_system_event_scheduler, true)
        children = build_children()
        assert Platform.Agents.SystemEventScheduler in children
      after
        if is_nil(prev) do
          Application.delete_env(:platform, :start_system_event_scheduler)
        else
          Application.put_env(:platform, :start_system_event_scheduler, prev)
        end
      end
    end

    test "ResponsibilityRouter is declared as a child when enabled" do
      prev = Application.get_env(:platform, :start_responsibility_router)

      try do
        Application.put_env(:platform, :start_responsibility_router, true)
        children = build_children()
        assert Platform.Responsibilities.Router in children
      after
        if is_nil(prev) do
          Application.delete_env(:platform, :start_responsibility_router)
        else
          Application.put_env(:platform, :start_responsibility_router, prev)
        end
      end
    end

    test "CutoverMonitor is declared as a child when enabled" do
      prev = Application.get_env(:platform, :start_cutover_monitor)

      try do
        Application.put_env(:platform, :start_cutover_monitor, true)
        children = build_children()
        assert Platform.Responsibilities.CutoverMonitor in children
      after
        if is_nil(prev) do
          Application.delete_env(:platform, :start_cutover_monitor)
        else
          Application.put_env(:platform, :start_cutover_monitor, prev)
        end
      end
    end

    test "IntentDispatcher is declared as a child when :start_meeting_intent_dispatcher true" do
      prev = Application.get_env(:platform, :start_meeting_intent_dispatcher)

      try do
        Application.put_env(:platform, :start_meeting_intent_dispatcher, true)
        children = build_children()
        assert Platform.Meetings.IntentDispatcher in children
      after
        if is_nil(prev) do
          Application.delete_env(:platform, :start_meeting_intent_dispatcher)
        else
          Application.put_env(:platform, :start_meeting_intent_dispatcher, prev)
        end
      end
    end

    test "IntentDispatcher is absent when :start_meeting_intent_dispatcher false" do
      prev = Application.get_env(:platform, :start_meeting_intent_dispatcher)

      try do
        Application.put_env(:platform, :start_meeting_intent_dispatcher, false)
        children = build_children()
        refute Platform.Meetings.IntentDispatcher in children
      after
        if is_nil(prev) do
          Application.delete_env(:platform, :start_meeting_intent_dispatcher)
        else
          Application.put_env(:platform, :start_meeting_intent_dispatcher, prev)
        end
      end
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  # The children `start/2` would build at boot under the full role, from
  # the same `Platform.Application.children/2` it calls and the same gate
  # reader (task 01a155a6). It used to mirror the pipeline by hand, which
  # could only see the gates someone remembered to copy.
  defp build_children do
    Platform.Application.children(:full, &Platform.Application.boot_flag/3)
  end
end
