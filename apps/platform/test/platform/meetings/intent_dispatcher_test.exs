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

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Federation
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
    org_id = Platform.TenancyFixtures.fabrikam_org_id()

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

  defp create_user! do
    Repo.insert!(%User{
      email: "intentdisp_#{System.unique_integer([:positive])}@example.com",
      name: "Intent Dispatcher Test User",
      oidc_sub: "oidc-intentdisp-#{System.unique_integer([:positive])}"
    })
  end

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
      # `off_topic` is the canonical unrouted intent — deliberately
      # absent from the table (see `IntentRouting`'s moduledoc: a
      # routing row for it would wake an agent for every joke). The
      # premise is asserted rather than assumed, because if someone ever
      # DOES route it, this test would otherwise quietly start proving
      # nothing.
      assert IntentRouting.entry("off_topic") == nil,
             "off_topic gained a routing row; pick another unrouted intent for this control"

      {agent, runtime} = seed_target!("designer")
      subscribe_all_intent_topics!()

      meeting_id = new_meeting!()
      start_dispatcher!()

      row =
        enqueue!(meeting_id, %{
          classified_intent: "off_topic",
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
      # nothing back.
      assert timed_out.dispatch_failure_reason == nil

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
end
