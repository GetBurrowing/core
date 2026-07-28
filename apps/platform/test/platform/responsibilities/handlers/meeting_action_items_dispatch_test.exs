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

  defp fire!(transcript_id, space_id) do
    capture_log(fn ->
      send(
        self(),
        {:fire_result,
         ResponsibilityRouter.fire(:meetings_action_items, %{
           kind: :event_topic,
           topic: "meeting:finished",
           payload: %{transcript_id: transcript_id, space_id: space_id}
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
      refute user_msg["content"] == "meetings.action_items.v1"
      refute user_msg["content"] =~ "meetings.action_items.v1"

      # Real transcript content reaches the model.
      assert user_msg["content"] =~ "Priya"
      assert user_msg["content"] =~ "onboarding revert"
      assert user_msg["content"] =~ "Alex"
      assert user_msg["content"] =~ "deploy audit"

      # A system turn frames the extraction task.
      system_msg = Enum.find(messages, &(&1["role"] == "system"))
      assert system_msg
      assert system_msg["content"] =~ "action item"
    end

    test "an empty transcript refuses the dispatch rather than prompting on nothing" do
      _ = seed_action_items_row!()
      _agent = seed_action_items_agent!()
      _registry = start_registry!()

      space = create_space!()
      transcript = create_transcript!(%{space_id: space.id, segments: []})

      stub_ok(~s({"action_items": ["should never be asked for"]}))

      assert {:error, {:build_prompt_refused, :no_transcript_text}} =
               fire!(transcript.id, space.id)

      refute_receive {:dispatch_body, _}, 200
      assert action_item_messages(space.id) == []
    end
  end

  # ── defect 1 — the freeform string never became items ─────────────────────

  describe "output handling (defect 1 — validator hands the handler a binary)" do
    test "a JSON-object STRING response lands both items as a message in the space" do
      _ = seed_action_items_row!()
      _agent = seed_action_items_agent!()
      _registry = start_registry!()

      space = create_space!()

      transcript =
        create_transcript!(%{space_id: space.id, segments: dialogue_segments()})

      # Byte-for-byte the content the live e2e run's model returned —
      # `server3.log:1392` logged it as an "unexpected output shape".
      stub_ok(~s({"action_items": ["Ship the adapter fix", "Email Rowan the audit"]}))

      assert {:ok, :dispatched} = fire!(transcript.id, space.id)
      assert_receive {:dispatch_body, _}, 5_000

      assert [message] = action_item_messages(space.id)
      assert message.content =~ "Action Items"
      assert message.content =~ "- [ ] Ship the adapter fix"
      assert message.content =~ "- [ ] Email Rowan the audit"
      assert message.metadata["transcript_id"] == transcript.id
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

      assert [message] = action_item_messages(space.id)
      assert message.content =~ "- [ ] Revert the onboarding flow before the mobile launch"
      assert message.content =~ "- [ ] Email Rowan the deploy audit once the adapter fix lands"
      assert message.content =~ "- [ ] Book the compliance sign-off with the design partners"

      # List markers are stripped exactly once, not doubled up.
      refute message.content =~ "- [ ] - "
      refute message.content =~ "- [ ] * "
      refute message.content =~ "- [ ] 1. "
    end

    test "a string with no extractable items posts nothing and stays :ok" do
      _ = seed_action_items_row!()
      _agent = seed_action_items_agent!()
      _registry = start_registry!()

      space = create_space!()

      transcript =
        create_transcript!(%{space_id: space.id, segments: dialogue_segments()})

      stub_ok("   \n\n  \n")

      assert {:ok, :dispatched} = fire!(transcript.id, space.id)
      assert_receive {:dispatch_body, _}, 5_000

      assert action_item_messages(space.id) == []
    end
  end
end
