defmodule Platform.Meetings.IntentDispatcherTest do
  @moduledoc """
  Tests for `Platform.Meetings.IntentDispatcher` — the global GenServer
  that drives every meeting's ack-gated intent queue and hands each
  claimed intent to the runtime linked to the agent assigned to its
  `target_role`.

  Rewritten twice for task 019f70b8: stage 3 replaced the batch drain
  with a per-meeting serial cursor, and stage 4 replaced the two
  chat-shaped dispatch surfaces with a single runtime-attention
  broadcast. The behaviours under test now are:

    * **runtime targeting (AC2)** — a claimed intent lands on
      `runtime:<runtime_id>` as an `"attention"` signal within 500ms,
      carrying the addressable `intent_id`
    * **`:no_runtime` is retained (not dropped)** — a target agent with
      no linked AgentRuntime produces a visible `:dispatch_failed` row,
      not silence
    * **cancellation reaches the subagent (AC7)** — cancelling an
      in-flight intent broadcasts `"intent_cancelled"` carrying the
      `subagent_id` the target stamped at ack time
    * **`:cancelled_late` (AC8)** — a completion that beat the cancel is
      a distinct, explainable status, not a crash
    * **serial cursor (AC3)** — three intents for the same target go out
      one at a time; a `:working` ack does NOT advance, `:completed` does
    * **ack timeout (AC4)** and **`:no_ack_spawn_failed` vs `:timed_out`
      (AC6)**

  ## Nothing here hands the dispatcher a target

  Every case seeds a role assignment and a runtime link and then lets
  the production chain derive the rest: `target_role` → `Roles.agent_id_for_role/1`
  → `%Agent{}` → `Federation.get_runtime_for_agent/1` → `runtime:<runtime_id>`.
  The tests subscribe to the topic they expect that chain to produce and
  assert the row's `target_agent_id` was stamped by the dispatcher —
  they never enqueue one. A harness that passed the target in would go
  green against a dispatcher that ignored roles entirely, which is
  exactly the class of hole stage 3 found in `append_segment/2`.

  Async-false: the dispatcher subscribes to the shared
  `meeting:intent_enqueued` topic and the per-meeting queue supervisor
  is application-global. Test-scoped dispatcher instances boot under
  unique names via `start_supervised/1`.
  """

  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  import Platform.TenancyFixtures

  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Chat
  alias Platform.Federation
  alias Platform.Federation.ToolAuthorization
  alias Platform.Federation.ToolSurface
  alias Platform.Meetings
  alias Platform.Meetings.IntentClassifier
  alias Platform.Meetings.IntentCorrection
  alias Platform.Meetings.IntentCorrections
  alias Platform.Meetings.IntentDispatcher
  alias Platform.Meetings.IntentQueue
  alias Platform.Meetings.IntentRouting
  alias Platform.Repo
  alias Platform.Roles

  setup do
    # Shared sandbox so the queue supervisor's children (started outside
    # this test's ownership chain) can see the test's schema. Mirrors
    # `TaskRouterWatcherTest`'s setup.
    Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, {:shared, self()})

    # Bump this module's log level to :info so `capture_log` can
    # actually see the "unknown target_role" line the once-per-boot
    # spam suppressor emits. Mirrors `IntentClassifierTest`.
    Logger.put_module_level(Platform.Meetings.IntentDispatcher, :info)

    on_exit(fn ->
      Logger.delete_module_level(Platform.Meetings.IntentDispatcher)
      Application.delete_env(:platform, Platform.Meetings.IntentQueue)
    end)

    :ok
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  # A fresh meeting id per test, with its queue torn down on exit. Queue
  # owners are per-meeting so tests never share one; a unique id IS the
  # isolation.
  defp new_meeting!(opts \\ []) do
    meeting_id = Platform.Types.UUIDv7.generate()
    {:ok, _pid} = IntentQueue.ensure_started(meeting_id, opts)
    on_exit(fn -> IntentQueue.stop(meeting_id) end)
    meeting_id
  end

  # A meeting id backed by a REAL `org -> project -> meeting` chain,
  # for the stage-6 cases that assert on a correction row's derived
  # `org_id`. Everything else in this file uses `new_meeting!/1`'s bare
  # UUID, which is correct for the queue (Registry-keyed, no DB) and
  # useless the moment a durable row has to resolve a tenant.
  defp new_real_meeting! do
    org_id = Platform.TenancyFixtures.acme_org_id()

    {:ok, project} =
      Platform.Tasks.create_project(%{
        name: "Intent Dispatcher #{System.unique_integer([:positive])}",
        org_id: org_id
      })

    {:ok, space} =
      Platform.Chat.create_space(%{
        name: "Intent Dispatcher Space #{System.unique_integer([:positive])}",
        slug: "intent-dispatcher-#{System.unique_integer([:positive])}",
        kind: "meeting"
      })

    meeting =
      %Platform.Meetings.Meeting{}
      |> Platform.Meetings.Meeting.changeset(%{
        project_id: project.id,
        chat_space_id: space.id,
        slug: "dispatch-#{System.unique_integer([:positive])}",
        name: "Intent Dispatcher Meeting",
        livekit_room_name: "meeting-#{Ecto.UUID.generate()}"
      })
      |> Repo.insert!()

    {:ok, _pid} = IntentQueue.ensure_started(meeting.id)
    on_exit(fn -> IntentQueue.stop(meeting.id) end)

    {meeting, org_id}
  end

  # Deliberately never sets `target_agent_id` — that field is the
  # dispatcher's output, and seeding it would hide a broken role→agent
  # →runtime chain behind a value the test supplied.
  defp enqueue!(meeting_id, attrs) do
    {:ok, row} =
      IntentQueue.enqueue(
        meeting_id,
        Map.merge(
          %{
            room_id: "room-#{System.unique_integer([:positive])}",
            dedupe_key: "dk-#{System.unique_integer([:positive])}",
            classified_intent: "book_followup",
            chunk_excerpt: "we should book a follow-up on the onboarding funnel",
            target_role: "designer",
            confidence: 0.9,
            transcript_chunk_id: "chunk-#{System.unique_integer([:positive])}"
          },
          attrs
        )
      )

    row
  end

  defp status_of(meeting_id, intent_id) do
    case IntentQueue.get(meeting_id, intent_id) do
      {:ok, row} -> row.status
      other -> other
    end
  end

  # Poll until `intent_id` reaches `expected`, or blow up with the
  # status it actually settled on. Dispatch is async (PubSub notify →
  # dispatcher mailbox → queue call), so every status assertion that
  # follows an enqueue has to be a wait rather than a read.
  defp await_status(meeting_id, intent_id, expected, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_status(meeting_id, intent_id, expected, deadline)
  end

  defp do_await_status(meeting_id, intent_id, expected, deadline) do
    actual = status_of(meeting_id, intent_id)

    cond do
      actual == expected ->
        {:ok, row} = IntentQueue.get(meeting_id, intent_id)
        row

      System.monotonic_time(:millisecond) > deadline ->
        flunk(
          "expected intent #{intent_id} to reach #{inspect(expected)}, got #{inspect(actual)}"
        )

      true ->
        Process.sleep(10)
        do_await_status(meeting_id, intent_id, expected, deadline)
    end
  end

  defp attach_telemetry!(events) when is_list(events) do
    handler_id = "intent-dispatcher-test-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _ ->
        send(parent, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  defp start_dispatcher!(opts \\ []) do
    name = :"intent_dispatcher_#{System.unique_integer([:positive])}"

    # Push tick out to something the test never trips into so the hot
    # PubSub path and the periodic tick can be exercised independently.
    child_opts =
      opts
      |> Keyword.put(:name, name)
      |> Keyword.put_new(:tick_interval_ms, 60_000)

    {:ok, pid} = start_supervised({IntentDispatcher, child_opts})

    # Let `init/1` finish subscribing before the test enqueues, or the
    # very first notify lands in nobody's mailbox.
    Process.sleep(20)

    {pid, name}
  end

  defp create_agent!(overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          slug: "intentdisp-agent-#{System.unique_integer([:positive])}",
          name: "Intent Dispatcher Test Agent",
          status: "active",
          kind: "native"
        },
        overrides
      )

    %Agent{}
    |> Agent.changeset(attrs)
    |> Repo.insert!()
  end

  defp create_user!, do: root_admin!()

  # The only agent shape that can receive an intent since stage 4: one
  # with a linked AgentRuntime. Agent `kind` is irrelevant to dispatch
  # now, which is why the default here is a plain native agent.
  defp create_runtime_agent!(overrides \\ %{}) do
    agent = create_agent!(overrides)
    user = create_user!()

    {:ok, runtime} =
      Federation.register_runtime(user.id, %{
        runtime_id: "intentdisp-rt-#{System.unique_integer([:positive])}"
      })

    {:ok, linked} = Federation.link_agent(runtime, agent)

    {linked, runtime}
  end

  defp subscribe_runtime!(%{runtime_id: runtime_id}) do
    :ok = PlatformWeb.Endpoint.subscribe("runtime:#{runtime_id}")
    runtime_id
  end

  defp assign_role!(role_key, %Agent{id: id}) do
    # Roles are DB-seeded; `role_assignments.role_key` has a unique
    # index, so if a sibling test left a row we clear it first.
    :ok = Roles.unassign_role(role_key)
    {:ok, _} = Roles.assign_role(role_key, id)
    :ok
  end

  # Seed the whole production chain for `role_key` in one call and
  # subscribe to the topic it should resolve to.
  defp seed_target!(role_key \\ "designer") do
    {agent, runtime} = create_runtime_agent!()
    :ok = assign_role!(role_key, agent)
    subscribe_runtime!(runtime)
    {agent, runtime}
  end

  # Which bundles actually register `intent_ack`, read out of the catalogue
  # instead of named here. Hardcoding "meetings" would make these cases
  # silently vacuous the next time the tool moves: the strip below would
  # remove a bundle that no longer carries it, the fixture would still be
  # able to ack, and case 1 would fail for a reason that looks like the
  # dispatcher's fault.
  defp ack_carrier_bundles do
    Enum.filter(ToolSurface.all_bundles(), fn bundle ->
      Enum.any?(ToolSurface.list_tools([bundle]), &(&1.name == "intent_ack"))
    end)
  end

  # A role -> agent -> runtime chain where the runtime's ability to call
  # `intent_ack` is the ONE thing that varies.
  #
  # The starting point is PROVEN rather than assumed: `register_runtime/2`
  # is passed no `allowed_bundles` key, and the row is re-read from the
  # database and held to `AgentRuntime.default_allowed_bundles/0`. A
  # hand-written literal list would pass whatever the real defaults became.
  defp seed_ack_target!(role_key, can_ack?) do
    {agent, runtime} = create_runtime_agent!()

    defaults = AgentRuntime.default_tool_profile()

    assert Federation.get_runtime(runtime.id).allowed_bundles == defaults,
           "the fixture must track whatever the defaults actually are"

    carriers = ack_carrier_bundles()

    refute carriers == [],
           "no bundle registers intent_ack, so `defaults -- carriers` cannot revoke " <>
             "anything and the negative fixture below would silently BE the positive one"

    bundles =
      if can_ack?, do: Enum.uniq(defaults ++ carriers), else: defaults -- carriers

    {:ok, runtime} = Federation.update_allowed_bundles(runtime, bundles)

    # The fixture is proved to be what the case needs it to be, on the same
    # code path production authorizes through, BEFORE anything is enqueued.
    expected = if can_ack?, do: :ok, else: {:error, :forbidden}
    assert ToolAuthorization.authorize("intent_ack", runtime) == expected

    # ANTI-VACUITY on the fixture itself. A runtime stripped to an EMPTY
    # surface would be refused for every tool, so `:cannot_ack` below would
    # be true of a runtime that cannot do anything at all — which is not the
    # gap being closed. This one keeps a real surface and lacks exactly one
    # capability.
    refute ToolAuthorization.tool_names(runtime) == [],
           "a runtime with no tools at all is refused for everything and proves nothing"

    :ok = assign_role!(role_key, agent)
    subscribe_runtime!(runtime)

    {agent, runtime}
  end

  # Subscribe to EVERY topic the responsibility fork can broadcast on,
  # read from `IntentRouting` rather than listed here. A hardcoded list
  # would go stale the next time an intent is added and would quietly
  # narrow `intent_broadcasts_received/1` to the topics it still knew
  # about — the failure mode being that a fork firing on the NEW topic
  # looks like silence.
  #
  # NB `intent_broadcasts_received/1` below drains greedily: it empties
  # every atom-headed 2-tuple from the mailbox, not only routing ones.
  # Call it after the `assert_receive`s a case needs, never before.
  defp subscribe_all_intent_topics! do
    for %{topic: topic} <- IntentRouting.entries() do
      :ok = Phoenix.PubSub.subscribe(Platform.PubSub, topic)
    end

    :ok
  end

  # Every responsibility-fork broadcast sitting in the mailbox, as
  # `{event_atom, payload}`. One drain window for all topics rather than
  # a `refute_receive` per topic, so the wait does not grow with the
  # routing table — and so a failure NAMES the intent that fired instead
  # of just reporting a mailbox that was not empty.
  defp intent_broadcasts_received(timeout \\ 300) do
    events = MapSet.new(IntentRouting.entries(), & &1.event)
    drain_intent_broadcasts(events, System.monotonic_time(:millisecond) + timeout, [])
  end

  defp drain_intent_broadcasts(events, deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Enum.reverse(acc)
    else
      receive do
        {event, payload} when is_atom(event) ->
          acc = if MapSet.member?(events, event), do: [{event, payload} | acc], else: acc
          drain_intent_broadcasts(events, deadline, acc)
      after
        remaining -> Enum.reverse(acc)
      end
    end
  end

  # Pull the `dispatch_auto_invite` event for ONE space out of the mailbox,
  # skipping any that belong to a different space. Matching on `space_id`
  # rather than taking the first event is what lets a single test drive two
  # dispatches and compare their outcomes.
  defp await_invite_outcome(space_id, timeout \\ 2_000) do
    receive do
      {:telemetry, [:platform, :chat, :dispatch_auto_invite], _measurements,
       %{space_id: ^space_id, source: :meeting_intent} = metadata} ->
        metadata.outcome

      {:telemetry, [:platform, :chat, :dispatch_auto_invite], _measurements, _other} ->
        await_invite_outcome(space_id, timeout)
    after
      timeout ->
        flunk("no dispatch_auto_invite telemetry for space #{inspect(space_id)}")
    end
  end

  defp participant_row_count(agent_id) do
    Repo.aggregate(
      from(p in Platform.Chat.Participant,
        where: p.participant_type == "agent" and p.participant_id == ^agent_id
      ),
      :count
    )
  end

  defp in_flight_count(meeting_id) do
    meeting_id
    |> IntentQueue.list()
    |> Enum.count(&(&1.status in IntentQueue.in_flight_statuses()))
  end

  defp ack!(intent_id, subagent_id, status) do
    Platform.Federation.ToolSurface.execute(
      "intent_ack",
      %{"intent_id" => intent_id, "subagent_id" => subagent_id, "status" => status},
      %{}
    )
  end

  # ── Runtime targeting (AC2) ────────────────────────────────────────────────

  describe "runtime targeting" do
    test "a claimed intent reaches the target's runtime topic as an attention signal" do
      {agent, runtime} = seed_target!()

      meeting_id = new_meeting!()
      start_dispatcher!()

      row = enqueue!(meeting_id, %{classified_intent: "book_followup", confidence: 0.87})

      # AC2's 500ms budget, measured from enqueue through classify →
      # notify → claim → resolve → broadcast.
      assert_receive %Phoenix.Socket.Broadcast{
                       topic: topic,
                       event: "attention",
                       payload: %{
                         signal: %{
                           reason: "meeting_intent_dispatch",
                           intent_id: signal_intent_id,
                           meeting_id: signal_meeting_id,
                           classified_intent: "book_followup",
                           confidence: 0.87,
                           target_agent_id: signal_agent_id,
                           transcript_chunk_excerpt: excerpt
                         }
                       }
                     },
                     500

      assert topic == "runtime:#{runtime.runtime_id}"
      assert signal_intent_id == row.id
      assert signal_meeting_id == meeting_id
      # Derived by the dispatcher from the role, never supplied here.
      assert signal_agent_id == agent.id
      assert excerpt == "we should book a follow-up on the onboarding funnel"

      dispatched = await_status(meeting_id, row.id, :dispatched)
      assert dispatched.dispatched_at
      assert dispatched.target_agent_id == agent.id
      assert dispatched.target_agent_slug == agent.slug
      assert IntentQueue.cursor(meeting_id) == row.id
    end

    test "the signal goes to runtime:<runtime_id>, never runtime:<agent_id>" do
      {agent, _runtime} = create_runtime_agent!()
      :ok = assign_role!("designer", agent)

      # Subscribe to the WRONG topic — the one the task description
      # originally specified. A dispatcher keyed by the agent uuid would
      # publish where no RuntimeChannel ever joins, so this refute is
      # the only thing standing between us and a silent zero-delivery
      # dispatch with a fully green suite.
      :ok = PlatformWeb.Endpoint.subscribe("runtime:#{agent.id}")

      meeting_id = new_meeting!()
      start_dispatcher!()

      row = enqueue!(meeting_id, %{classified_intent: "wrong-topic-probe"})

      # It definitely went out...
      await_status(meeting_id, row.id, :dispatched)
      # ...and not here.
      refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 200
    end

    test "the row is :dispatched before the broadcast leaves, so an instant ack lands" do
      {_agent, _runtime} = seed_target!()

      meeting_id = new_meeting!()
      start_dispatcher!()

      row = enqueue!(meeting_id, %{classified_intent: "instant-ack"})

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{intent_id: intent_id}}
                     },
                     1_000

      # An ack racing the dispatcher's own bookkeeping must succeed —
      # if the row were still `:queued` at broadcast time this would
      # come back `{:invalid_ack_state, :queued}`.
      assert {:ok, acked} = ack!(intent_id, "instant-probe", "working")
      assert acked.status == :acked
      assert intent_id == row.id
    end
  end

  # ── Target space naming ────────────────────────────────────────────────────

  describe "the dispatch names the meeting's chat space" do
    test "the target is a participant of that space by the time the signal lands" do
      {agent, runtime} = seed_target!()
      {meeting, _org_id} = new_real_meeting!()
      start_dispatcher!()

      # Negative control, CAPTURED rather than assumed. Without it, "the agent
      # is a participant afterwards" is equally consistent with "it always
      # was" — and `Meetings.create_meeting/1` adding the assignee would be a
      # perfectly plausible reason for that, so this is not a hypothetical.
      refute Chat.get_agent_participant(meeting.chat_space_id, agent.id)

      row = enqueue!(meeting.id, %{classified_intent: "name-the-space"})

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: topic,
                       event: "attention",
                       payload: %{signal: signal}
                     },
                     1_000

      assert topic == "runtime:#{runtime.runtime_id}"

      # Both halves. See `IntentRuntimeAdapterTest` for why the refute is not
      # decoration: an envelope carrying BOTH keys satisfies the assert alone
      # and re-pins a live client-side permission prompt.
      assert signal.target_space_id == meeting.chat_space_id
      refute Map.has_key?(signal, :space_id)

      # The invite committed BEFORE the broadcast (Federation.AttentionDispatch
      # orders it that way), so it is already durable at this point rather
      # than something we have to wait for.
      participant = Chat.get_agent_participant(meeting.chat_space_id, agent.id)
      assert participant.participant_type == "agent"
      assert participant.attention_mode == "mention"
      assert participant.role == "member"

      dispatched = await_status(meeting.id, row.id, :dispatched)
      assert dispatched.dispatch_failure_reason == nil
    end

    test "an unresolvable space and an archived one report DIFFERENT outcome atoms" do
      # The whole point of the eight distinct refusal atoms is that an
      # operator can tell these two apart. A guard that collapsed every
      # refusal to one shared value would satisfy a per-case
      # `assert outcome == :whatever` in every test that happened to exercise
      # a single situation — so this case exercises BOTH and asserts they
      # differ, which no collapse can survive.
      {agent, _runtime} = seed_target!()
      attach_telemetry!([[:platform, :chat, :dispatch_auto_invite]])

      {archived_meeting, _org_id} = new_real_meeting!()
      {:ok, _} = Chat.archive_space(Repo.get!(Chat.Space, archived_meeting.chat_space_id))

      # A bare UUID with no `meetings` row behind it — the queue is
      # Registry-keyed and never required one.
      orphan_meeting_id = new_meeting!()

      start_dispatcher!()

      archived_row = enqueue!(archived_meeting.id, %{classified_intent: "archived-space"})
      await_status(archived_meeting.id, archived_row.id, :dispatched)

      orphan_row = enqueue!(orphan_meeting_id, %{classified_intent: "no-space"})
      await_status(orphan_meeting_id, orphan_row.id, :dispatched)

      archived_outcome = await_invite_outcome(archived_meeting.chat_space_id)
      orphan_outcome = await_invite_outcome(nil)

      assert archived_outcome == :space_archived
      assert orphan_outcome == :no_space_named
      refute archived_outcome == orphan_outcome

      # Neither refusal produced a row anywhere, and neither turned into a
      # red queue row: a writability problem is not a reachability problem.
      assert participant_row_count(agent.id) == 0

      assert IntentQueue.get(archived_meeting.id, archived_row.id)
             |> elem(1)
             |> Map.get(:dispatch_failure_reason) == nil

      assert IntentQueue.get(orphan_meeting_id, orphan_row.id)
             |> elem(1)
             |> Map.get(:dispatch_failure_reason) == nil
    end

    test "the envelope omits target_space_id entirely when no space resolves" do
      seed_target!()
      meeting_id = new_meeting!()
      start_dispatcher!()

      enqueue!(meeting_id, %{classified_intent: "omit-the-key"})

      assert_receive %Phoenix.Socket.Broadcast{event: "attention", payload: %{signal: signal}},
                     1_000

      # Absent, not present-and-null. A `target_space_id: nil` on the wire
      # reads to a runtime as "there is a space and it is nothing".
      refute Map.has_key?(signal, :target_space_id)
      refute Map.has_key?(signal, :space_id)
    end

    test "deleting a meeting's chat space deletes the meeting — why :space_not_found is unreachable here" do
      # This pins a PREMISE, not this stage's code. The stage's test brief
      # asked for a case where `meetings.chat_space_id` points at a deleted
      # space and the invite reports `:space_not_found`. That state cannot
      # exist: the FK is `on_delete: :delete_all`, so deleting the space takes
      # the meeting with it and the dispatcher resolves `nil` —
      # `:no_space_named`, covered above.
      #
      # The dispatcher still passes the column through UNFILTERED rather than
      # verifying the space exists first, which is what keeps `:space_not_found`
      # reachable the moment this cascade changes. If this test ever fails,
      # that branch has become live and wants its own case.
      {meeting, _org_id} = new_real_meeting!()
      space = Repo.get!(Chat.Space, meeting.chat_space_id)

      {:ok, _} = Repo.delete(space)

      refute Repo.get(Platform.Meetings.Meeting, meeting.id)
    end
  end

  # ── Responsibility fork (task 019fb90f-36e3 stage 1) ───────────────────────
  #
  # Some classified intents are NOT handed to a role's runtime. Each
  # goes out as a single global `{<event>, payload}` broadcast for the
  # Responsibilities Router, and the row stays on the meeting's serial
  # cursor until that intent's handler closes it.
  #
  # `action_items` was the only such intent when this block was written;
  # 2026-07-31 added five more, and `Platform.Meetings.IntentRouting` is
  # now the single table saying which. So the fork is no longer "one
  # intent vs everything else" and the cases below stopped naming a
  # specific intent as the dividing line — what divides is whether the
  # intent HAS a routing row.
  #
  # The positive cases and the negative controls are a pair. A fork that
  # matched EVERY intent would pass the positive cases alone; a fork
  # that matched nothing would pass the controls alone. Only both
  # together pin the fork to exactly the routed set.

  describe "responsibility fork — routed intents vs everything else" do
    test "the row goes to the responsibility topic and NOT to a runtime" do
      # `meeting_scribe` is the role the classifier actually stamps on
      # these rows, and it is seeded here with a real runtime. That is
      # what makes the refute below mean something: the role path is
      # fully wired and WOULD have produced an attention broadcast, so
      # the silence is the fork's doing rather than a missing fixture.
      {agent, _runtime} = seed_target!("meeting_scribe")

      :ok = Phoenix.PubSub.subscribe(Platform.PubSub, "meeting:action_item_intent")

      meeting_id = new_meeting!()
      start_dispatcher!()

      row =
        enqueue!(meeting_id, %{
          classified_intent: "action_items",
          target_role: "meeting_scribe",
          chunk_excerpt: "Priya will revert the onboarding flow by Friday",
          confidence: 0.91
        })

      assert_receive {:action_item_intent, payload}, 1_000

      assert payload.intent_id == row.id
      assert payload.meeting_id == meeting_id
      assert payload.room_id == row.room_id
      assert payload.classified_intent == "action_items"
      assert payload.confidence == 0.91
      assert payload.chunk_excerpt == "Priya will revert the onboarding flow by Friday"

      # No runtime attention. `seed_target!/1` subscribed this process
      # to `runtime:<runtime_id>`, so a dispatcher that fell through to
      # the role arms would deliver here.
      refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 300

      # The row is committed and the cursor is HELD — that is what stops
      # a second utterance reconciling the same canvas concurrently. It
      # is released by the handler's terminal transition, or by the
      # queue's 90s ack window if the model call overruns.
      dispatched = await_status(meeting_id, row.id, :dispatched)
      assert dispatched.dispatched_at
      assert IntentQueue.cursor(meeting_id) == row.id

      # Stamped from the responsibility's own assignee.
      assert dispatched.target_agent_id == agent.id
      assert dispatched.target_agent_slug == agent.slug
    end

    test "an intent with NO routing row takes the runtime path and fires no responsibility" do
      # The negative control. Without it the fork could match every row
      # and the case above would still be green.
      #
      # This used to enqueue `visual_adjust` and call it "any OTHER
      # intent". That premise died on 2026-07-31, when `visual_adjust`
      # got a routing row of its own — so the case was asserting the
      # opposite of the shipped behaviour and would have had to be
      # loosened to survive. The honest version pins what the fork
      # actually keys on: the PRESENCE of a row in `IntentRouting`, not
      # a hardcoded one-intent allowlist.
      #
      # This control needs an intent that is unrouted AND routable.
      # "Has no responsibility row" and "reaches nobody at all" are
      # different properties, and only the first is what this case is
      # about.
      #
      # `off_topic` stood here until task 01a06637 and no longer can:
      # `dispatch_row/3` now fails it ahead of BOTH forks, so it takes
      # neither path and cannot demonstrate the runtime one.
      # `book_followup` is this file's default intent, has no routing
      # row, and is routable. Both halves of the premise are asserted
      # rather than assumed — if someone routes it, or declares it
      # unroutable, this test would otherwise quietly start proving
      # nothing.
      assert IntentRouting.entry("book_followup") == nil,
             "book_followup gained a routing row; pick another unrouted intent for this control"

      refute IntentRouting.unroutable_intent?("book_followup"),
             "book_followup became unroutable; it can no longer stand for the runtime path"

      {agent, runtime} = seed_target!("designer")
      subscribe_all_intent_topics!()

      meeting_id = new_meeting!()
      start_dispatcher!()

      row =
        enqueue!(meeting_id, %{
          classified_intent: "book_followup",
          target_role: "designer"
        })

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: topic,
                       event: "attention",
                       payload: %{signal: %{intent_id: intent_id}}
                     },
                     1_000

      assert topic == "runtime:#{runtime.runtime_id}"
      assert intent_id == row.id

      # Silence on EVERY responsibility topic, not just the action-items
      # one the old version watched — a fork that fell through to some
      # other intent's broadcast would have passed a single-topic refute.
      assert intent_broadcasts_received() == []

      dispatched = await_status(meeting_id, row.id, :dispatched)
      assert dispatched.target_agent_id == agent.id
    end

    test "an unknown intent string the classifier could emit also takes the runtime path" do
      # `off_topic` above is a *known* intent the table deliberately
      # omits. This is the other half: `classified_intent` is free text
      # from a small local model, so the fork must also decline a string
      # nobody has ever declared — rather than, say, deriving a topic
      # from it and broadcasting into the void (which would hold the
      # meeting's serial cursor for the full 90s ack window).
      {_agent, runtime} = seed_target!("designer")
      subscribe_all_intent_topics!()

      meeting_id = new_meeting!()
      start_dispatcher!()

      row =
        enqueue!(meeting_id, %{
          classified_intent: "vsual_adjsut",
          target_role: "designer"
        })

      row_id = row.id
      expected_topic = "runtime:#{runtime.runtime_id}"

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: ^expected_topic,
                       event: "attention",
                       payload: %{signal: %{intent_id: ^row_id}}
                     },
                     1_000

      assert intent_broadcasts_received() == []
      assert await_status(meeting_id, row.id, :dispatched).target_agent_id
    end

    test "every intent WITH a routing row takes the fork, not the runtime path" do
      # The generalisation of the action-items case above, driven over
      # `IntentRouting.entries/0` rather than a second hand-kept list.
      #
      # This is NOT circular. The table supplies the inputs and the
      # expected topic/event; what is asserted is observable dispatcher
      # behaviour — a broadcast landed on that topic and no runtime
      # attention did. Stop consulting `IntentRouting` in
      # `dispatch_row/3` (or drop the fork entirely) and every iteration
      # goes red on an empty mailbox. What the table CANNOT protect
      # against is a row being deleted from it, which would silently
      # shrink this loop; `intent_routing_test.exs` owns that side with
      # its own non-empty and per-row pins, and the guard below keeps
      # the loop from passing over nothing.
      entries = IntentRouting.entries()

      assert length(entries) >= 6,
             "IntentRouting shrank to #{length(entries)} rows — this loop would prove less " <>
               "than it did; confirm the deletion was intended, then update this floor"

      # `target_role` is the SAME assigned-and-runtime-backed role for
      # every iteration, regardless of which role actually owns the
      # intent. That is deliberate: the fork is checked BEFORE role
      # resolution, so a fully-wired runtime target is precisely what
      # makes the silence below evidence rather than a missing fixture.
      {_agent, _runtime} = seed_target!("designer")
      subscribe_all_intent_topics!()

      start_dispatcher!()

      for %{intent: intent, event: event, key: key} <- entries do
        # A fresh meeting per intent: the fork HOLDS the serial cursor
        # until the handler closes the row, so a second enqueue on the
        # same meeting would never be claimed.
        meeting_id = new_meeting!()

        row =
          enqueue!(meeting_id, %{
            classified_intent: intent,
            target_role: "designer",
            chunk_excerpt: "utterance routing to #{key}"
          })

        assert_receive {^event, payload}, 1_000
        assert payload.intent_id == row.id
        assert payload.classified_intent == intent

        refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 200

        await_status(meeting_id, row.id, :dispatched)
      end
    end

    test "the stamped agent comes from the RESPONSIBILITY, not from the classifier's role" do
      # These two resolutions normally agree — `meetings.action_items`
      # lives in the `meeting_scribe` bundle — so agreement proves
      # nothing. A responsibility override forces them apart: the role
      # resolves to `role_agent`, the responsibility to `resp_agent`.
      # A fork that reused `Roles.agent_id_for_role/1` stamps the
      # former and goes red here.
      {role_agent, _runtime} = seed_target!("meeting_scribe")
      resp_agent = create_agent!()
      {:ok, _} = Roles.set_override("meetings.action_items", resp_agent.id)

      refute resp_agent.id == role_agent.id

      meeting_id = new_meeting!()
      start_dispatcher!()

      # `target_role` is set to the role the classifier really stamps
      # on these rows, and it IS assigned — so a role-based stamp would
      # produce `role_agent.id`, a plausible wrong answer, rather than
      # nil. A control that can only fail by producing nil is weaker:
      # nil is also what a lookup that simply errored would give.
      row =
        enqueue!(meeting_id, %{
          classified_intent: "action_items",
          target_role: "meeting_scribe"
        })

      dispatched = await_status(meeting_id, row.id, :dispatched)
      assert dispatched.target_agent_id == resp_agent.id
      assert dispatched.target_agent_slug == resp_agent.slug
      refute dispatched.target_agent_id == role_agent.id
    end

    test "an unassigned responsibility still dispatches — the Router owns that outcome" do
      # No role assignment and no override anywhere. The runtime path
      # would land `:dispatch_failed{:no_assignee}` here; the
      # responsibility path must NOT, because the broadcast is global
      # and the Router resolves the assignee itself. Failing the row for
      # a lookup this code path does not depend on would make the queue
      # lie about what happened.
      :ok = Roles.unassign_role("meeting_scribe")

      :ok = Phoenix.PubSub.subscribe(Platform.PubSub, "meeting:action_item_intent")

      meeting_id = new_meeting!()
      start_dispatcher!()

      row = enqueue!(meeting_id, %{classified_intent: "action_items"})

      assert_receive {:action_item_intent, _payload}, 1_000

      dispatched = await_status(meeting_id, row.id, :dispatched)
      assert is_nil(dispatched.target_agent_id)
      refute dispatched.status == :dispatch_failed
    end

    test "the payload carries the room's transcript, space and speaker" do
      seed_target!("meeting_scribe")
      :ok = Phoenix.PubSub.subscribe(Platform.PubSub, "meeting:action_item_intent")

      room_id = "room-#{System.unique_integer([:positive])}"
      space_id = Platform.Types.UUIDv7.generate()

      {:ok, transcript} =
        Platform.Meetings.create_transcript(%{
          room_id: room_id,
          space_id: space_id,
          segments: [
            %{"speaker_name" => "Alex", "text" => "morning everyone", "final" => true},
            %{
              "speaker_name" => "Priya",
              "text" => "I will revert the onboarding flow by Friday",
              "final" => true
            }
          ]
        })

      meeting_id = new_meeting!()
      start_dispatcher!()

      _row =
        enqueue!(meeting_id, %{
          classified_intent: "action_items",
          room_id: room_id,
          chunk_excerpt: "I will revert the onboarding flow by Friday"
        })

      assert_receive {:action_item_intent, payload}, 1_000

      assert payload.transcript_id == transcript.id
      assert payload.space_id == space_id
      # Attributed to the segment whose text the excerpt is a prefix of
      # — NOT to the newest segment, and NOT to the first. Alex spoke
      # first and Priya spoke the line; a "just take the last segment"
      # implementation would answer "Priya" here too, so the sibling
      # case below (where the excerpt matches Alex's earlier line)
      # is what actually pins the matching.
      assert payload.speaker == "Priya"
    end

    test "speaker attribution follows the excerpt, not recency" do
      seed_target!("meeting_scribe")
      :ok = Phoenix.PubSub.subscribe(Platform.PubSub, "meeting:action_item_intent")

      room_id = "room-#{System.unique_integer([:positive])}"

      {:ok, _transcript} =
        Platform.Meetings.create_transcript(%{
          room_id: room_id,
          space_id: Platform.Types.UUIDv7.generate(),
          segments: [
            %{
              "speaker_name" => "Alex",
              "text" => "I will email the deploy audit",
              "final" => true
            },
            %{"speaker_name" => "Priya", "text" => "sounds good", "final" => true}
          ]
        })

      meeting_id = new_meeting!()
      start_dispatcher!()

      _row =
        enqueue!(meeting_id, %{
          classified_intent: "action_items",
          room_id: room_id,
          chunk_excerpt: "I will email the deploy audit"
        })

      assert_receive {:action_item_intent, payload}, 1_000

      # Alex's line is NOT the newest segment. A recency heuristic
      # answers "Priya" and this goes red.
      assert payload.speaker == "Alex"
    end

    test "a room with no transcript row still fires, with the unknown fields nil" do
      # Mid-meeting the utterance is the ground truth; transcript
      # enrichment is optional. Each unknown stays nil rather than
      # collapsing into a default, so the handler can tell "no space
      # known" from "space X".
      seed_target!("meeting_scribe")
      :ok = Phoenix.PubSub.subscribe(Platform.PubSub, "meeting:action_item_intent")

      meeting_id = new_meeting!()
      start_dispatcher!()

      row =
        enqueue!(meeting_id, %{
          classified_intent: "action_items",
          chunk_excerpt: "we should ship the audit"
        })

      assert_receive {:action_item_intent, payload}, 1_000

      assert payload.intent_id == row.id
      assert payload.chunk_excerpt == "we should ship the audit"
      assert is_nil(payload.transcript_id)
      assert is_nil(payload.space_id)
      assert is_nil(payload.speaker)
    end
  end

  # ── Serial cursor ──────────────────────────────────────────────────────────

  describe "ack-gated serial cursor" do
    test "three intents for the same target go out one at a time (AC3)" do
      seed_target!()

      meeting_id = new_meeting!()
      start_dispatcher!()

      first = enqueue!(meeting_id, %{classified_intent: "one"})
      second = enqueue!(meeting_id, %{classified_intent: "two"})
      third = enqueue!(meeting_id, %{classified_intent: "three"})

      await_status(meeting_id, first.id, :dispatched)

      # The cursor did NOT fan out — this is the whole point of the
      # redesign, and it is what the old batch drain could not promise.
      assert status_of(meeting_id, second.id) == :queued
      assert status_of(meeting_id, third.id) == :queued
      assert IntentQueue.cursor(meeting_id) == first.id

      # A `:working` ack says "I spawned a subagent", not "I'm done".
      # It must NOT release the queue.
      assert {:ok, _} = IntentQueue.ack(meeting_id, first.id, "probe-1", :working)
      assert status_of(meeting_id, first.id) == :acked
      assert status_of(meeting_id, second.id) == :queued
      assert status_of(meeting_id, third.id) == :queued
      assert IntentQueue.cursor(meeting_id) == first.id

      # `:completed` advances.
      assert {:ok, _} = IntentQueue.ack(meeting_id, first.id, "probe-1", :completed)
      assert status_of(meeting_id, first.id) == :completed

      await_status(meeting_id, second.id, :dispatched)
      assert status_of(meeting_id, third.id) == :queued
      assert IntentQueue.cursor(meeting_id) == second.id
    end

    test "at no point are two intents in flight for the same meeting" do
      seed_target!()

      meeting_id = new_meeting!()
      start_dispatcher!()

      rows = for n <- 1..5, do: enqueue!(meeting_id, %{classified_intent: "intent-#{n}"})

      # Walk the whole queue, sampling the in-flight count at every
      # step. A single sample after each ack would miss a transient
      # double-dispatch; sampling on a tight loop while acking is what
      # actually exercises the invariant.
      Enum.each(rows, fn row ->
        await_status(meeting_id, row.id, :dispatched)
        assert in_flight_count(meeting_id) == 1

        {:ok, _} = IntentQueue.ack(meeting_id, row.id, "probe-#{row.id}", :working)
        assert in_flight_count(meeting_id) == 1

        {:ok, _} = IntentQueue.ack(meeting_id, row.id, "probe-#{row.id}", :completed)
      end)

      assert in_flight_count(meeting_id) == 0
      assert IntentQueue.cursor(meeting_id) == nil
      assert Enum.all?(IntentQueue.list(meeting_id), &(&1.status == :completed))
    end

    test "meetings do not block each other" do
      seed_target!()

      meeting_a = new_meeting!()
      meeting_b = new_meeting!()
      start_dispatcher!()

      a1 = enqueue!(meeting_a, %{classified_intent: "a1"})
      _a2 = enqueue!(meeting_a, %{classified_intent: "a2"})
      b1 = enqueue!(meeting_b, %{classified_intent: "b1"})

      # Head-of-line blocking is per-meeting and deliberate. Across
      # meetings it would be a bug.
      await_status(meeting_a, a1.id, :dispatched)
      await_status(meeting_b, b1.id, :dispatched)
    end

    test "a rejected ack advances the cursor and emits the stage-6 correction hook" do
      attach_telemetry!([[:platform, :meetings, :intent_rejected]])
      seed_target!()

      meeting_id = new_meeting!()
      start_dispatcher!()

      first = enqueue!(meeting_id, %{classified_intent: "not-mine"})
      second = enqueue!(meeting_id, %{classified_intent: "next"})

      await_status(meeting_id, first.id, :dispatched)

      assert {:ok, row} =
               IntentQueue.ack(meeting_id, first.id, "probe-r", :rejected, "wrong person")

      assert row.status == :completed

      assert_receive {:telemetry, [:platform, :meetings, :intent_rejected], %{count: 1}, meta},
                     1_000

      assert meta.intent_id == first.id
      assert meta.meeting_id == meeting_id
      assert meta.classified_intent == "not-mine"
      assert meta.note == "wrong person"
      # `dispatch_outcome` is the status the row held when the reject
      # landed — stage 6 writes it onto the correction row, so it has
      # to be the PRE-transition value, not `:completed`.
      assert meta.dispatch_outcome == :dispatched

      await_status(meeting_id, second.id, :dispatched)
    end
  end

  # ── Cancellation (AC7 / AC8) ───────────────────────────────────────────────

  describe "cancelling an in-flight intent" do
    test "the runtime is told, carrying the subagent_id it acked with (AC7)" do
      seed_target!()

      meeting_id = new_meeting!()
      start_dispatcher!()

      first = enqueue!(meeting_id, %{classified_intent: "cancel-me"})
      second = enqueue!(meeting_id, %{classified_intent: "behind-it"})

      await_status(meeting_id, first.id, :dispatched)
      assert {:ok, _} = ack!(first.id, "cancel-probe-9x", "working")

      assert {:ok, :cancel_requested, _row} =
               IntentQueue.cancel(meeting_id, first.id, reason: :wrong_target)

      # The subagent_id is the one the TARGET supplied, read back off
      # the row — not regenerated, not nil. Without it the runtime has
      # no idea which of its subagents to stop.
      assert_receive %Phoenix.Socket.Broadcast{
                       event: "intent_cancelled",
                       payload: %{
                         intent_id: cancelled_id,
                         subagent_id: "cancel-probe-9x",
                         reason: :wrong_target,
                         corrected_intent: nil,
                         corrected_target_agent_id: nil
                       }
                     },
                     500

      assert cancelled_id == first.id

      # Still in flight until the target answers. Marking it cancelled
      # here would claim a subagent stopped that may still be running.
      assert status_of(meeting_id, first.id) == :acked
      assert status_of(meeting_id, second.id) == :queued

      assert {:ok, honored} = ack!(first.id, "cancel-probe-9x", "cancel_honored")
      assert honored.status == :cancelled

      {:ok, cancelled_row} = IntentQueue.get(meeting_id, first.id)
      assert cancelled_row.cancelled_at

      # Cursor advanced.
      await_status(meeting_id, second.id, :dispatched)
    end

    test "a pencil edit forwards the corrected intent and target" do
      seed_target!()
      other = create_agent!()

      meeting_id = new_meeting!()
      start_dispatcher!()

      row = enqueue!(meeting_id, %{classified_intent: "misclassified"})
      await_status(meeting_id, row.id, :dispatched)
      assert {:ok, _} = ack!(row.id, "pencil-probe", "working")

      assert {:ok, :cancel_requested, _} =
               IntentQueue.cancel(meeting_id, row.id,
                 reason: :wrong_intent,
                 corrected_intent: "draft_brief",
                 corrected_target_agent_id: other.id
               )

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "intent_cancelled",
                       payload: %{
                         reason: :wrong_intent,
                         corrected_intent: "draft_brief",
                         corrected_target_agent_id: corrected_target
                       }
                     },
                     500

      assert corrected_target == other.id
    end

    test "cancelling a :dispatched intent that never acked carries a nil subagent_id" do
      seed_target!()

      meeting_id = new_meeting!()
      start_dispatcher!()

      row = enqueue!(meeting_id, %{classified_intent: "never-acked"})
      await_status(meeting_id, row.id, :dispatched)

      assert {:ok, :cancel_requested, _} =
               IntentQueue.cancel(meeting_id, row.id, reason: :not_actionable)

      # Honest nil: the runtime never told us a subagent existed, so we
      # cannot invent a handle for one.
      assert_receive %Phoenix.Socket.Broadcast{
                       event: "intent_cancelled",
                       payload: %{subagent_id: nil, status: :dispatched}
                     },
                     500
    end

    test "a queued intent is deleted outright and no runtime is bothered" do
      seed_target!()

      meeting_id = new_meeting!()
      # No dispatcher — the row stays `:queued`, which is the state the
      # producer X's before anything has gone out.
      first = enqueue!(meeting_id, %{classified_intent: "never-sent"})

      assert {:ok, :deleted, deleted} = IntentQueue.cancel(meeting_id, first.id)
      assert deleted.id == first.id
      assert IntentQueue.get(meeting_id, first.id) == {:error, :not_found}
      assert IntentQueue.list(meeting_id) == []

      refute_received %Phoenix.Socket.Broadcast{event: "intent_cancelled"}
    end

    test "a completion that beat the cancel lands :cancelled_late, not a failure (AC8)" do
      seed_target!()

      meeting_id = new_meeting!()
      start_dispatcher!()

      row = enqueue!(meeting_id, %{classified_intent: "already-done"})
      await_status(meeting_id, row.id, :dispatched)

      # The target finished before the producer's X reached the queue.
      assert {:ok, %{status: :completed}} = ack!(row.id, "fast-probe", "completed")

      assert {:ok, :cancelled_late, late} = IntentQueue.cancel(meeting_id, row.id)
      assert late.status == :cancelled_late
      assert late.cancelled_at
      # The completion is not erased — `completed_at` survives, which is
      # what keeps the tuning corpus honest about what actually ran.
      assert late.completed_at

      # Nothing to signal: the work is done.
      refute_received %Phoenix.Socket.Broadcast{event: "intent_cancelled"}
    end

    test "a cancel_honored arriving after the work completed also lands :cancelled_late" do
      seed_target!()

      meeting_id = new_meeting!()
      start_dispatcher!()

      row = enqueue!(meeting_id, %{classified_intent: "raced"})
      await_status(meeting_id, row.id, :dispatched)
      assert {:ok, _} = ack!(row.id, "race-probe", "working")

      assert {:ok, :cancel_requested, _} = IntentQueue.cancel(meeting_id, row.id)
      assert_receive %Phoenix.Socket.Broadcast{event: "intent_cancelled"}, 500

      # The completion was already in flight when the cancel went out.
      assert {:ok, %{status: :completed}} = ack!(row.id, "race-probe", "completed")

      # The target then honours the cancel it had already been sent.
      # No crash, no "cannot ack a completed intent" — a distinct
      # status the producer can be shown.
      assert {:ok, honored} = ack!(row.id, "race-probe", "cancel_honored")
      assert honored.status == :cancelled_late
    end

    test "an unreachable runtime lands the row :cancelled locally rather than leaving it in flight" do
      {agent, _runtime} = seed_target!()

      meeting_id = new_meeting!(ack_timeout_ms: 60_000)
      start_dispatcher!()

      row = enqueue!(meeting_id, %{classified_intent: "orphaned-runtime"})
      await_status(meeting_id, row.id, :dispatched)
      assert {:ok, _} = ack!(row.id, "orphan-probe", "working")

      # The runtime link disappears between dispatch and cancel — an
      # operator revoked it, or the agent was re-provisioned.
      Repo.update_all(from(a in Agent, where: a.id == ^agent.id),
        set: [runtime_id: nil, runtime_type: "built_in"]
      )

      assert {:ok, :cancelled, cancelled} = IntentQueue.cancel(meeting_id, row.id)
      assert cancelled.status == :cancelled
      assert cancelled.cancelled_at
      assert IntentQueue.cursor(meeting_id) == nil
    end

    test "an already-terminal row is not cancellable" do
      seed_target!()

      meeting_id = new_meeting!(ack_timeout_ms: 400)
      start_dispatcher!()

      row = enqueue!(meeting_id, %{classified_intent: "will-time-out"})
      await_status(meeting_id, row.id, :dispatched)
      await_status(meeting_id, row.id, :timed_out, 3_000)

      assert {:error, {:not_cancellable, :timed_out}} = IntentQueue.cancel(meeting_id, row.id)
    end

    test "cancelling an unknown intent answers :not_found" do
      meeting_id = new_meeting!()

      assert {:error, :not_found} =
               IntentQueue.cancel(meeting_id, Platform.Types.UUIDv7.generate())
    end
  end

  # ── Ack timeout ────────────────────────────────────────────────────────────

  describe "ack timeout" do
    test "an unanswered dispatch times out and the cursor advances (AC4)" do
      seed_target!()

      meeting_id = new_meeting!(ack_timeout_ms: 500)
      start_dispatcher!()

      first = enqueue!(meeting_id, %{classified_intent: "unanswered"})
      second = enqueue!(meeting_id, %{classified_intent: "behind-it"})

      await_status(meeting_id, first.id, :dispatched)

      timed_out = await_status(meeting_id, first.id, :timed_out, 3_000)
      assert timed_out.timed_out_at

      # Amber, not red: nothing is provably broken, we just heard
      # nothing back. That is a claim about the STATUS, and the status
      # is unchanged — `:timed_out`, not `:no_ack_spawn_failed`.
      assert timed_out.status == :timed_out

      # The reason was `nil` until task 019ff292 stage 2. Nothing here
      # went red; the row now says WHICH of the two bounds gave up on
      # it. `:never_delivered` means the outer, transmission-anchored
      # bound expired with no first contact of any kind — no
      # `"intent_delivered"` receipt and no ack — which is a different
      # thing for an operator to chase (is anything listening on that
      # runtime topic?) than a responder that made contact and then
      # went quiet, which still reports `nil`.
      assert timed_out.dispatch_failure_reason == :never_delivered

      await_status(meeting_id, second.id, :dispatched)
    end

    test "a :working ack re-arms the window rather than letting it expire" do
      seed_target!()

      meeting_id = new_meeting!(ack_timeout_ms: 400)
      start_dispatcher!()

      row = enqueue!(meeting_id, %{classified_intent: "long-running"})
      await_status(meeting_id, row.id, :dispatched)

      # Three heartbeats across 900ms — more than two full windows.
      # A target that keeps saying "still working" must not be timed
      # out underneath itself.
      Enum.each(1..3, fn _ ->
        Process.sleep(300)
        assert {:ok, _} = IntentQueue.ack(meeting_id, row.id, "probe-hb", :working)
      end)

      assert status_of(meeting_id, row.id) == :acked
    end

    test "the ack window is configurable through application env" do
      seed_target!()

      Application.put_env(:platform, Platform.Meetings.IntentQueue, queue_ack_timeout_ms: 400)

      # Started AFTER the put_env, since the server reads config once
      # at init and then holds it.
      meeting_id = new_meeting!()
      start_dispatcher!()

      row = enqueue!(meeting_id, %{classified_intent: "config-driven"})
      await_status(meeting_id, row.id, :dispatched)
      await_status(meeting_id, row.id, :timed_out, 3_000)
    end
  end

  # ── :no_ack_spawn_failed vs :timed_out ─────────────────────────────────────

  describe "no_ack_spawn_failed disambiguation (AC6)" do
    test "rejected ack attempts turn an eventual timeout red" do
      seed_target!()

      meeting_id = new_meeting!(ack_timeout_ms: 600)
      start_dispatcher!()

      row = enqueue!(meeting_id, %{classified_intent: "runtime-cant-spawn"})
      await_status(meeting_id, row.id, :dispatched)

      # The runtime TRIED — it called intent_ack and the schema
      # rejected its subagent_id, twice. That is evidence of a broken
      # target, not of silence.
      :ok = IntentQueue.record_rejected_ack(meeting_id, row.id)
      :ok = IntentQueue.record_rejected_ack(meeting_id, row.id)
      assert IntentQueue.rejected_ack_count(meeting_id, row.id) == 2

      failed = await_status(meeting_id, row.id, :no_ack_spawn_failed, 3_000)
      assert failed.dispatch_failure_reason == :subagent_spawn_rejected
      assert failed.timed_out_at
    end

    test "no rejected attempts leaves the same timeout amber" do
      seed_target!()

      meeting_id = new_meeting!(ack_timeout_ms: 600)
      start_dispatcher!()

      row = enqueue!(meeting_id, %{classified_intent: "runtime-silent"})
      await_status(meeting_id, row.id, :dispatched)

      assert IntentQueue.rejected_ack_count(meeting_id, row.id) == 0
      await_status(meeting_id, row.id, :timed_out, 3_000)
    end

    test "a rejected attempt against a successfully-acked row does not turn it red" do
      seed_target!()

      meeting_id = new_meeting!(ack_timeout_ms: 600)
      start_dispatcher!()

      row = enqueue!(meeting_id, %{classified_intent: "acked-then-silent"})
      await_status(meeting_id, row.id, :dispatched)

      :ok = IntentQueue.record_rejected_ack(meeting_id, row.id)
      assert {:ok, _} = IntentQueue.ack(meeting_id, row.id, "probe-late", :working)

      # It got there in the end. `:no_ack_spawn_failed` means "never
      # produced a subagent id"; this runtime did.
      await_status(meeting_id, row.id, :timed_out, 3_000)
    end
  end

  # ── Durable corrections (AC14 / AC17) ──────────────────────────────────────

  describe "system-originated correction rows (AC14)" do
    # Task 019f70b8 stage 6. These are the only two paths that write a
    # `meeting_intent_corrections` row without a human clicking
    # anything. Both go queue transition site → telemetry →
    # `IntentCorrections.TelemetryHandler` → Postgres, so a test that
    # inserted a row directly would prove nothing about the wiring.
    #
    # `new_real_meeting!/0` builds an actual org → project → meeting
    # chain rather than the bare UUID the rest of this file uses,
    # because the correction row's `org_id` is DERIVED from that chain
    # at write time. A harness that passed the org in would go green
    # against a handler that never resolved one, and the whole
    # org-scoped exemplar query (AC16) reads that column.

    test "a rejected ack writes a removed_no_action / wrong_target correction" do
      {agent, _runtime} = seed_target!()

      meeting_id = new_meeting!()
      start_dispatcher!()

      row =
        enqueue!(meeting_id, %{
          classified_intent: "not-mine",
          chunk_excerpt: "someone should redo the onboarding illustrations"
        })

      await_status(meeting_id, row.id, :dispatched)

      assert {:ok, _} = IntentQueue.ack(meeting_id, row.id, "probe-reject", :rejected)

      assert [correction] = IntentCorrections.list_for_meeting(meeting_id)

      # Asserted explicitly rather than inferred from `list_for_meeting/2`
      # returning it: inside a test transaction this is the only row in
      # the table, so an unscoped query would hand it back regardless of
      # what meeting it was attributed to.
      assert correction.meeting_id == meeting_id
      assert correction.correction == :removed_no_action
      assert correction.reason == :wrong_target
      assert correction.classified_intent == "not-mine"
      assert correction.transcript_chunk_excerpt =~ "onboarding illustrations"
      # Derived by the dispatcher from the role — never seeded by the test.
      assert correction.classified_target_agent_id == agent.id
      # No human clicked anything.
      assert is_nil(correction.actor_participant_id)
    end

    test "the rejected correction records where the intent HAD GOT TO, not where it landed" do
      seed_target!()

      meeting_id = new_meeting!()
      start_dispatcher!()

      row = enqueue!(meeting_id, %{classified_intent: "acked-then-rejected"})
      await_status(meeting_id, row.id, :dispatched)

      # Ack `:working` first so the row is `:acked`, not `:dispatched`,
      # when the reject lands. "The target acked, looked, and pushed it
      # back" is a different tuning signal from "the target rejected it
      # before acking" — and both land the ROW on `:completed`, so a
      # handler reading the post-transition status would collapse them.
      assert {:ok, %{status: :acked}} =
               IntentQueue.ack(meeting_id, row.id, "probe-working", :working)

      assert {:ok, %{status: :completed}} =
               IntentQueue.ack(meeting_id, row.id, "probe-working", :rejected)

      assert [correction] = IntentCorrections.list_for_meeting(meeting_id)
      assert correction.dispatch_outcome == :acked
    end

    test "a rejected ack straight from :dispatched records :dispatched" do
      seed_target!()

      meeting_id = new_meeting!()
      start_dispatcher!()

      row = enqueue!(meeting_id, %{classified_intent: "rejected-cold"})
      await_status(meeting_id, row.id, :dispatched)

      assert {:ok, _} = IntentQueue.ack(meeting_id, row.id, "probe-cold", :rejected)

      assert [correction] = IntentCorrections.list_for_meeting(meeting_id)
      assert correction.dispatch_outcome == :dispatched
    end

    test "the correction's org_id is derived from the meeting's project, not passed in" do
      seed_target!()

      {meeting, org_id} = new_real_meeting!()
      start_dispatcher!()

      row = enqueue!(meeting.id, %{classified_intent: "org-derivation-probe"})
      await_status(meeting.id, row.id, :dispatched)

      assert {:ok, _} = IntentQueue.ack(meeting.id, row.id, "probe-org", :rejected)

      assert [correction] = IntentCorrections.list_for_meeting(meeting.id)
      assert correction.org_id == org_id

      # And it is therefore visible to the classifier's org-scoped
      # exemplar read, which is the entire point of writing the column.
      exemplar_intents =
        meeting.id
        |> IntentCorrections.exemplars_for_meeting(10)
        |> Enum.map(& &1.classified_intent)

      assert "org-derivation-probe" in exemplar_intents
    end

    test "a :no_ack_spawn_failed timeout writes a reason: :other correction" do
      seed_target!()

      meeting_id = new_meeting!(ack_timeout_ms: 600)
      start_dispatcher!()

      row = enqueue!(meeting_id, %{classified_intent: "runtime-cant-spawn"})
      await_status(meeting_id, row.id, :dispatched)

      :ok = IntentQueue.record_rejected_ack(meeting_id, row.id)

      await_status(meeting_id, row.id, :no_ack_spawn_failed, 3_000)

      assert [correction] = IntentCorrections.list_for_meeting(meeting_id)

      assert correction.dispatch_outcome == :no_ack_spawn_failed
      assert correction.correction == :removed_no_action
      # NOT `:wrong_target` — a runtime that cannot spawn a subagent is
      # an unreliable target, which is a different thing from the wrong
      # one, and the corpus has to keep them apart.
      assert correction.reason == :other
    end

    test "an amber :timed_out writes NO correction row" do
      seed_target!()

      meeting_id = new_meeting!(ack_timeout_ms: 600)
      start_dispatcher!()

      row = enqueue!(meeting_id, %{classified_intent: "runtime-silent"})
      await_status(meeting_id, row.id, :dispatched)

      await_status(meeting_id, row.id, :timed_out, 3_000)

      # Saru's status semantics: `:timed_out` is amber — we waited and
      # heard nothing, which is not evidence the classification was
      # wrong. Recording it as a correction would train the model to
      # stop producing intents for slow targets.
      assert IntentCorrections.list_for_meeting(meeting_id) == []
    end

    test "a visible :dispatch_failed writes NO correction row" do
      meeting_id = new_meeting!()
      start_dispatcher!()

      row = enqueue!(meeting_id, %{target_role: nil})
      await_status(meeting_id, row.id, :dispatch_failed)

      # The producer can see this row and correct it by hand. Until they
      # do, "we could not route it" is a routing gap, not a statement
      # that the classifier was wrong.
      assert IntentCorrections.list_for_meeting(meeting_id) == []
    end
  end

  describe "AC17 — a meeting with nothing corrected leaves zero durable rows" do
    test "20 intents dispatched, acked and completed cleanly write nothing" do
      seed_target!()

      before_count = Repo.aggregate(IntentCorrection, :count)

      meeting_id = new_meeting!()
      start_dispatcher!()

      rows =
        for n <- 1..20 do
          enqueue!(meeting_id, %{classified_intent: "clean-#{n}"})
        end

      for row <- rows do
        await_status(meeting_id, row.id, :dispatched, 5_000)
        assert {:ok, _} = IntentQueue.ack(meeting_id, row.id, "probe-#{row.id}", :working)
        assert {:ok, _} = IntentQueue.ack(meeting_id, row.id, "probe-#{row.id}", :completed)
      end

      assert Enum.all?(IntentQueue.list(meeting_id), &(&1.status == :completed))

      # Scoped by meeting AND checked corpus-wide: the meeting scope
      # catches a row attributed here, the global count catches one
      # written with a mangled meeting_id.
      assert IntentCorrections.list_for_meeting(meeting_id) == []
      assert Repo.aggregate(IntentCorrection, :count) == before_count
    end

    test "a cancel_honored cancellation writes nothing on its own" do
      seed_target!()

      before_count = Repo.aggregate(IntentCorrection, :count)

      meeting_id = new_meeting!()
      start_dispatcher!()

      row = enqueue!(meeting_id, %{classified_intent: "cancel-me"})
      await_status(meeting_id, row.id, :dispatched)

      assert {:ok, _} = IntentQueue.ack(meeting_id, row.id, "probe-cancel", :working)
      assert {:ok, :cancel_requested, _} = IntentQueue.cancel(meeting_id, row.id)
      assert {:ok, _} = IntentQueue.ack(meeting_id, row.id, "probe-cancel", :cancel_honored)

      await_status(meeting_id, row.id, :cancelled)

      # `IntentQueue.cancel/3` deliberately does not write a correction:
      # the durable record of a producer's X is written by the surface
      # that knows WHY (stage 7's reason/pencil), and a cancel with no
      # stated reason is not an exemplar.
      assert IntentCorrections.list_for_meeting(meeting_id) == []
      assert Repo.aggregate(IntentCorrection, :count) == before_count
    end
  end

  # ── Resolution failures are retained ───────────────────────────────────────

  describe "dispatch failures" do
    test "nil target_role fails visibly and retains the row" do
      meeting_id = new_meeting!()
      start_dispatcher!()

      row = enqueue!(meeting_id, %{target_role: nil})

      failed = await_status(meeting_id, row.id, :dispatch_failed)
      assert failed.dispatch_failure_reason == :no_target_role

      # Retained, not deleted — the producer has to be able to see it,
      # X it, and correct it. The pre-019f70b8 queue deleted this row.
      assert [^failed] = IntentQueue.list(meeting_id)
      assert IntentQueue.cursor(meeting_id) == nil
    end

    # The classifier's "nobody" is the STRING "null", never Elixir's
    # `nil` — `normalise_target_role/1` maps the prompt's JSON null onto
    # it because `target_role` is hashed into the dedupe key and has to
    # be a binary. So the `is_nil/1` guard above could never match a row
    # this pipeline actually produces, and EVERY off_topic row was
    # recorded `:unknown_role`: "the model emitted a role outside the
    # enum", a model defect that is not occurring, on the single most
    # common value in the queue.
    #
    # The row shape below is the one the classifier writes for small
    # talk, not an invented one: `classified_intent: "off_topic"` (absent
    # from `IntentRouting`, so the responsibility fork above does not
    # claim it) plus `IntentClassifier.no_target_role/0`.
    test "the classifier's \"null\" target_role fails as :no_target_role, not :unknown_role" do
      meeting_id = new_meeting!()
      {_pid, _name} = start_dispatcher!()

      log =
        capture_log(fn ->
          row =
            enqueue!(meeting_id, %{
              classified_intent: "off_topic",
              target_role: IntentClassifier.no_target_role()
            })

          failed = await_status(meeting_id, row.id, :dispatch_failed)

          assert failed.dispatch_failure_reason == :no_target_role,
                 "an off_topic row carries the classifier's no-role sentinel; " <>
                   "recording it as :unknown_role blames the model for a defect it did not commit"
        end)

      # And it does not burn the once-per-key unknown-role log line on
      # the most common value in the queue.
      refute log =~ "unknown target_role"

      # POSITIVE CONTROL, same run: the sentinel is not simply being
      # treated as valid. A genuinely bogus role still fails, and still
      # fails DIFFERENTLY.
      bogus_log =
        capture_log(fn ->
          bogus = enqueue!(meeting_id, %{target_role: "not-a-real-role-either"})
          bogus_failed = await_status(meeting_id, bogus.id, :dispatch_failed)
          assert bogus_failed.dispatch_failure_reason == :unknown_role
        end)

      assert bogus_log =~ "unknown target_role"
    end

    # ── An intent that reaches nobody, whatever role it named ──────────────
    #
    # Task 01a06637. `IntentRouting` has known since `b768c2ef` that
    # `off_topic` reaches nobody — `@unroutable_intents`, asked first in
    # `routable?/2` — but `dispatch_row/3` never asked it. The response
    # schema demands a `target_role` STRING on every answer while the
    # prompt makes `off_topic` the stated default, so a small model
    # filling in `meeting_scribe` while declining is an ordinary output,
    # not a contrived shape.
    #
    # THE SEEDING IS THE TEST. The original production repro only
    # stopped because the probe's scribe had no runtime, so the row
    # failed fast on `:no_runtime` and released the cursor anyway. A
    # version of these cases without a runtime-backed `meeting_scribe`
    # goes green against the UNFIXED dispatcher and proves nothing.
    test "off_topic naming a REAL role does not hold the cursor from the ask behind it" do
      # Runtime-backed on purpose: without the fix this row genuinely
      # resolves an agent, genuinely reaches `:dispatched`, and
      # genuinely holds the cursor.
      {_scribe, _scribe_runtime} = seed_target!("meeting_scribe")
      {designer, _designer_runtime} = seed_target!("designer")

      # 60s, deliberately far longer than `await_status/4`'s 2s budget.
      # A held cursor must not be rescued by the ack window expiring
      # inside the test — with a short timeout here the buggy code
      # passes.
      meeting_id = new_meeting!(ack_timeout_ms: 60_000)
      start_dispatcher!()

      first =
        enqueue!(meeting_id, %{
          classified_intent: "off_topic",
          target_role: "meeting_scribe",
          chunk_excerpt: "ha, did you catch the game last night?"
        })

      second =
        enqueue!(meeting_id, %{
          classified_intent: "book_followup",
          target_role: "designer",
          chunk_excerpt: "designer, book us a follow-up on the onboarding funnel"
        })

      # THE CLAIM. Not "the small talk did not dispatch" — that is the
      # easy half and nearly worthless. The user-visible bug is that the
      # meeting FEELS STUCK, so what has to be proved is that the real
      # ask spoken behind the small talk went out WITHOUT WAITING.
      dispatched = await_status(meeting_id, second.id, :dispatched)
      assert dispatched.target_agent_id == designer.id
      assert IntentQueue.cursor(meeting_id) == second.id

      # A direct read, not a wait: `second` could only be claimed after
      # `first` released the cursor, so `first` is already terminal here
      # by the queue's own ordering.
      assert status_of(meeting_id, first.id) == :dispatch_failed

      {:ok, failed} = IntentQueue.get(meeting_id, first.id)
      assert failed.dispatch_failure_reason == :no_target_role
    end

    test "nothing reaches the named scribe, and the row is retained and visible" do
      # `seed_target!/1` subscribes this process to `runtime:<id>` for
      # the role it seeds, so the refute below is evidence rather than a
      # missing fixture: the role path is fully wired and WOULD have
      # delivered.
      {_scribe, _runtime} = seed_target!("meeting_scribe")

      meeting_id = new_meeting!()
      start_dispatcher!()

      row =
        enqueue!(meeting_id, %{
          classified_intent: "off_topic",
          target_role: "meeting_scribe",
          chunk_excerpt: "anyway, my flight got delayed three hours"
        })

      failed = await_status(meeting_id, row.id, :dispatch_failed)

      refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 300

      assert failed.dispatch_failure_reason == :no_target_role

      # Never resolved an agent — the branch fires ahead of resolution.
      assert failed.target_agent_id == nil

      # Retained, X-able and visible: the contract every other failure
      # branch in this module keeps. And the cursor is free.
      assert [^failed] = IntentQueue.list(meeting_id)
      assert IntentQueue.cursor(meeting_id) == nil
    end

    # `:no_target_role` and `:unknown_role` are load-bearing for triage
    # and were separated deliberately in `88291626`. Widening
    # `:no_target_role` to cover unroutable intents is an easy way to
    # collapse them back together, so all three rows live in ONE test —
    # a collapse cannot hide in a case that is skipped or read alone.
    test "the two dispatch-failure reasons still mean different things" do
      # Runtime-backed again: with the unroutable branch removed, row
      # (b) below would DISPATCH rather than fail for some unrelated
      # reason, so this test fails loudly instead of drifting green.
      {_scribe, _runtime} = seed_target!("meeting_scribe")

      meeting_id = new_meeting!()
      start_dispatcher!()

      quiet_log =
        capture_log(fn ->
          # (a) the shape the classifier writes when it declines
          # cleanly. This is the pre-existing case; it must not break.
          sentinel =
            enqueue!(meeting_id, %{
              classified_intent: "off_topic",
              target_role: IntentClassifier.no_target_role()
            })

          assert await_status(meeting_id, sentinel.id, :dispatch_failed).dispatch_failure_reason ==
                   :no_target_role

          # (b) the shape task 01a06637 fixed: the same decline, still
          # naming a real role, because the schema demands one.
          named =
            enqueue!(meeting_id, %{
              classified_intent: "off_topic",
              target_role: "meeting_scribe"
            })

          assert await_status(meeting_id, named.id, :dispatch_failed).dispatch_failure_reason ==
                   :no_target_role
        end)

      # Neither off_topic row spends the once-per-key unknown-role line
      # on the single most common value in the queue.
      refute quiet_log =~ "unknown target_role"

      # (c) The distinction that must SURVIVE: a routable intent naming
      # a role outside `Role.valid_keys/0` is a different event, keeps
      # its own reason, and still logs.
      noisy_log =
        capture_log(fn ->
          bogus =
            enqueue!(meeting_id, %{
              classified_intent: "book_followup",
              target_role: "not-a-real-role"
            })

          assert await_status(meeting_id, bogus.id, :dispatch_failed).dispatch_failure_reason ==
                   :unknown_role
        end)

      assert noisy_log =~ "unknown target_role"
    end

    test "unknown role fails as :unknown_role and logs once per key" do
      meeting_id = new_meeting!()
      {_pid, _name} = start_dispatcher!()

      log =
        capture_log(fn ->
          row = enqueue!(meeting_id, %{target_role: "not-a-real-role"})
          failed = await_status(meeting_id, row.id, :dispatch_failed)
          assert failed.dispatch_failure_reason == :unknown_role

          second = enqueue!(meeting_id, %{target_role: "not-a-real-role"})
          await_status(meeting_id, second.id, :dispatch_failed)
        end)

      # Spam suppression: one line per unknown key for the dispatcher's
      # lifetime, however many intents carry it.
      occurrences = log |> String.split("unknown target_role") |> length() |> Kernel.-(1)
      assert occurrences == 1
    end

    test "valid but unassigned role fails as :no_assignee" do
      :ok = Roles.unassign_role("designer")

      meeting_id = new_meeting!()
      start_dispatcher!()

      row = enqueue!(meeting_id, %{target_role: "designer"})

      failed = await_status(meeting_id, row.id, :dispatch_failed)
      assert failed.dispatch_failure_reason == :no_assignee
    end

    test "a role whose agent was deleted fails visibly rather than dispatching" do
      agent = create_agent!()
      :ok = assign_role!("designer", agent)
      Repo.delete_all(from(a in Agent, where: a.id == ^agent.id))

      meeting_id = new_meeting!()
      start_dispatcher!()

      row = enqueue!(meeting_id, %{target_role: "designer"})

      failed = await_status(meeting_id, row.id, :dispatch_failed)

      # `:no_assignee`, not `:agent_not_found`: `role_assignments` has a
      # cascading FK, so deleting the agent takes the assignment with
      # it and `agent_id_for_role/1` returns nil. The dispatcher's
      # `:agent_not_found` branch covers the narrower inter-query race
      # (id resolved, agent gone before `Repo.get/2`), which cannot be
      # provoked through the public path — asserting it here would mean
      # asserting a lie about which branch ran.
      assert failed.dispatch_failure_reason == :no_assignee
    end

    test "a target agent with no linked runtime fails as :no_runtime and retains the row" do
      # The flagged stage-4 behaviour change. This agent used to get an
      # AgentResponder chat signal; under the ack contract there is no
      # runtime to spawn a subagent, so the producer sees a red row
      # instead of silence.
      agent = create_agent!()
      :ok = assign_role!("designer", agent)

      meeting_id = new_meeting!()
      start_dispatcher!()

      first = enqueue!(meeting_id, %{classified_intent: "nowhere-to-go"})
      second = enqueue!(meeting_id, %{classified_intent: "should-still-be-tried"})

      failed = await_status(meeting_id, first.id, :dispatch_failed)
      assert failed.dispatch_failure_reason == :no_runtime
      # Never stamped — the row never got as far as a target.
      assert failed.target_agent_id == nil

      # Retained AND the cursor advanced. A wedged cursor would leave
      # everything behind it queued forever, which is the invisibility
      # this whole task exists to remove.
      second_failed = await_status(meeting_id, second.id, :dispatch_failed)
      assert second_failed.dispatch_failure_reason == :no_runtime

      assert length(IntentQueue.list(meeting_id)) == 2
      assert IntentQueue.cursor(meeting_id) == nil
    end
  end

  # ── A target that provably cannot ack (task 01a08875 stage 2) ──────────────
  #
  # The defect: `resolve_target/1`'s only test is `agent.runtime_id != nil`,
  # so a runtime that is not authorized to call `intent_ack` was dispatched to
  # anyway. Its ack was then refused by `ToolAuthorization.authorize/2` ABOVE
  # `ToolSurface.execute/3`, where the MCP transport emits no log, no
  # telemetry and no audit row — so the queue heard nothing, held the
  # meeting's serial cursor for the whole `:awaiting_delivery` window
  # (`ack_timeout_ms` x 2) and then recorded a plain `:timed_out` that is
  # indistinguishable from an offline runtime.
  #
  # WHY THE EXISTING SUITE PROVES NOTHING HERE. Every other case in this file
  # goes through `create_runtime_agent!/1`, which calls `register_runtime/2`
  # with only a `runtime_id` — so every one of them dispatches to a
  # DEFAULT-bundle runtime, and since stage 1 put `intent_ack` in `meetings`
  # (which the defaults carry) they are all green against this defect. A
  # fixture that genuinely lacks the capability has to be built on purpose,
  # which is what `seed_ack_target!/2` below is for.
  describe "the target must be able to ack" do
    # THE CLAIM, and it is about the QUEUE, not about `ToolAuthorization`.
    # Asserting that `authorize/2` returns `{:error, :forbidden}` would be a
    # fact about a different module. The harm this exists to remove is the
    # SECOND ask — a real request, to a different and perfectly capable agent
    # — sitting `:queued` behind a dispatch that can never be answered.
    test "a runtime that cannot ack fails fast and does not hold the cursor" do
      {_designer, _designer_runtime} = seed_ack_target!("designer", false)
      {scribe, _scribe_runtime} = seed_ack_target!("meeting_scribe", true)

      # 60s, deliberately far beyond `await_status/4`'s 2s budget. With a
      # short ack window the UNFIXED dispatcher passes this test for the
      # wrong reason: the cursor is released by the window expiring rather
      # than by the row being refused.
      meeting_id = new_meeting!(ack_timeout_ms: 60_000)
      start_dispatcher!()

      # THE ENQUEUES ARE INSIDE THE CAPTURE WINDOW, and they have to be.
      # `enqueue/2` broadcasts `:intent_enqueued` synchronously, so the
      # dispatcher can claim, refuse and LOG before a `capture_log/1` opened
      # afterwards has installed its handler — the log line is then simply
      # gone and the assertion below fails with `left: ""`. Measured: 1 in ~3
      # runs of this file with the enqueues outside. `with_log/1` rather than
      # `capture_log/1` so the rows can still be named out here.
      {{failed, dispatched, second_id}, log} =
        with_log(fn ->
          first =
            enqueue!(meeting_id, %{
              target_role: "designer",
              classified_intent: "book_followup",
              chunk_excerpt: "designer, book us a follow-up on the onboarding funnel"
            })

          second =
            enqueue!(meeting_id, %{
              target_role: "meeting_scribe",
              classified_intent: "summarise_decision",
              chunk_excerpt: "scribe, write that decision down"
            })

          # THE CLAIM, waited on FIRST and deliberately so. "The first one
          # failed" is the easy half and nearly worthless alone; the
          # user-visible harm this stage exists for is a real request to a
          # perfectly capable agent sitting `:queued` behind a dispatch that
          # could never have been answered. Asking this question before
          # looking at the refused row is also what makes the mutations
          # legible: a gate that always authorizes, and a gate that records a
          # NON-advancing status, both fail HERE with "expected intent ... to
          # reach :dispatched, got :queued" rather than on a status string.
          dispatched = await_status(meeting_id, second.id, :dispatched)

          # A direct read, not a wait: `second` could only be claimed once
          # `first` had released the cursor, so `first` is already terminal by
          # the queue's own ordering. Precedent: the 01a06637 case above.
          {:ok, failed} = IntentQueue.get(meeting_id, first.id)

          {failed, dispatched, second.id}
        end)

      assert failed.status == :dispatch_failed
      assert failed.dispatch_failure_reason == :cannot_ack

      # `target_agent_id` is stamped by `send_dispatch/7`, which never ran, so
      # it is nil here exactly as it is for every other pre-dispatch failure.
      # What distinguishes this row from a `:no_runtime` one is the REASON,
      # and that is the whole point of keeping the two separate: resolution
      # SUCCEEDED here, authorization did not.
      assert failed.target_agent_id == nil
      assert failed.target_role == "designer"

      assert dispatched.target_agent_id == scribe.id
      assert IntentQueue.cursor(meeting_id) == second_id

      # Unlike the MCP transport's denial, which emits no log, no telemetry
      # and no audit row, this refusal is on the record — and on the record
      # BEFORE any time has been spent waiting on it.
      assert log =~ "target cannot ack"

      # Retained and visible, the contract every other failure branch keeps.
      assert length(IntentQueue.list(meeting_id)) == 2
    end

    # Nothing was ever sent, so the capable agent behind it is not merely
    # first in the queue — it is the only thing that got a signal at all.
    test "nothing reaches a runtime that cannot ack, and the row is retained" do
      {_designer, _runtime} = seed_ack_target!("designer", false)

      meeting_id = new_meeting!(ack_timeout_ms: 60_000)
      start_dispatcher!()

      row = enqueue!(meeting_id, %{target_role: "designer"})

      # No `capture_log` here, matching the `:no_runtime` case above: the
      # refusal's log line is asserted in the case before this one, and
      # `capture_log` around a body that also uses `refute_receive` makes the
      # mailbox harder to reason about than the noise is worth.
      failed = await_status(meeting_id, row.id, :dispatch_failed)
      assert failed.dispatch_failure_reason == :cannot_ack

      # `seed_ack_target!/2` subscribed this process to `runtime:<id>`, so the
      # refute is evidence rather than a missing fixture: the role path is
      # fully wired and WOULD have delivered.
      refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 300

      assert [^failed] = IntentQueue.list(meeting_id)
      assert IntentQueue.cursor(meeting_id) == nil
    end

    # MANDATORY POSITIVE CONTROL. Without this, the case above passes for a
    # dispatcher that refuses EVERYTHING — including one where the gate is
    # asking about a misspelled tool name, since an unknown name is in no
    # bundle and `authorize/2` denies it. Same fixture, same role chain, same
    # helper: the only difference is the bundle grant.
    test "the same fixture with the bundle granted still dispatches, acks and completes" do
      {designer, _runtime} = seed_ack_target!("designer", true)

      meeting_id = new_meeting!(ack_timeout_ms: 60_000)
      start_dispatcher!()

      first = enqueue!(meeting_id, %{target_role: "designer", classified_intent: "book_followup"})
      second = enqueue!(meeting_id, %{target_role: "designer", classified_intent: "next_ask"})

      dispatched = await_status(meeting_id, first.id, :dispatched)
      assert dispatched.target_agent_id == designer.id

      # It really reached the runtime, over the surface the adapter builds.
      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{intent_id: signal_intent_id}}
                     },
                     1_000

      assert signal_intent_id == first.id

      # And the ack it is now allowed to make is accepted, through the real
      # tool rather than `IntentQueue.ack/5` directly — the whole point of the
      # gate is that this call would have been refused.
      assert {:ok, _} = ack!(first.id, "probe-can-ack", "working")
      assert status_of(meeting_id, first.id) == :acked

      assert {:ok, _} = ack!(first.id, "probe-can-ack", "completed")
      assert status_of(meeting_id, first.id) == :completed

      # The cursor advanced for the ordinary reason too.
      await_status(meeting_id, second.id, :dispatched)

      # Nothing anywhere in this run was refused.
      refute Enum.any?(IntentQueue.list(meeting_id), &(&1.status == :dispatch_failed))
      refute Enum.any?(IntentQueue.list(meeting_id), &(&1.dispatch_failure_reason == :cannot_ack))
    end
  end

  # ── Re-drive paths ─────────────────────────────────────────────────────────

  describe "belt-and-braces re-drive" do
    test "the periodic tick drains a meeting whose notify was missed" do
      seed_target!()

      # Enqueue BEFORE any dispatcher exists, so the notify broadcast
      # lands in nobody's mailbox — exactly the case the tick recovers.
      meeting_id = new_meeting!()
      row = enqueue!(meeting_id, %{classified_intent: "missed-notify"})
      assert status_of(meeting_id, row.id) == :queued

      start_dispatcher!(tick_interval_ms: 50)

      await_status(meeting_id, row.id, :dispatched)
    end

    test "sweep_stalled/0 re-broadcasts and needs no running dispatcher" do
      seed_target!()

      meeting_id = new_meeting!()
      row = enqueue!(meeting_id, %{classified_intent: "swept"})

      # Safe with nothing listening — the StallRegistry fires this from
      # its own process and must not care whether a dispatcher is up.
      assert :ok = IntentDispatcher.sweep_stalled()
      assert status_of(meeting_id, row.id) == :queued

      start_dispatcher!()
      assert :ok = IntentDispatcher.sweep_stalled()

      await_status(meeting_id, row.id, :dispatched)
    end

    test "drain/2 is a no-op when the cursor is held" do
      seed_target!()

      meeting_id = new_meeting!()
      {_pid, name} = start_dispatcher!()

      first = enqueue!(meeting_id, %{classified_intent: "holding"})
      _second = enqueue!(meeting_id, %{classified_intent: "waiting"})

      await_status(meeting_id, first.id, :dispatched)

      assert IntentDispatcher.drain(meeting_id, name) == :busy
      assert in_flight_count(meeting_id) == 1
    end

    test "drain/2 on a meeting with no queue answers :empty" do
      {_pid, name} = start_dispatcher!()
      assert IntentDispatcher.drain(Platform.Types.UUIDv7.generate(), name) == :empty
    end
  end

  # ── Telemetry ──────────────────────────────────────────────────────────────

  describe "telemetry" do
    test "a successful dispatch emits :intent_dispatched with the intent id and runtime" do
      attach_telemetry!([[:platform, :meetings, :intent_dispatched]])
      {agent, runtime} = seed_target!()

      meeting_id = new_meeting!()
      start_dispatcher!()

      row = enqueue!(meeting_id, %{classified_intent: "measured"})

      assert_receive {:telemetry, [:platform, :meetings, :intent_dispatched], measurements, meta},
                     2_000

      assert measurements.count == 1
      assert is_integer(measurements.dispatch_ms)
      assert meta.meeting_id == meeting_id
      assert meta.intent_id == row.id
      assert meta.target_role == "designer"
      assert meta.agent_id == agent.id
      # Agent kind no longer selects a surface — there is one surface.
      assert meta.dispatch_kind == :runtime_attention
      assert meta.runtime_id == runtime.runtime_id
    end

    test "a resolution failure emits :intent_dropped carrying the reason" do
      attach_telemetry!([[:platform, :meetings, :intent_dropped]])

      meeting_id = new_meeting!()
      start_dispatcher!()

      row = enqueue!(meeting_id, %{target_role: nil})

      assert_receive {:telemetry, [:platform, :meetings, :intent_dropped], %{count: 1}, meta},
                     2_000

      assert meta.meeting_id == meeting_id
      assert meta.intent_id == row.id
      assert meta.reason == :no_target_role
    end

    test "the tick emits :tick and :queue_depth counting queued and in-flight separately" do
      attach_telemetry!([
        [:platform, :meetings, :intent_dispatcher, :tick],
        [:platform, :meetings, :intent_dispatcher, :queue_depth]
      ])

      seed_target!()

      meeting_id = new_meeting!()
      first = enqueue!(meeting_id, %{classified_intent: "d1"})
      _second = enqueue!(meeting_id, %{classified_intent: "d2"})
      _third = enqueue!(meeting_id, %{classified_intent: "d3"})

      start_dispatcher!(tick_interval_ms: 50)
      await_status(meeting_id, first.id, :dispatched)

      # Depth is rows still WAITING. The in-flight row is not waiting,
      # and counting it would make the number mean two things at once —
      # which is what the old global-table `:ets.info/2` size did.
      assert_receive {:telemetry, [:platform, :meetings, :intent_dispatcher, :queue_depth],
                      %{count: depth}, _},
                     2_000

      assert depth >= 2

      assert_receive {:telemetry, [:platform, :meetings, :intent_dispatcher, :tick], measurements,
                      meta},
                     2_000

      assert is_integer(measurements.claimed)
      assert is_integer(meta.queue_depth_after)
      # Since stage 4 this counts rows a meeting cursor is holding, not
      # this process's outstanding dispatch tasks (there are none).
      assert is_integer(meta.in_flight)
    end
  end

  # ── Per-meeting mute hold (task 019fbaac stage 2) ──────────────────────────
  describe "per-meeting mute" do
    test "a muted meeting claims nothing and drains after unmute" do
      # Both halves in one body, deliberately. The "still :queued"
      # assertions are satisfiable by a dispatcher that is simply
      # broken, so the SAME fixture has to go on and dispatch once the
      # mute lifts before the held half means anything.
      {meeting, _org_id} = new_real_meeting!()
      {_agent, _runtime} = seed_target!("designer")
      {_pid, name} = start_dispatcher!()

      {:ok, _} = Meetings.set_intent_muted(meeting, true)

      # Enqueued AFTER the mute is on, so the queue's own
      # `:intent_enqueued` notify drains into the hold too — not just
      # the explicit call below.
      first = enqueue!(meeting.id, %{})
      second = enqueue!(meeting.id, %{})

      assert IntentDispatcher.drain(meeting.id, name) == :muted

      assert status_of(meeting.id, first.id) == :queued
      assert status_of(meeting.id, second.id) == :queued
      assert IntentQueue.cursor(meeting.id) == nil

      {:ok, _} = Meetings.set_intent_muted(meeting, false)

      assert IntentDispatcher.drain(meeting.id, name) == :dispatched
      await_status(meeting.id, first.id, :dispatched)

      # Serial cursor semantics are unchanged by the mute: exactly one
      # row goes out, the other waits its turn.
      assert status_of(meeting.id, second.id) == :queued
      assert IntentQueue.cursor(meeting.id) == first.id
    end

    test "the tick sweep does not count a muted meeting as dispatched" do
      {meeting, _org_id} = new_real_meeting!()
      {_agent, _runtime} = seed_target!("designer")
      attach_telemetry!([[:platform, :meetings, :intent_dispatcher, :tick]])

      # `:tick` reduces over EVERY live queue on the node, and queue
      # owners are application-global — a sibling test's leftover queue
      # would contribute its own `:dispatched` to `claimed` and make a
      # `== 0` assertion mean nothing about mute. Narrow the tick's
      # universe to this meeting, then assert that is what it is.
      Enum.each(IntentQueue.live_meeting_ids(), fn id ->
        if id != meeting.id, do: IntentQueue.stop(id)
      end)

      # Membership, not equality. Queue owners are application-global and
      # sibling ASYNC cases start their own queues at arbitrary moments,
      # including between the sweep above and this line — so `== [id]` is
      # a race that fails whenever the suite's scheduling happens to
      # interleave. It is safe to relax: a foreign queue can only ADD to
      # `claimed` below, so it can produce a loud failure but never a
      # false pass. The message on that assertion says so.
      assert meeting.id in IntentQueue.live_meeting_ids()

      {:ok, _} = Meetings.set_intent_muted(meeting, true)
      _row = enqueue!(meeting.id, %{})

      start_dispatcher!(tick_interval_ms: 50)

      assert_receive {:telemetry, [:platform, :meetings, :intent_dispatcher, :tick],
                      %{claimed: claimed}, _meta},
                     2_000

      assert claimed == 0,
             "expected the muted meeting to contribute nothing to the tick, got claimed=#{claimed}. " <>
               "If this is non-zero, check whether a sibling async case's queue was live during " <>
               "the tick before concluding that mute is broken."
    end
  end
end
