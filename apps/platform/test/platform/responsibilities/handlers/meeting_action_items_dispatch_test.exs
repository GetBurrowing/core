defmodule Platform.Responsibilities.Handlers.MeetingActionItemsDispatchTest do
  @moduledoc """
  Seam-crossing tests for `meetings.action_items` (task 019fa56b-c81f
  e2e fix).

  ## Why this file exists separately from `meeting_action_items_test.exs`

  The 19 tests in `meeting_action_items_test.exs` all call
  `handle_output/3` DIRECTLY with an already-decoded map
  (`%{"action_items" => [...]}`). They were green while the production
  key was completely unfireable, because none of them crosses the
  string/map seam that production actually walks:

      Router.fire
        → Providers.Meetings.gather_context/2
        → Providers.Meetings.build_prompt/1     <-- defect 2 lived here
        → Dispatcher.dispatch/4  (HTTP)
        → ContractValidator.validate/2          <-- returns a BINARY,
        →   invoke_handle_output/3                  never a map
        → MeetingActionItems.handle_output/3    <-- defect 1 lived here

  `ContractValidator.classify/1` has no clause for the field-map
  contract shape `%{"action_items" => "list[string]"}`, so it falls
  through to `:unknown` → freeform → `validate/2` hands the handler the
  RAW STRING. Every responsibility in the tree declares its contract in
  that shape, so this is the universal production shape, not an edge
  case. See `MeetingActionItems`'s moduledoc for why the fix is at the
  handler and not in the shared classifier.

  Both tests here drive `Router.fire/2` for real, with HTTP stubbed via
  `Req.Test`, and assert on the two things the live e2e run
  (case 019fa57b-4544) proved were broken:

    * the POST body carries transcript content, not the literal
      un-seeded template name `"meetings.action_items.v1"`
    * a freeform string response lands as a message in the meeting space
      with every item in it

  Structure mirrors `Platform.Review.MeetingSummarizeE2EReviewTest`,
  which is the existing template for router-fired dispatch coverage.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.ExternalAgents.EphemeralCredentials
  alias Platform.Meetings
  alias Platform.Meetings.IntentQueue
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.BuiltIns
  alias Platform.Responsibilities.Handlers.MeetingActionItems
  alias Platform.Responsibilities.Registry
  alias Platform.Responsibilities.Router, as: ResponsibilityRouter
  alias Platform.Roles

  @stub :meeting_action_items_dispatch_stub

  setup do
    Logger.put_module_level(ResponsibilityRouter, :info)

    {:ok, _} = Application.ensure_all_started(:req)

    Application.put_env(
      :platform,
      :external_agents_dispatcher_req_client,
      Req.new(plug: {Req.Test, @stub})
    )

    on_exit(fn ->
      Application.delete_env(:platform, :external_agents_dispatcher_req_client)
      Logger.delete_module_level(ResponsibilityRouter)
    end)

    :ok
  end

  # ── fixtures ──────────────────────────────────────────────────────────────

  defp seed_action_items_row! do
    [attrs] = MeetingActionItems.register()
    {:ok, row} = Responsibilities.upsert_by_key(attrs)
    row
  end

  defp seed_action_items_agent! do
    role_key = "meeting_scribe"

    Repo.insert!(
      %Platform.Roles.Role{
        key: role_key,
        name: "Meeting Scribe",
        description: "dispatch seam seed",
        icon: "hero-star"
      },
      on_conflict: :nothing,
      conflict_target: :key
    )

    Repo.insert!(
      %Platform.Roles.RoleResponsibility{
        role_key: role_key,
        responsibility_key: "meetings.action_items"
      },
      on_conflict: :nothing,
      conflict_target: [:role_key, :responsibility_key]
    )

    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "seam-scribe-#{System.unique_integer([:positive])}",
        name: "Seam Scribe",
        status: "active",
        kind: "external",
        endpoint_kind: "openai_compat",
        base_url: "https://api.example.test",
        model: "test-model",
        workspace_id: nil
      })
      |> Repo.insert!()

    :ok = EphemeralCredentials.put(agent.id, "sk-seam-test")
    on_exit(fn -> EphemeralCredentials.delete(agent.id) end)

    {:ok, _} = Roles.assign_role(role_key, agent.id)
    agent
  end

  defp create_space! do
    {:ok, space} = Chat.create_space(%{kind: "execution"})
    space
  end

  defp create_transcript!(overrides) do
    attrs =
      Map.merge(
        %{
          room_id: "seam-room-#{System.unique_integer([:positive])}",
          space_id: nil,
          segments: []
        },
        overrides
      )

    {:ok, transcript} = Meetings.create_transcript(attrs)
    transcript
  end

  defp dialogue_segments do
    [
      %{
        "speaker_name" => "Priya",
        "text" =>
          "The onboarding revert has to happen before the mobile launch. I'll own that and " <>
            "have it out by Friday — day-two retention dropped thirty percent on the pilot.",
        "start_time" => 0,
        "end_time" => 14_000,
        "final" => true
      },
      %{
        "speaker_name" => "Alex",
        "text" =>
          "I'll email Rowan the deploy audit once the adapter fix lands. That unblocks the " <>
            "compliance sign-off we owe the design partners.",
        "start_time" => 14_500,
        "end_time" => 28_000,
        "final" => true
      }
    ]
  end

  defp start_registry! do
    name = Module.concat([Registry, "Seam#{System.unique_integer([:positive])}"])
    _pid = start_supervised!({Registry, name: name, providers: BuiltIns.providers()})
    name
  end

  # Capture the outbound POST body, reply with a canned completion.
  defp stub_ok(canned_content) do
    test_pid = self()

    Req.Test.stub(@stub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:dispatch_body, body})

      Req.Test.json(conn, %{
        "choices" => [
          %{"message" => %{"role" => "assistant", "content" => canned_content}}
        ]
      })
    end)
  end

  # The live shape: `IntentDispatcher.action_item_payload/2` on the
  # global `meeting:action_item_intent` topic (task 019fb90f-36e3 stage
  # 1), carrying the classified utterance the prompt is built around
  # (stage 3). `payload_overrides` lets a case blank the excerpt or the
  # transcript independently — the two now have different consequences.
  defp fire!(transcript_id, space_id, payload_overrides \\ %{}) do
    payload =
      Map.merge(
        %{
          transcript_id: transcript_id,
          space_id: space_id,
          # Every payload `IntentDispatcher.action_item_payload/2`
          # broadcasts carries a meeting id; `handle_output/3` refuses
          # without one because it has no canvas to reconcile. There is
          # deliberately no meeting ROW behind it here, so the space
          # resolves via the payload rung of the ladder rather than via
          # `Meetings.get_meeting/1` — which is what a dispatch looks
          # like when the meeting row is not the thing under test.
          meeting_id: Platform.Types.UUIDv7.generate(),
          intent_id: Platform.Types.UUIDv7.generate(),
          classified_intent: "action_items",
          confidence: 0.9,
          chunk_excerpt: "The onboarding revert has to happen before the mobile launch.",
          speaker: "Priya"
        },
        payload_overrides
      )

    capture_log(fn ->
      send(
        self(),
        {:fire_result,
         ResponsibilityRouter.fire(:meetings_action_items, %{
           kind: :event_topic,
           topic: "meeting:action_item_intent",
           payload: payload
         })}
      )
    end)

    assert_receive {:fire_result, result}
    result
  end

  defp action_item_messages(space_id) do
    space_id
    |> Chat.list_messages()
    |> Enum.filter(&(get_in(&1.metadata, ["source"]) == "meeting_action_items"))
  end

  # The delivery surface as of task 019fb90f-36e3 stage 4: a canvas, not
  # a message. `action_item_messages/1` is kept because the absence of
  # that markdown post is now itself an assertion — mid-meeting it would
  # repost the whole list once per utterance.
  defp action_items_canvases(space_id) do
    space_id
    |> Chat.list_canvases()
    |> Enum.filter(
      &(get_in(&1.metadata, ["source"]) == Platform.Meetings.ActionItemsCanvas.metadata_source())
    )
  end

  # A live queue row in `:dispatched` for `meeting_id`, exactly as
  # `IntentDispatcher` leaves it before broadcasting the trigger the
  # Router picks up. No meeting ROW is needed — the queue is ETS-backed
  # and keyed by id — which keeps these cases at the router seam rather
  # than dragging in meeting fixtures.
  defp dispatched_row!(meeting_id) do
    {:ok, row} =
      IntentQueue.enqueue(meeting_id, %{
        room_id: "seam-room-#{System.unique_integer([:positive])}",
        chunk_excerpt: "The onboarding revert has to happen before the mobile launch.",
        classified_intent: "action_items",
        confidence: 0.9
      })

    {:ok, dispatched} = IntentQueue.transition(meeting_id, row.id, :dispatched)

    on_exit(fn -> IntentQueue.stop(meeting_id) end)

    dispatched
  end

  defp row_status(meeting_id, intent_id) do
    {:ok, row} = IntentQueue.get(meeting_id, intent_id)
    row
  end

  defp labels_on(canvas_id) do
    {:ok, %{document: document}} = Platform.Chat.Canvas.Server.describe(canvas_id)

    document
    |> Platform.Meetings.ActionItemsCanvas.summarize()
    |> Enum.map(& &1.label)
  end

  # ── defect 2 — the prompt never carried the transcript ────────────────────

  describe "dispatch prompt (defect 2 — un-seeded template name as the user turn)" do
    test "POST body carries real transcript content, not the literal template name" do
      _ = seed_action_items_row!()
      _agent = seed_action_items_agent!()
      _registry = start_registry!()

      space = create_space!()

      transcript =
        create_transcript!(%{space_id: space.id, segments: dialogue_segments()})

      stub_ok(~s({"action_items": ["Revert onboarding by Friday"]}))

      assert {:ok, :dispatched} = fire!(transcript.id, space.id)

      assert_receive {:dispatch_body, raw_body}, 5_000
      decoded = Jason.decode!(raw_body)

      messages = decoded["messages"]
      assert is_list(messages)

      user_msg = Enum.find(messages, &(&1["role"] == "user"))
      assert user_msg, "dispatch carried no user turn: #{inspect(messages)}"

      # The live e2e capture had EXACTLY this as the whole user turn.
      # The slug is the name of the prompt, never the prompt.
      refute user_msg["content"] == "meetings.action_items.v1"
      refute user_msg["content"] =~ "meetings.action_items.v1"

      # Stage 3 splits the turns: the user turn is the ONE classified
      # utterance being acted on, and everything standing — the window,
      # the canvas, the org identity — is in the system turn.
      assert user_msg["content"] =~ "Priya"
      assert user_msg["content"] =~ "onboarding revert has to happen"

      system_msg = Enum.find(messages, &(&1["role"] == "system"))
      assert system_msg
      assert system_msg["content"] =~ "action item"

      # The system turn is the migrated DB row, rendered — not a
      # heredoc, and not a body carrying literal markers. Both halves
      # matter: the mid-meeting framing only exists in the migrated row,
      # and surrounding transcript only reaches the model through an
      # interpolated assign.
      assert system_msg["content"] =~ "DURING a live meeting"
      refute system_msg["content"] =~ "A meeting just ended"
      refute system_msg["content"] =~ "{{"
      assert system_msg["content"] =~ "Alex"
      assert system_msg["content"] =~ "deploy audit"
    end

    test "a blank utterance refuses the dispatch rather than prompting on nothing" do
      _ = seed_action_items_row!()
      _agent = seed_action_items_agent!()
      _registry = start_registry!()

      space = create_space!()

      transcript =
        create_transcript!(%{space_id: space.id, segments: dialogue_segments()})

      stub_ok(~s({"operations": []}))

      meeting_id = Platform.Types.UUIDv7.generate()
      row = dispatched_row!(meeting_id)

      # A full transcript and NO utterance: nothing to reconcile against
      # the canvas, so no round-trip. The refusal is `:no_intent_text`
      # and the transcript's presence does not rescue it.
      assert {:error, {:build_prompt_refused, :no_intent_text}} =
               fire!(transcript.id, space.id, %{
                 chunk_excerpt: "   ",
                 meeting_id: meeting_id,
                 intent_id: row.id
               })

      refute_receive {:dispatch_body, _}, 200
      assert action_item_messages(space.id) == []

      # THE HALF THAT SHIPPED BROKEN (task 019fb90f-36e3 e2e review).
      # The refusal above was always right; this file asserted it and
      # nothing else, so it stayed green while the row it left behind
      # never moved. `IntentDispatcher` had already put the row in
      # `:dispatched`, which pins the meeting's SERIAL cursor, and the
      # refusal returns through `Router.dispatch_external/5` without
      # ever reaching `handle_output/3` — the only thing that closed a
      # row. Measured against a monotonic clock the row read
      # `:dispatched` at t+3s/+30s/+60s/+90s and only reached
      # `:timed_out` at t+110s, released by the 90s claim watchdog. So
      # one blank utterance cost the meeting 90 seconds of queue and
      # every intent behind it waited.
      #
      # Asserted as the EXACT terminal status and reason, not as
      # `!= :dispatched`: the watchdog's `:timed_out` also satisfies
      # "not dispatched", 90 seconds later, which is precisely the bug.
      closed = row_status(meeting_id, row.id)

      assert closed.status == :dispatch_failed
      assert closed.dispatch_failure_reason == :no_intent_text

      # And no round trip is claimed for a round trip that never
      # happened — `:timed_out` would have stamped this.
      assert is_nil(closed.timed_out_at)

      # The consequence the row status is a proxy for: the next intent
      # can go out now, not in 90 seconds.
      assert IntentQueue.cursor(meeting_id) == nil
    end

    test "POSITIVE CONTROL: a dispatch that DOES happen still lands the row :completed" do
      # The presence side of the absence assertion above. "The row is no
      # longer stuck in :dispatched" is satisfiable by never dispatching
      # at all, so the refusal case cannot be read on its own — this
      # pins the same row, at the same seam, through a real round trip.
      _ = seed_action_items_row!()
      _agent = seed_action_items_agent!()
      _registry = start_registry!()

      space = create_space!()

      transcript =
        create_transcript!(%{space_id: space.id, segments: dialogue_segments()})

      stub_ok(~s({"operations": [{"op": "add", "label": "Ship the adapter fix"}]}))

      meeting_id = Platform.Types.UUIDv7.generate()
      row = dispatched_row!(meeting_id)

      assert {:ok, :dispatched} =
               fire!(transcript.id, space.id, %{meeting_id: meeting_id, intent_id: row.id})

      assert_receive {:dispatch_body, _}, 5_000

      closed = row_status(meeting_id, row.id)

      assert closed.status == :completed
      assert is_nil(closed.dispatch_failure_reason)
      assert IntentQueue.cursor(meeting_id) == nil
    end

    test "an utterance with NO transcript still dispatches — the refusal moved off the window" do
      # The dual of the case above, at the router seam rather than in a
      # unit test. Before stage 3 a blank window refused; mid-meeting the
      # first action item routinely lands before the transcript row
      # exists, and the utterance is the ground truth on its own.
      _ = seed_action_items_row!()
      _agent = seed_action_items_agent!()
      _registry = start_registry!()

      space = create_space!()
      transcript = create_transcript!(%{space_id: space.id, segments: []})

      stub_ok(~s({"operations": []}))

      assert {:ok, :dispatched} = fire!(transcript.id, space.id)
      assert_receive {:dispatch_body, raw_body}, 5_000

      messages = Jason.decode!(raw_body)["messages"]
      user_msg = Enum.find(messages, &(&1["role"] == "user"))
      assert user_msg["content"] =~ "onboarding revert has to happen"

      system_msg = Enum.find(messages, &(&1["role"] == "system"))
      assert system_msg["content"] =~ "no surrounding transcript captured yet"
    end
  end

  # ── defect 1 — the freeform string never became items ─────────────────────

  describe "output handling (defect 1 — validator hands the handler a binary)" do
    test "a JSON-object STRING response lands both items on a canvas" do
      _ = seed_action_items_row!()
      _agent = seed_action_items_agent!()
      _registry = start_registry!()

      space = create_space!()

      transcript =
        create_transcript!(%{space_id: space.id, segments: dialogue_segments()})

      stub_ok(
        ~s({"operations": [{"op": "add", "label": "Ship the adapter fix"},) <>
          ~s( {"op": "add", "label": "Email Rowan the audit"}]})
      )

      assert {:ok, :dispatched} = fire!(transcript.id, space.id)
      assert_receive {:dispatch_body, _}, 5_000

      assert [canvas] = action_items_canvases(space.id)
      assert labels_on(canvas.id) == ["Ship the adapter fix", "Email Rowan the audit"]

      # And the POST-meeting markdown surface stayed out of it.
      assert action_item_messages(space.id) == []
    end

    test "the pre-stage-3 action_items JSON shape is refused, not shredded into prose" do
      # Byte-for-byte the content the live e2e run's model returned —
      # `server3.log:1392` logged it as an "unexpected output shape".
      # It parses as JSON and is not the operations contract, so it is a
      # contract violation. Sending it to the prose splitter would invent
      # action items out of its punctuation.
      _ = seed_action_items_row!()
      _agent = seed_action_items_agent!()
      _registry = start_registry!()

      space = create_space!()

      transcript =
        create_transcript!(%{space_id: space.id, segments: dialogue_segments()})

      stub_ok(~s({"action_items": ["Ship the adapter fix", "Email Rowan the audit"]}))

      assert {:ok, :dispatched} = fire!(transcript.id, space.id)
      assert_receive {:dispatch_body, _}, 5_000

      assert action_items_canvases(space.id) == []
      assert action_item_messages(space.id) == []
    end

    test "a plain-prose bulleted list response lands every item" do
      _ = seed_action_items_row!()
      _agent = seed_action_items_agent!()
      _registry = start_registry!()

      space = create_space!()

      transcript =
        create_transcript!(%{space_id: space.id, segments: dialogue_segments()})

      stub_ok("""
      - Revert the onboarding flow before the mobile launch (Priya, Friday)

      * Email Rowan the deploy audit once the adapter fix lands
      1. Book the compliance sign-off with the design partners
      """)

      assert {:ok, :dispatched} = fire!(transcript.id, space.id)
      assert_receive {:dispatch_body, _}, 5_000

      assert [canvas] = action_items_canvases(space.id)

      # List markers are stripped exactly once, not doubled up — asserted
      # as equality on the labels rather than as a `refute` on a rendered
      # body, so a marker that survives cannot hide inside other text.
      assert labels_on(canvas.id) == [
               "Revert the onboarding flow before the mobile launch (Priya, Friday)",
               "Email Rowan the deploy audit once the adapter fix lands",
               "Book the compliance sign-off with the design partners"
             ]
    end

    test "a string with no extractable items writes nothing and stays :ok" do
      _ = seed_action_items_row!()
      _agent = seed_action_items_agent!()
      _registry = start_registry!()

      space = create_space!()

      transcript =
        create_transcript!(%{space_id: space.id, segments: dialogue_segments()})

      stub_ok("   \n\n  \n")

      assert {:ok, :dispatched} = fire!(transcript.id, space.id)
      assert_receive {:dispatch_body, _}, 5_000

      assert action_items_canvases(space.id) == []
      assert action_item_messages(space.id) == []
    end
  end
end
