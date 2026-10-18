defmodule Platform.Integration.MeetingIntentDispatcherE2ETest do
  @moduledoc """
  End-to-end integration test for the FULL Meeting Producer runtime
  pipeline (task 019f2452 stage 5). Extends the classifier's e2e
  coverage (`Platform.Integration.MeetingIntentRuntimeTest`, stage 5's
  sibling for stage 1) past the queue-insert assertion — this one
  walks the last hops end-to-end:

      Meetings.append_segment/2
        → PubSub.broadcast_transcript_chunk/2  (meeting_id resolved)
        → IntentClassifier.handle_info/2       (stubbed provider)
        → IntentQueue.enqueue/2                (per MEETING)
        → PubSub.broadcast_intent_enqueued/1
        → IntentDispatcher.handle_info/2       (per-case instance)
        → IntentQueue.claim_next/1             (serial cursor)
        → IntentRuntimeAdapter.resolve_target/1 (role → agent → runtime)
        → "attention" on runtime:<runtime_id>  (REAL broadcast)
        → row transitions to :dispatched and STAYS there, awaiting ack
        → :telemetry.execute([:platform, :meetings, :intent_dispatched], …)
        → intent_ack(:completed) → row :completed, cursor advances

  Everything runs on a real BEAM node under a shared-mode DataCase
  sandbox. Exactly ONE boundary is stubbed — the classifier's LLM call —
  via the `provider_module:` seam the unit tests already use. The
  dispatch hop is NOT stubbed any more: since task 019f70b8 stage 4 the
  hand-off is a Phoenix broadcast on the target runtime's own topic, so
  the test subscribes to that topic and asserts the real thing. The
  `:meetings_intent_dispatcher_native_dispatcher` /
  `_external_dispatcher` MFA seams are gone with the surfaces they
  stood in for.

  ## Nothing here supplies a target

  Each case seeds a role assignment and a runtime link, then lets the
  chain derive the topic: `target_role` (from the stubbed LLM) →
  `Roles.agent_id_for_role/1` → `%Agent{}` →
  `Federation.get_runtime_for_agent/1` → `runtime:<runtime_id>`. The
  meeting id is likewise derived from the transcript's space, not
  passed in — the hole stage 3 found in `append_segment/2` was exactly
  a harness feeding a value production had to compute.

  ## Cases

    1. **Agent kind no longer selects a surface** — an `external`-kind
       agent and a `native`-kind agent both receive the identical
       runtime-attention signal. Before stage 4 these took two
       different code paths (`ExternalAgents.Dispatcher.dispatch/3` vs
       `Chat.AgentResponder.maybe_dispatch/1`); now `kind` is not
       consulted at all and only the runtime link matters.

    2. **Ack round-trip** — the signal carries an addressable
       `intent_id`, and `intent_ack` walks the row
       `:dispatched → :acked → :completed`, releasing the cursor.

    3. **Cross-meeting isolation** — two parallel classifier→dispatcher
       flows on distinct meetings both dispatch cleanly. Head-of-line
       blocking is per-meeting by design; one meeting's in-flight
       intent must never gate another's.

  ## Sandbox note

  DataCase runs `Sandbox.mode(Repo, {:shared, self()})` for `async: false`
  tests, so per-case `start_supervised!` children see the test's Repo
  connection transparently.
  """

  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Federation
  alias Platform.Meetings
  alias Platform.Meetings.IntentClassifier
  alias Platform.Meetings.IntentDispatcher
  alias Platform.Meetings.IntentQueue
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo
  alias Platform.Roles

  # The classifier walks `Roles.assignee_for/1` on this responsibility
  # key to find its LLM-owning agent. Independent of the `target_role`
  # the LLM later emits (which resolves via `Roles.agent_id_for_role/1`
  # inside the dispatcher).
  @responsibility_key "meetings.intent_classify"
  @prompt_slug "meetings.intent_classify.v1"

  # ── Provider stub — same shape as the classifier's e2e ─────────────────────

  defmodule StubProvider do
    @moduledoc """
    Runs inside the classifier's own process. Reads a fun off the
    process dictionary key `:intent_classifier_stub_fun` and calls it
    with `(credentials, messages, opts)`. Mirrors
    `Platform.Integration.MeetingIntentRuntimeTest.StubProvider` — kept
    private to this suite so a change here can't accidentally shift
    behaviour of the sibling test.
    """

    def chat(credentials, messages, opts) do
      case Process.get(:intent_classifier_stub_fun) do
        nil -> {:error, :no_stub_configured}
        fun when is_function(fun, 3) -> fun.(credentials, messages, opts)
      end
    end
  end

  # ── Setup ──────────────────────────────────────────────────────────────────

  setup do
    Logger.put_module_level(Platform.Meetings.IntentDispatcher, :info)

    # Boot a per-case classifier + dispatcher. Unique names keep them
    # from clashing with any app-tree singletons (both are gated OFF
    # in `config/test.exs`).
    classifier_name = :"intent_classifier_e2e_#{System.unique_integer([:positive])}"
    dispatcher_name = :"intent_dispatcher_e2e_#{System.unique_integer([:positive])}"

    {:ok, classifier_pid} =
      start_supervised({IntentClassifier, name: classifier_name, provider_module: StubProvider})

    # Long tick — the hot PubSub path is what these cases exercise;
    # we don't want a periodic tick claiming rows out from under the
    # notify handler and muddying the assertions.
    {:ok, dispatcher_pid} =
      start_supervised({IntentDispatcher, name: dispatcher_name, tick_interval_ms: 60_000})

    # Seed the classifier's responsibility assignee. The closed roster
    # has no `meetings.intent_classify` role, so we use the override
    # escape hatch — same pattern the classifier e2e uses.
    classifier_agent =
      create_agent!(%{
        slug: "e2e-dispatch-classifier-#{System.unique_integer([:positive])}",
        kind: "native"
      })

    {:ok, _} = Roles.set_override(@responsibility_key, classifier_agent.id)

    # No prompt template row for the classifier — force the inline
    # fallback path, matches the sibling e2e.
    case PromptTemplates.get_template_by_slug(@prompt_slug) do
      nil -> :ok
      template -> PromptTemplates.delete_template(template)
    end

    on_exit(fn -> Logger.delete_module_level(Platform.Meetings.IntentDispatcher) end)

    {:ok,
     classifier_pid: classifier_pid,
     classifier_name: classifier_name,
     dispatcher_pid: dispatcher_pid,
     dispatcher_name: dispatcher_name}
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp create_agent!(overrides) do
    attrs =
      Map.merge(
        %{
          slug: "e2e-dispatch-agent-#{System.unique_integer([:positive])}",
          name: "E2E Dispatch Test Agent",
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
    user =
      Repo.insert!(%User{
        email: "e2e_dispatch_#{System.unique_integer([:positive])}@example.com",
        name: "E2E Dispatch User",
        oidc_sub: "oidc-e2e-dispatch-#{System.unique_integer([:positive])}"
      })

    Platform.ExternalUserFixtures.plain_member!(
      user,
      Platform.Tenancy.get_org!(Platform.TenancyFixtures.acme_org_id()),
      "admin"
    )

    user
  end

  # Role assignment + runtime link + topic subscription, in the order a
  # real deployment does them. Returns the agent and the topic the
  # dispatcher's own resolution should independently arrive at.
  defp seed_target!(role_key, agent_overrides) do
    agent = create_agent!(agent_overrides)

    {:ok, runtime} =
      Federation.register_runtime(create_user!().id, %{
        runtime_id: "e2e-dispatch-rt-#{System.unique_integer([:positive])}"
      })

    {:ok, linked} = Federation.link_agent(runtime, agent)

    :ok = Roles.unassign_role(role_key)
    {:ok, _} = Roles.assign_role(role_key, linked.id)

    :ok = PlatformWeb.Endpoint.subscribe("runtime:#{runtime.runtime_id}")

    {linked, runtime}
  end

  # Plant the provider stub fun in the classifier's process dictionary
  # via its test-only handshake message.
  defp plant_stub_fun(classifier_pid, fun) do
    ref = make_ref()
    send(classifier_pid, {:__test_plant_stub, self(), ref, fun})

    receive do
      {^ref, :ok} -> :ok
    after
      500 -> flunk("classifier did not ack stub fun plant")
    end
  end

  defp attach_telemetry!(events) when is_list(events) do
    handler_id = "intent-dispatcher-e2e-#{System.unique_integer([:positive])}"
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

  # Build the classifier's happy-path response — the raw string content
  # the provider returns is parsed by the classifier as JSON.
  defp classifier_response(intent, target_role, confidence, messages) do
    {:ok,
     %{
       content:
         Jason.encode!(%{
           "intent" => intent,
           "target_role" => target_role,
           "confidence" => confidence,
           "evidence_quote" => echo_quote(messages)
         })
     }}
  end

  # A real project → meeting → chat space chain. The chunk's meeting_id
  # is resolved from the transcript's space, so a stubbed id would
  # bypass the link this pipeline depends on.
  defp create_meeting!(name) do
    {:ok, project} =
      Platform.Tasks.create_project(%{
        name: "#{name} project #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/meeting-intent-dispatch-e2e"
      })

    {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: name})

    # Generous ack window: these cases assert on dispatch, not on the
    # timeout path, and a short window would race them.
    {:ok, _} = IntentQueue.ensure_started(meeting.id, ack_timeout_ms: 60_000)
    on_exit(fn -> IntentQueue.stop(meeting.id) end)

    meeting
  end

  defp append_transcript_segment!(meeting, room_id, participant, text) do
    {:ok, transcript} =
      Meetings.ensure_transcript(%{room_id: room_id, space_id: meeting.chat_space_id})

    {:ok, updated} =
      Meetings.append_segment(transcript.id, %{
        participant_identity: participant,
        text: text,
        start_time: 0,
        end_time: 1000
      })

    updated
  end

  # Poll until the meeting's queue holds exactly one row in `status`.
  defp await_single_row(meeting_id, status, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_single_row(meeting_id, status, deadline)
  end

  defp do_await_single_row(meeting_id, status, deadline) do
    case IntentQueue.list(meeting_id) do
      [%{status: ^status} = row] ->
        row

      other ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("expected one #{inspect(status)} row for #{meeting_id}, got #{inspect(other)}")
        else
          Process.sleep(10)
          do_await_single_row(meeting_id, status, deadline)
        end
    end
  end

  # ── Test 1: agent kind no longer selects a dispatch surface ───────────────

  describe "runtime attention is the only dispatch surface" do
    test "an external-kind agent with a runtime gets the same signal a native one does",
         %{classifier_pid: classifier_pid} do
      attach_telemetry!([[:platform, :meetings, :intent_dispatched]])

      plant_stub_fun(classifier_pid, fn _c, messages, _o ->
        classifier_response("design_task", "designer", 0.92, messages)
      end)

      {target_agent, runtime} =
        seed_target!("designer", %{
          slug: "e2e-dispatch-designer-external-#{System.unique_integer([:positive])}",
          kind: "external",
          endpoint_kind: "openai_compat",
          base_url: "https://example.test/v1",
          model: "gpt-fake"
        })

      meeting = create_meeting!("E2E Dispatch External")

      # A single transcript segment triggers the whole chain.
      _ =
        append_transcript_segment!(
          meeting,
          "e2e-dispatch-external",
          "user-1",
          "we should redesign the onboarding funnel"
        )

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: topic,
                       event: "attention",
                       payload: %{
                         signal: %{
                           reason: "meeting_intent_dispatch",
                           classified_intent: "design_task",
                           target_role: "designer",
                           confidence: 0.92,
                           room_id: "e2e-dispatch-external",
                           intent_id: intent_id,
                           meeting_id: signal_meeting_id,
                           target_agent_id: signal_agent_id
                         }
                       }
                     },
                     3_000

      # The whole chain derived this, not the test.
      assert topic == "runtime:#{runtime.runtime_id}"
      assert signal_meeting_id == meeting.id
      assert signal_agent_id == target_agent.id

      assert_receive {:telemetry, [:platform, :meetings, :intent_dispatched], measurements,
                      metadata},
                     3_000

      assert %{count: 1, dispatch_ms: dispatch_ms} = measurements
      assert is_integer(dispatch_ms) and dispatch_ms >= 0

      assert %{
               room_id: "e2e-dispatch-external",
               target_role: "designer",
               intent: "design_task",
               dispatch_kind: :runtime_attention,
               agent_slug: agent_slug,
               runtime_id: telemetry_runtime_id
             } = metadata

      assert agent_slug == target_agent.slug
      assert telemetry_runtime_id == runtime.runtime_id

      # The row is RETAINED as `:dispatched`, waiting on an ack. Before
      # task 019f70b8 `mark_dispatched/2` deleted it, which left the
      # live-tuning UI nothing to render and the queue no way to know
      # whether the target ever picked the work up.
      row = await_single_row(meeting.id, :dispatched)
      assert row.id == intent_id
      assert row.dispatched_at
      assert row.subagent_id == nil
      assert IntentQueue.cursor(meeting.id) == row.id
    end
  end

  # ── Test 2: ack round-trip off the signal's own intent_id ─────────────────

  describe "ack round-trip" do
    test "the dispatched signal is addressable and walks :dispatched → :acked → :completed",
         %{classifier_pid: classifier_pid} do
      attach_telemetry!([[:platform, :meetings, :intent_dispatched]])

      plant_stub_fun(classifier_pid, fn _c, messages, _o ->
        classifier_response("record_decision", "historian", 0.85, messages)
      end)

      {target_agent, _runtime} =
        seed_target!("historian", %{
          slug: "e2e-dispatch-historian-native-#{System.unique_integer([:positive])}",
          kind: "native"
        })

      meeting = create_meeting!("E2E Dispatch Native")

      _ =
        append_transcript_segment!(
          meeting,
          "e2e-dispatch-native",
          "user-2",
          "let's record that we're going to ship weekly"
        )

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{
                         signal: %{
                           reason: "meeting_intent_dispatch",
                           intent_id: intent_id,
                           target_agent_id: signal_agent_id,
                           transcript_chunk_excerpt: excerpt
                         }
                       }
                     },
                     3_000

      assert signal_agent_id == target_agent.id
      # The excerpt is what makes the signal self-describing — the
      # target shouldn't have to read the transcript back to know what
      # it was asked about.
      assert excerpt =~ "ship weekly"

      assert_receive {:telemetry, [:platform, :meetings, :intent_dispatched], %{count: 1},
                      %{
                        room_id: "e2e-dispatch-native",
                        target_role: "historian",
                        intent: "record_decision",
                        dispatch_kind: :runtime_attention
                      }},
                     3_000

      row = await_single_row(meeting.id, :dispatched)
      assert row.id == intent_id

      # The whole ack contract is reachable from what the target
      # actually received — the point of keying rows by a generated id
      # rather than a room/dedupe pair.
      {:ok, acked} =
        Platform.Federation.ToolSurface.execute(
          "intent_ack",
          %{
            "intent_id" => intent_id,
            "subagent_id" => "historian.test-host",
            "status" => "working"
          },
          %{}
        )

      assert acked.status == :acked
      assert acked.meeting_id == meeting.id

      {:ok, completed} =
        Platform.Federation.ToolSurface.execute(
          "intent_ack",
          %{
            "intent_id" => intent_id,
            "subagent_id" => "historian.test-host",
            "status" => "completed"
          },
          %{}
        )

      assert completed.status == :completed
      assert IntentQueue.cursor(meeting.id) == nil
    end
  end

  # ── Test 3: cross-meeting isolation ───────────────────────────────────────

  describe "cross-meeting isolation" do
    test "two meetings dispatch in parallel — one's cursor never gates the other",
         %{classifier_pid: classifier_pid} do
      # Both meetings drive the same target_role, so we only need one
      # role assignment — and that is precisely the case where a
      # GLOBAL serial cursor would have wedged. Head-of-line blocking
      # is per-meeting by design; across meetings it would be a bug.
      plant_stub_fun(classifier_pid, fn _c, messages, _o ->
        classifier_response("schedule_followup", "meeting_scribe", 0.8, messages)
      end)

      {_target_agent, _runtime} =
        seed_target!("meeting_scribe", %{
          slug: "e2e-dispatch-scribe-shared-#{System.unique_integer([:positive])}",
          kind: "native"
        })

      meeting_a = create_meeting!("E2E Dispatch Meeting A")
      meeting_b = create_meeting!("E2E Dispatch Meeting B")

      room_a = "e2e-dispatch-room-a"
      room_b = "e2e-dispatch-room-b"

      _ =
        append_transcript_segment!(
          meeting_a,
          room_a,
          "user-a",
          "let's follow up on the roadmap next Friday"
        )

      # Meeting B kicked off before meeting A's intent is acked, so
      # both are in flight simultaneously.
      _ =
        append_transcript_segment!(
          meeting_b,
          room_b,
          "user-b",
          "we should schedule a follow-up on that item"
        )

      # Both dispatches land on the SAME runtime topic (one agent holds
      # the role), so the two meetings are told apart by the signal's
      # meeting_id. Order isn't guaranteed — assert set-equality.
      meetings_seen =
        for _ <- 1..2 do
          assert_receive %Phoenix.Socket.Broadcast{
                           event: "attention",
                           payload: %{signal: %{meeting_id: m}}
                         },
                         5_000

          m
        end

      assert Enum.sort(meetings_seen) == Enum.sort([meeting_a.id, meeting_b.id])

      # Both meetings hold their own cursor, simultaneously. Neither
      # waited on the other.
      row_a = await_single_row(meeting_a.id, :dispatched)
      row_b = await_single_row(meeting_b.id, :dispatched)

      assert IntentQueue.cursor(meeting_a.id) == row_a.id
      assert IntentQueue.cursor(meeting_b.id) == row_b.id
      refute row_a.id == row_b.id
    end
  end

  # ── Test 4: the dispatched target can actually write the named space ──────

  describe "the dispatch names a space the target can write" do
    test "the target cannot create a canvas in the meeting space before dispatch and can after",
         %{classifier_pid: classifier_pid} do
      plant_stub_fun(classifier_pid, fn _c, messages, _o ->
        classifier_response("draft_brief", "designer", 0.9, messages)
      end)

      {target_agent, runtime} =
        seed_target!("designer", %{
          slug: "e2e-dispatch-writable-#{System.unique_integer([:positive])}",
          kind: "native"
        })

      meeting = create_meeting!("E2E Dispatch Writable")

      # ── Negative control, captured rather than assumed ────────────────────
      #
      # "It can write after the dispatch" is equally consistent with "it could
      # always write" unless the before-state is measured with the SAME call.
      # The two probes below are byte-identical apart from when they run.
      refute Chat.get_agent_participant(meeting.chat_space_id, target_agent.id)

      assert {:error, before_error} = canvas_probe(meeting.chat_space_id, target_agent.id)

      # `:error`, not `:message` — the refusal payload is built by
      # `Canvas.ToolHandlers.create/2` and passed through `ToolSurface` unchanged.
      assert before_error.recoverable == false
      assert before_error.error =~ "is not a participant"

      _ =
        append_transcript_segment!(
          meeting,
          "e2e-dispatch-writable",
          "user-4",
          "can somebody draft a brief for the new landing page"
        )

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: topic,
                       event: "attention",
                       payload: %{signal: signal}
                     },
                     3_000

      assert topic == "runtime:#{runtime.runtime_id}"

      # The envelope names the space, and does NOT claim the top-level
      # `space_id` slot a live client uses to pin permission prompts.
      assert signal.target_space_id == meeting.chat_space_id
      refute Map.has_key?(signal, :space_id)

      participant = Chat.get_agent_participant(meeting.chat_space_id, target_agent.id)
      assert participant.attention_mode == "mention"
      assert participant.role == "member"

      # The same probe, now succeeding. Success is keyed `:canvas_id`: since
      # task 01a14a7f stage 3 `canvas_create` is the declared name of
      # `canvas.create`, whose handler result it returns, and the legacy
      # execute-only clause that answered with `:id` is gone.
      assert {:ok, created} = canvas_probe(meeting.chat_space_id, target_agent.id)
      assert is_binary(created.canvas_id)
      refute Map.has_key?(created, :id)

      row = await_single_row(meeting.id, :dispatched)
      assert row.dispatch_failure_reason == nil
    end
  end

  # Build the tool context the way `PlatformWeb.MCPController.build_context/2`
  # does: resolve `agent_participant_id` from the space AT CALL TIME.
  # `Canvas.ToolHandlers.create/2` reads that key and never derives it from
  # `:agent_id`, so a bare `%{agent_id: id}` context refuses identically before
  # AND after the invite — a negative control that looks like it passes while
  # proving nothing.
  defp canvas_probe(space_id, agent_id) do
    participant_id =
      case Chat.get_agent_participant(space_id, agent_id) do
        %Platform.Chat.Participant{id: id} -> id
        _ -> nil
      end

    args = %{
      "space_id" => space_id,
      "title" => "writability probe",
      "document" => %{
        "version" => 1,
        "revision" => 1,
        "root" => %{
          "id" => "root",
          "type" => "text",
          "props" => %{"value" => "probe"},
          "children" => []
        }
      }
    }

    Federation.ToolSurface.execute("canvas_create", args, %{
      space_id: space_id,
      agent_id: agent_id,
      agent_participant_id: participant_id
    })
  end

  # Task 01a03f57 stage 2: the classifier demotes a non-off_topic
  # classification to off_topic unless `evidence_quote` is a verbatim
  # span of the chunk. Stubs echo the chunk back as their citation —
  # the user message the classifier sends IS the chunk text.
  defp echo_quote(messages) do
    Enum.find_value(messages, "", fn message ->
      role = Map.get(message, :role) || Map.get(message, "role")
      if role == "user", do: Map.get(message, :content) || Map.get(message, "content")
    end)
  end
end
