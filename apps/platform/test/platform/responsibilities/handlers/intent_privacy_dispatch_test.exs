defmodule Platform.Responsibilities.Handlers.IntentPrivacyDispatchTest do
  @moduledoc """
  The candid-register floor at the Router seam, on a NATIVE assignee
  (task `01a0e58f`, acceptance 2 and 3).

  ## Why the refusal lives in gather_context, not build_prompt

  A `build_prompt/1` refusal does not stop a native dispatch:
  `Router.dispatch_native/6` classifies `{:error, _}` as a refused prompt
  and still sends the agent a signal, with `prompt_status` `:no_work`.
  That signal carries `metadata.space_id`, which is what invites the
  agent into the meeting space. The only code-level refusal that stops
  both paths is `gather_context/2` returning `{:error, reason}`:
  `Router.refuse_dispatch/5` then sends nothing and calls
  `handle_refusal/3`.

  The red run of this file (tests committed before the implementation)
  is the evidence for that premise: the Priya signal was DELIVERED.

  ## The invite, modelled

  `CaptureDispatcher` stands in for `AgentResponder.maybe_dispatch/1`. It
  records the signal and then does what the funnel does with it: calls
  `DispatchMembership.ensure_writable/3` with the signal's
  `metadata.space_id`. So "the meeting space gains no participant" is
  something the red run could violate, not an assertion that holds by
  construction.

  ## Named mutations — each applied and reverted, measured on the rig
  (`intent_privacy_test.exs` + `test/platform/responsibilities`, 1103 tests)

    * **M-p1** — move the check from `gather_context/2` to
      `build_prompt/1` in all three handlers. Measured: 10 failures. All
      three tests in "a native dispatch of a candid line" fail with
      `{:ok, :dispatched}` — the signal is delivered again, which is the
      premise correction — plus the six handler-level gather refusals
      and the independence test.
    * **M-p4** — remove `handle_refusal/3` from `MeetingOpenQuestion`.
      Measured: 2 failures — the open-question case here (row left
      `:dispatched`) and the row-closing test in
      `meeting_open_question_test.exs`.

  ## Found by this file: the provider dispatch table

  The first green attempt still failed here for brief_worthy and
  open_question: `Providers.Meetings.handle_refusal/3` routed ONLY
  `meetings.action_items` and answered `:ok` for every other key, so the
  handlers' new `handle_refusal/3` was never reached from the Router and
  the row stayed `:dispatched`. The handler-level unit tests could not
  see that. The table now probes each handler for the callback.

  Rows are synthesised; names are invented; the shape was filed from the
  2026-09-14 one-to-one.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.IntentQueue
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.BuiltIns
  alias Platform.Responsibilities.Handlers.MeetingActionItems
  alias Platform.Responsibilities.Handlers.MeetingBriefWorthy
  alias Platform.Responsibilities.Handlers.MeetingOpenQuestion
  alias Platform.Responsibilities.Registry
  alias Platform.Responsibilities.Router
  alias Platform.Roles
  alias Platform.Roles.Role

  @priya "Priya to deliver list of demands to Marcus by end of week"

  defmodule CaptureDispatcher do
    @moduledoc false
    def maybe_dispatch(signal) do
      pid = Application.get_env(:platform, :intent_privacy_capture_pid)
      if is_pid(pid), do: send(pid, {:captured_signal, signal})

      metadata = Map.get(signal, :metadata) || %{}

      invite =
        Platform.Chat.DispatchMembership.ensure_writable(
          Map.get(metadata, :space_id),
          Map.get(metadata, :agent_id),
          source: :intent_privacy_dispatch_test
        )

      if is_pid(pid), do: send(pid, {:invite_result, invite})

      :ok
    end
  end

  @logged_modules [
    Router,
    MeetingActionItems,
    MeetingBriefWorthy,
    MeetingOpenQuestion,
    Platform.Meetings.IntentContext
  ]

  setup do
    Application.put_env(:platform, :intent_privacy_capture_pid, self())

    Application.put_env(
      :platform,
      :responsibility_router_native_dispatcher,
      {CaptureDispatcher, :maybe_dispatch}
    )

    # The log assertion is only worth something if the info-level lines
    # on this path are actually emitted into the capture.
    Enum.each(@logged_modules, &Logger.put_module_level(&1, :debug))

    _registry =
      start_supervised!(
        {Registry,
         name: Module.concat([Registry, "IntentPrivacy#{System.unique_integer([:positive])}"]),
         providers: BuiltIns.providers()}
      )

    on_exit(fn ->
      Application.delete_env(:platform, :intent_privacy_capture_pid)
      Application.delete_env(:platform, :responsibility_router_native_dispatcher)
      Enum.each(@logged_modules, &Logger.delete_module_level/1)
    end)

    :ok
  end

  defp wire_native_assignee(responsibility_key) do
    # A fixed key: `roles_key_check` rejects digits, so a unique suffix
    # cannot be used. The sandbox rolls the rows back per test.
    role_key = "historian"

    Repo.insert!(
      %Role{key: role_key, name: "Historian", description: "test", icon: "hero-star"},
      on_conflict: :nothing,
      conflict_target: :key
    )

    Repo.insert!(
      %Platform.Roles.RoleResponsibility{
        role_key: role_key,
        responsibility_key: responsibility_key
      },
      on_conflict: :nothing,
      conflict_target: [:role_key, :responsibility_key]
    )

    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "intent-privacy-native-#{System.unique_integer([:positive])}",
        name: "Privacy Seam Assignee",
        status: "active",
        kind: "native",
        workspace_id: nil
      })
      |> Repo.insert!()

    {:ok, _} = Roles.assign_role(role_key, agent.id)
    agent
  end

  defp create_meeting! do
    {:ok, project} =
      Platform.Tasks.create_project(%{name: "Candid #{System.unique_integer([:positive])}"})

    {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: "One to one"})
    meeting
  end

  defp dispatched_row!(meeting, intent) do
    {:ok, row} =
      IntentQueue.enqueue(meeting.id, %{
        room_id: "room-#{System.unique_integer([:positive])}",
        chunk_excerpt: @priya,
        classified_intent: intent,
        confidence: 0.95
      })

    {:ok, dispatched} = IntentQueue.transition(meeting.id, row.id, :dispatched)
    on_exit(fn -> IntentQueue.stop(meeting.id) end)
    dispatched
  end

  defp fire(row, meeting, intent_row, intent, excerpt) do
    meta = %{
      kind: :event_topic,
      topic: "meeting:#{intent}_intent",
      payload: %{
        intent_id: intent_row.id,
        meeting_id: meeting.id,
        chunk_excerpt: excerpt,
        classified_intent: intent,
        confidence: 0.95,
        speaker: "Priya"
      }
    }

    log = capture_log(fn -> send(self(), {:fire_result, Router.fire_trigger(row, meta, %{})}) end)
    assert_receive {:fire_result, result}
    {result, log}
  end

  describe "a native dispatch of a candid line" do
    for {handler, intent} <- [
          {MeetingActionItems, "action_items"},
          {MeetingBriefWorthy, "brief_worthy"},
          {MeetingOpenQuestion, "open_question"}
        ] do
      test "#{inspect(handler)}: refused at gather, nothing sent, row closed, no invite, no leak" do
        handler = unquote(handler)
        intent = unquote(intent)

        # Meeting FIRST: creating a meeting seats the role's agents in its
        # space, which would make the invite below a no-op in both runs.
        meeting = create_meeting!()

        [spec] = handler.register()
        {:ok, row} = Responsibilities.upsert_by_key(spec)
        _agent = wire_native_assignee(row.key)

        intent_row = dispatched_row!(meeting, intent)
        participants_before = length(Chat.list_participants(meeting.chat_space_id))

        {result, log} = fire(row, meeting, intent_row, intent, @priya)

        assert result == {:error, {:context_gather_refused, :candid_register}}

        # Nothing reached the agent responder: no signal, so no invite and
        # no prompt. On the red run this is where the Priya signal showed
        # up.
        refute_receive {:captured_signal, _signal}, 200

        closed = IntentQueue.get(meeting.id, intent_row.id) |> elem(1)
        assert closed.status == :dispatch_failed
        assert closed.dispatch_failure_reason == :candid_register

        assert length(Chat.list_participants(meeting.chat_space_id)) == participants_before

        refute log =~ "Priya"
        refute log =~ "demands"
      end
    end
  end

  # Task 01a0e58f, acceptance 4: a NEAR-MISS in a space with no canvas is
  # refused at gather too, on the same native seam, for the same reason —
  # a `build_prompt/1` refusal would still deliver the signal. M-n3 (move
  # the check to build_prompt) is what this describe exists to kill.
  describe "a native dispatch of a near-miss into an empty space" do
    for {handler, intent} <- [
          {MeetingActionItems, "action_items"},
          {MeetingBriefWorthy, "brief_worthy"},
          {MeetingOpenQuestion, "open_question"}
        ] do
      test "#{inspect(handler)}: no signal, row :dispatch_failed with :near_miss_without_canvas" do
        handler = unquote(handler)
        intent = unquote(intent)

        meeting = create_meeting!()

        [spec] = handler.register()
        {:ok, row} = Responsibilities.upsert_by_key(spec)
        _agent = wire_native_assignee(row.key)

        intent_row = dispatched_row!(meeting, intent)
        excerpt = "My contention is we log an action item for the retro"

        {result, log} = fire(row, meeting, intent_row, intent, excerpt)

        assert result == {:error, {:context_gather_refused, :near_miss_without_canvas}}
        refute_receive {:captured_signal, _signal}, 200

        closed = IntentQueue.get(meeting.id, intent_row.id) |> elem(1)
        assert closed.status == :dispatch_failed
        assert closed.dispatch_failure_reason == :near_miss_without_canvas

        refute log =~ "contention"
      end
    end
  end

  # POSITIVE CONTROL. The same seam with an ordinary line must deliver a
  # signal and invite the agent; otherwise every refute above would hold
  # on a rig that never dispatches at all.
  describe "a native dispatch of an ordinary line" do
    test "is delivered and invites the agent into the meeting space" do
      meeting = create_meeting!()

      [spec] = MeetingActionItems.register()
      {:ok, row} = Responsibilities.upsert_by_key(spec)
      agent = wire_native_assignee(row.key)

      intent_row = dispatched_row!(meeting, "action_items")
      participants_before = length(Chat.list_participants(meeting.chat_space_id))

      {result, _log} =
        fire(
          row,
          meeting,
          intent_row,
          "action_items",
          "Dana to send the sprint notes to the team by Friday"
        )

      assert result == {:ok, :dispatched}
      assert_receive {:captured_signal, signal}, 2_000
      assert signal.metadata.space_id == meeting.chat_space_id
      assert_receive {:invite_result, invite}, 2_000
      assert invite == {:ok, :invited}

      participants = Chat.list_participants(meeting.chat_space_id)
      assert length(participants) > participants_before
      assert Enum.any?(participants, &(&1.participant_id == agent.id))
    end
  end
end
