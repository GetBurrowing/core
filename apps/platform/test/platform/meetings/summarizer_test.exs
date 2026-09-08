defmodule Platform.Meetings.SummarizerTest.SlowOllamaPlug do
  @moduledoc """
  A real HTTP endpoint speaking the Ollama OpenAI-compatible chat shape that
  stalls before answering.

  Mirrors `Platform.Agents.Providers.OllamaTest.SlowPlug` (task 01a0826f
  stage 1) rather than a `Req.Test` stub on purpose: a plug stub runs
  in-process and never reaches the Finch socket, so it cannot observe a
  `receive_timeout` at all.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    Process.sleep(Keyword.fetch!(opts, :sleep_ms))

    body =
      Jason.encode!(%{
        "model" => "concierge",
        "choices" => [
          %{
            "index" => 0,
            "finish_reason" => "stop",
            "message" => %{
              "role" => "assistant",
              "content" => "## Summary\n\nThe team discussed the Q3 roadmap."
            }
          }
        ],
        "usage" => %{"prompt_tokens" => 40, "completion_tokens" => 12, "total_tokens" => 52}
      })

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, body)
  end
end

defmodule Platform.Meetings.SummarizerTest do
  @moduledoc false
  # M8 stage 4 added bridge tests that toggle global resources (Role
  # seeds, per-case Registry, telemetry handlers, Config app env), so
  # this case must run synchronously to keep the toggles from leaking
  # across processes.
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Meetings
  alias Platform.Meetings.Summarizer
  alias Platform.Meetings.SummaryPrompt

  defp unique_id, do: Platform.Types.UUIDv7.generate()

  defp create_transcript!(overrides \\ %{}) do
    attrs =
      Map.merge(
        %{room_id: unique_id(), space_id: unique_id()},
        overrides
      )

    {:ok, transcript} = Meetings.create_transcript(attrs)
    transcript
  end

  # A real meeting room (participants key off the room UUID, while a
  # transcript keys off the LiveKit room NAME).
  defp presence_room! do
    {:ok, space} = Platform.Chat.create_space(%{kind: "execution"})

    {:ok, room} =
      %Platform.Meetings.Room{}
      |> Platform.Meetings.Room.changeset(%{
        space_id: space.id,
        livekit_room_name: "space-#{space.id}"
      })
      |> Platform.Repo.insert()

    {space, room}
  end

  defp transcriber_joined!(room, seconds_ago, opts \\ []),
    do: join!(room, "meeting-transcriber", seconds_ago, opts)

  defp human_joined!(room, name, seconds_ago, opts \\ []),
    do: join!(room, name, seconds_ago, opts)

  defp join!(room, display_name, seconds_ago, opts) do
    joined_at = DateTime.add(DateTime.utc_now(), -seconds_ago, :second)

    left_at =
      case Keyword.get(opts, :present_for) do
        nil -> nil
        secs -> DateTime.add(joined_at, secs, :second)
      end

    {:ok, participant} =
      Meetings.participant_joined(room, %{
        display_name: display_name,
        joined_at: joined_at,
        left_at: left_at
      })

    participant
  end

  defp sample_segments do
    [
      %{
        "participant_identity" => "user_1",
        "speaker_name" => "Harper",
        "text" => "Let's discuss the roadmap for Q3.",
        "start_time" => 0,
        "end_time" => 3000,
        "language" => "en",
        "final" => true
      },
      %{
        "participant_identity" => "user_2",
        "speaker_name" => "Alex",
        "text" => "I think we should focus on the mobile app.",
        "start_time" => 3500,
        "end_time" => 6000,
        "language" => "en",
        "final" => true
      },
      %{
        "participant_identity" => "user_1",
        "speaker_name" => "Harper",
        "text" => "Agreed. Let's make that the priority.",
        "start_time" => 6500,
        "end_time" => 9000,
        "language" => "en",
        "final" => true
      }
    ]
  end

  describe "SummaryPrompt.format_segments/1" do
    test "formats segments with speaker attribution and timestamps" do
      result = SummaryPrompt.format_segments(sample_segments())

      assert result =~ "[00:00:00] Harper: Let's discuss the roadmap for Q3."
      assert result =~ "[00:00:03] Alex: I think we should focus on the mobile app."
      assert result =~ "[00:00:06] Harper: Agreed. Let's make that the priority."
    end

    test "handles missing speaker name" do
      segments = [
        %{
          "participant_identity" => "user_1",
          "text" => "Hello",
          "start_time" => 0,
          "end_time" => 1000,
          "final" => true
        }
      ]

      result = SummaryPrompt.format_segments(segments)
      assert result =~ "[00:00:00] user_1: Hello"
    end

    test "handles missing participant identity and speaker name" do
      segments = [
        %{"text" => "Hello", "start_time" => 0, "end_time" => 1000, "final" => true}
      ]

      result = SummaryPrompt.format_segments(segments)
      assert result =~ "[00:00:00] Unknown: Hello"
    end

    test "handles nil start_time" do
      segments = [
        %{"speaker_name" => "Harper", "text" => "Hello", "start_time" => nil, "final" => true}
      ]

      result = SummaryPrompt.format_segments(segments)
      assert result =~ "[00:00:00] Harper: Hello"
    end

    test "formats large timestamps correctly" do
      segments = [
        %{
          "speaker_name" => "Harper",
          "text" => "Wrapping up",
          "start_time" => 3_723_000,
          "final" => true
        }
      ]

      result = SummaryPrompt.format_segments(segments)
      assert result =~ "[01:02:03] Harper: Wrapping up"
    end

    test "returns empty string for empty segments" do
      assert SummaryPrompt.format_segments([]) == ""
    end
  end

  describe "SummaryPrompt.system_prompt/0" do
    test "returns a non-empty string with expected sections" do
      prompt = SummaryPrompt.system_prompt()
      assert is_binary(prompt)
      assert prompt =~ "Overview"
      assert prompt =~ "Key Topics"
      assert prompt =~ "Decisions Made"
      assert prompt =~ "Action Items"
    end
  end

  describe "summarize_async/1" do
    test "rejects transcript with invalid status" do
      transcript = create_transcript!()
      # Set to complete status
      {:ok, completed} =
        Meetings.complete_transcript(transcript.id, "Already done")

      assert {:error, :invalid_status} = Summarizer.summarize_async(completed)
    end

    test "handles empty segments by marking complete" do
      transcript = create_transcript!()
      {:ok, finalized} = Meetings.finalize_transcript(transcript.id)

      assert {:ok, :empty} = Summarizer.summarize_async(finalized)

      # Verify transcript was completed with empty message
      updated = Meetings.get_transcript(transcript.id)
      assert updated.status == "complete"
      assert updated.summary == "This meeting had no transcribed content."
    end

    test "FAILURE CASE: zero segments with a transcriber present is marked failed" do
      {space, room} = presence_room!()
      transcript = create_transcript!(%{room_id: room.livekit_room_name, space_id: space.id})
      transcriber_joined!(room, 1800)

      {:ok, finalized} = Meetings.finalize_transcript(transcript.id)

      assert {:ok, :failed} = Summarizer.summarize_async(finalized)

      # Assert on the stored row, never on a log line — a log assertion
      # passes while the row still reads "complete".
      reloaded = Meetings.get_transcript(transcript.id)
      assert reloaded.status == "failed"
      assert reloaded.summary != "This meeting had no transcribed content."
      assert is_binary(reloaded.summary)

      # The humans in the space see it, not just a status column.
      notice =
        space.id
        |> Platform.Chat.list_messages(limit: 50)
        |> Enum.find(&(&1.metadata["source"] == "meeting_transcription_failure"))

      assert notice
      assert notice.content_type == "system"
      assert notice.metadata["transcript_id"] == transcript.id
    end

    test "GENUINE-SILENCE CONTROL: zero segments with only humans stays complete" do
      {space, room} = presence_room!()
      transcript = create_transcript!(%{room_id: room.livekit_room_name, space_id: space.id})
      human_joined!(room, "Harper", 3600)
      human_joined!(room, "Alex", 3600)

      {:ok, finalized} = Meetings.finalize_transcript(transcript.id)

      assert {:ok, :empty} = Summarizer.summarize_async(finalized)

      reloaded = Meetings.get_transcript(transcript.id)
      assert reloaded.status == "complete"
      assert reloaded.summary == "This meeting had no transcribed content."

      refute space.id
             |> Platform.Chat.list_messages(limit: 50)
             |> Enum.any?(&(&1.metadata["source"] == "meeting_transcription_failure"))
    end

    test "a transcriber present below the threshold is still genuine silence" do
      {space, room} = presence_room!()
      transcript = create_transcript!(%{room_id: room.livekit_room_name, space_id: space.id})
      transcriber_joined!(room, 5, present_for: 5)

      {:ok, finalized} = Meetings.finalize_transcript(transcript.id)

      assert {:ok, :empty} = Summarizer.summarize_async(finalized)

      reloaded = Meetings.get_transcript(transcript.id)
      assert reloaded.status == "complete"
      assert reloaded.summary == "This meeting had no transcribed content."
    end

    test "SUCCESS CONTROL: a transcript WITH segments is not marked failed" do
      {space, room} = presence_room!()

      transcript =
        create_transcript!(%{
          room_id: room.livekit_room_name,
          space_id: space.id,
          segments: sample_segments()
        })

      transcriber_joined!(room, 3600)

      {:ok, finalized} = Meetings.finalize_transcript(transcript.id)

      assert {:ok, pid} = Summarizer.summarize_async(finalized)
      assert is_pid(pid)

      reloaded = Meetings.get_transcript(transcript.id)
      refute reloaded.status == "failed"
      refute reloaded.summary == "This meeting had no transcribed content."
    end

    test "rejects nil transcript" do
      assert {:error, :invalid_transcript} = Summarizer.summarize_async(nil)
    end

    test "rejects transcript missing required fields" do
      assert {:error, :missing_fields} = Summarizer.summarize_async(%{id: unique_id()})
    end
  end

  describe "run_summary/1 (synchronous)" do
    # Note: These tests mock the LLM call by testing the pipeline logic.
    # The actual Anthropic API call is not made in tests — we test the
    # formatting, error handling, and state transitions around it.

    test "formats segments correctly before LLM call" do
      # This tests the formatting pipeline that feeds into the LLM
      segments = sample_segments()
      formatted = SummaryPrompt.format_segments(segments)

      # Should have 3 lines, one per segment
      lines = String.split(formatted, "\n")
      assert length(lines) == 3

      # Each line should have timestamp, speaker, and text
      Enum.each(lines, fn line ->
        assert line =~ ~r/\[\d{2}:\d{2}:\d{2}\] \w+: .+/
      end)
    end
  end

  defmodule NoopNativeDispatcher do
    @moduledoc false
    # Mirrors the same-named module in router_test — gives the Router a
    # no-op native dispatch surface so we don't have to stand up
    # AgentResponder + chat plumbing just to prove the bridge fired.
    def maybe_dispatch(_signal), do: :ok
  end

  describe "M8 stage 4 dual-write bridge" do
    # The bridge gates the legacy LLM body on
    # `Platform.Responsibilities.Router.responsibility_filled?(:meetings_summarize)`.
    # When `true` → delegate to the router. When `false` → fall back to the
    # legacy body. We exercise both branches without standing up a full
    # external HTTP fixture by:
    #
    #   * using a `kind: "native"` agent (no endpoint_kind / base_url
    #     requirements), and
    #   * swapping the router's native dispatcher for a test no-op so
    #     `Router.fire/2` returns `:ok` without going through AgentResponder.

    alias Platform.Agents.Agent
    alias Platform.Repo
    alias Platform.Responsibilities.BuiltIns
    alias Platform.Responsibilities.Registry
    alias Platform.Roles
    alias Platform.Roles.Role
    alias Platform.Roles.RoleResponsibility

    setup do
      previous_dispatcher =
        Application.get_env(:platform, :responsibility_router_native_dispatcher)

      Application.put_env(
        :platform,
        :responsibility_router_native_dispatcher,
        {NoopNativeDispatcher, :maybe_dispatch}
      )

      on_exit(fn ->
        if previous_dispatcher do
          Application.put_env(
            :platform,
            :responsibility_router_native_dispatcher,
            previous_dispatcher
          )
        else
          Application.delete_env(:platform, :responsibility_router_native_dispatcher)
        end
      end)

      :ok
    end

    defp start_registry! do
      name = :"#{__MODULE__}.Reg#{System.unique_integer([:positive])}"
      _pid = start_supervised!({Registry, name: name, providers: BuiltIns.providers()})
      name
    end

    defp seed_role!(key) do
      case Repo.get(Role, key) do
        %Role{} = existing ->
          existing

        nil ->
          name = key |> String.replace("_", " ") |> String.capitalize()

          {:ok, role} =
            %Role{}
            |> Role.changeset(%{
              key: key,
              name: name,
              description: "test role #{key}",
              icon: "hero-star"
            })
            |> Repo.insert()

          role
      end
    end

    defp ensure_role_responsibility!(role_key, responsibility_key) do
      seed_role!(role_key)

      case Repo.get_by(RoleResponsibility,
             role_key: role_key,
             responsibility_key: responsibility_key
           ) do
        %RoleResponsibility{} = existing ->
          existing

        nil ->
          {:ok, rr} =
            %RoleResponsibility{}
            |> RoleResponsibility.changeset(%{
              role_key: role_key,
              responsibility_key: responsibility_key
            })
            |> Repo.insert()

          rr
      end
    end

    defp create_native_agent! do
      %Agent{}
      |> Agent.changeset(%{
        slug: "bridge-test-#{System.unique_integer([:positive])}",
        name: "Bridge Test Native",
        status: "active",
        kind: "native"
      })
      |> Repo.insert!()
    end

    test "router-filled path delegates to Router.fire and skips the legacy LLM call" do
      # Stand up the responsibility row + role assignment so
      # responsibility_filled?/1 sees a real assignee.
      _name = start_registry!()
      ensure_role_responsibility!("meeting_scribe", "meetings.summarize")
      agent = create_native_agent!()
      {:ok, _} = Roles.assign_role("meeting_scribe", agent.id)

      # Belt + braces — confirm the gate flipped.
      assert Platform.Responsibilities.Router.responsibility_filled?("meetings.summarize")

      transcript =
        create_transcript!(%{
          segments: [
            %{
              "speaker_name" => "Harper",
              "text" => "Quick standup.",
              "start_time" => 0,
              "end_time" => 500,
              "final" => true
            }
          ]
        })

      # Capture telemetry so we can assert the router actually fired
      # the responsibility (rather than the bridge silently falling
      # through to the legacy LLM body).
      test_pid = self()
      handler_id = "summarizer-router-bridge-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler_id,
        [
          [:platform, :responsibility, :fired],
          [:platform, :responsibility, :failed],
          [:platform, :responsibility, :unfilled]
        ],
        fn event, _measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert :ok = Summarizer.run_summary(transcript)

      assert_receive {:telemetry, [:platform, :responsibility, ev], %{key: "meetings.summarize"}},
                     1_000,
                     "expected responsibility telemetry from router.fire — got nothing, " <>
                       "which means the bridge fell through to the legacy LLM body"

      # ADR-0046 member 1 stage 3 tightened this from
      # `ev in [:fired, :failed]`. It has to be `:fired` now: a `:failed`
      # fire returns `{:error, _}` and a `:unfilled` one returns
      # `{:ok, :unfilled}`, and BOTH of those run `run_summary_legacy/3`,
      # which with no LLM provider configured returns
      # `{:error, {:llm_failed, _}}` — so the `assert :ok` above would
      # already have blown up. Asserting the weaker membership would now
      # be describing a state this test cannot be in.
      assert ev == :fired

      # Legacy body MUST NOT have touched the transcript — it should
      # still be in its starting `"recording"` status. The router-fired
      # path's `Handlers.MeetingSummarize.handle_output/3` only runs for
      # `:external` assignees in M6; the native dispatch is a no-op for
      # transcript state today (the M8 follow-up wires that).
      assert Meetings.get_transcript(transcript.id).status == "recording"
    end

    test "router-unfilled path runs the legacy body (no role assignment)" do
      # No agent assigned → responsibility_filled? returns false →
      # the bridge falls through to `run_summary_legacy/3`.
      _name = start_registry!()
      ensure_role_responsibility!("meeting_scribe", "meetings.summarize")

      refute Platform.Responsibilities.Router.responsibility_filled?("meetings.summarize")

      transcript = create_transcript!(%{segments: sample_segments()})

      # `Platform.Meetings.Config.summary/0` reads from priv/meetings.yml;
      # in test env that file doesn't exist so the resolved provider is
      # `:none` by default, and the legacy `call_llm/3` returns
      # `{:error, :no_summary_provider_configured}` without making any
      # network call — the cheapest proof that the legacy body executed
      # (and not the router).
      assert {:error, {:llm_failed, :no_summary_provider_configured}} =
               Summarizer.run_summary(transcript)

      # The legacy body marked the transcript failed.
      assert Meetings.get_transcript(transcript.id).status == "failed"
    end
  end

  # ── ADR-0046 member 1 stage 3 — the fire result decides the branch ──────
  #
  # The bridge's `{:error, reason}` clause in `run_summary/1` has existed
  # since M8 stage 4 and was UNREACHABLE for the failure it names: the
  # Router laundered every outcome into a flat `:ok`, so an assigned
  # external agent whose endpoint was down looked exactly like a
  # successful dispatch and the meeting summary was silently dropped.
  # Stages 1 and 2 of this task gave the Router a real return contract;
  # these two tests are the proof that the contract reaches this caller.
  #
  # They are a matched pair on ONE mechanism (external agent + stubbed
  # HTTP endpoint) differing only in the stubbed status code. That
  # pairing is what makes the control's absence assertion meaningful:
  # if the bridge gate were simply returning false and the Router were
  # never reached at all, the 503 case's "legacy ran" would still pass
  # while the 200 case's `assert_receive {:external_dispatch, _}` would
  # not.
  describe "ADR-0046 fire-result branching (external assignee)" do
    alias Platform.Agents.Agent
    alias Platform.Repo
    alias Platform.Roles

    @legacy_api_key_env "SUMMARIZER_STAGE3_ANTHROPIC_KEY"

    setup do
      {:ok, _} = Application.ensure_all_started(:req)

      # Seam 1 — the Router's external dispatcher.
      Application.put_env(
        :platform,
        :external_agents_dispatcher_req_client,
        Req.new(plug: {Req.Test, :summarizer_external_dispatch_test})
      )

      # Seam 2 — the LEGACY body's LLM call. Wiring a real (stubbed)
      # provider instead of leaving `provider: :none` is what turns
      # "did the legacy body run?" into a message the test process can
      # receive, rather than an inference from transcript state. Both
      # tests below wire it identically; only one of them expects it to
      # be called.
      System.put_env(@legacy_api_key_env, "sk-summarizer-stage3")

      previous_summary_cfg = Application.get_env(:platform, :meetings_summary)

      Application.put_env(:platform, :meetings_summary, %{
        provider: :anthropic,
        model: "claude-stage3-test",
        api_key_env: @legacy_api_key_env,
        max_tokens: 2048,
        temperature: 0.3
      })

      Application.put_env(
        :platform,
        :anthropic_req_client,
        Req.new(plug: {Req.Test, :summarizer_legacy_llm_test})
      )

      on_exit(fn ->
        Application.delete_env(:platform, :external_agents_dispatcher_req_client)
        Application.delete_env(:platform, :anthropic_req_client)
        System.delete_env(@legacy_api_key_env)

        if previous_summary_cfg do
          Application.put_env(:platform, :meetings_summary, previous_summary_cfg)
        else
          Application.delete_env(:platform, :meetings_summary)
        end
      end)

      :ok
    end

    # Mirrors wire_external_assignee/1 at
    # test/platform/responsibilities/router_test.exs:1088-1128, but pinned
    # to the meeting_scribe role so `responsibility_filled?/1` — the
    # bridge gate — flips for "meetings.summarize" specifically.
    defp wire_external_scribe! do
      ensure_role_responsibility!("meeting_scribe", "meetings.summarize")

      agent =
        %Agent{}
        |> Agent.changeset(%{
          slug: "summarizer-stage3-ext-#{System.unique_integer([:positive])}",
          name: "Summarizer Stage 3 External",
          status: "active",
          kind: "external",
          endpoint_kind: "openai_compat",
          base_url: "https://api.example.test",
          model: "test-model",
          workspace_id: nil
        })
        |> Repo.insert!()

      :ok = Platform.ExternalAgents.EphemeralCredentials.put(agent.id, "sk-summarizer-stage3")
      on_exit(fn -> Platform.ExternalAgents.EphemeralCredentials.delete(agent.id) end)

      {:ok, _} = Roles.assign_role("meeting_scribe", agent.id)

      agent
    end

    # The legacy body's only outbound side effect. Sends a message on
    # every call and answers 400 — deliberately NOT 5xx, which Req
    # retries, and deliberately an error so the legacy body terminates in
    # `{:error, {:llm_failed, _}}` + `fail_transcript/1`, the same
    # proof-of-legacy the router-unfilled test above uses.
    defp stub_legacy_llm!(test_pid) do
      Req.Test.stub(:summarizer_legacy_llm_test, fn conn ->
        send(test_pid, :legacy_llm_called)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, ~s({"error":{"message":"legacy stub"}}))
      end)
    end

    test "FIX DETECTOR — a failed external dispatch falls back to the legacy body" do
      _name = start_registry!()
      _agent = wire_external_scribe!()

      # The gate must be filled, otherwise this test proves nothing about
      # the fire result — it would just be the `else` branch again.
      assert Platform.Responsibilities.Router.responsibility_filled?("meetings.summarize")

      test_pid = self()
      stub_legacy_llm!(test_pid)

      Req.Test.stub(:summarizer_external_dispatch_test, fn conn ->
        send(test_pid, {:external_dispatch, conn.request_path})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(503, ~s({"error":"down"}))
      end)

      transcript = create_transcript!(%{segments: sample_segments()})

      # `capture_log/2` runs the function in this process, so stashing the
      # return value through the mailbox is the cheapest way to get it
      # back out without shadowing.
      log =
        capture_log([level: :warning], fn ->
          send(self(), {:run_summary_result, Summarizer.run_summary(transcript)})
        end)

      assert_receive {:run_summary_result, result}

      # 1. The Router really was reached and really did try the endpoint.
      assert_receive {:external_dispatch, "/chat/completions"}

      # 2. The previously-unreachable clause fired.
      assert log =~ "[Summarizer] Router fire failed for transcript #{transcript.id}"
      assert log =~ "dispatch_failed"

      # 3. The legacy body ran — observed directly at its LLM seam, not
      #    inferred. THIS is the assertion that fails against the
      #    pre-task code, where the fire returned `:ok` and `run_summary/1`
      #    returned `:ok` having produced nothing.
      assert_receive :legacy_llm_called

      # 4. …and ran to completion, terminating the transcript rather than
      #    leaving it stuck in "recording" forever.
      assert {:error, {:llm_failed, _reason}} = result
      assert Meetings.get_transcript(transcript.id).status == "failed"
    end

    test "POSITIVE CONTROL — a successful external dispatch does NOT run the legacy body" do
      # Identical wiring to the detector; the stubbed status is the only
      # difference. Without this, the detector's "legacy ran" could be
      # satisfied by a bridge that never consulted the Router at all.
      _name = start_registry!()
      _agent = wire_external_scribe!()

      assert Platform.Responsibilities.Router.responsibility_filled?("meetings.summarize")

      test_pid = self()
      stub_legacy_llm!(test_pid)

      Req.Test.stub(:summarizer_external_dispatch_test, fn conn ->
        send(test_pid, {:external_dispatch, conn.request_path})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "choices" => [
              %{
                "message" => %{
                  "role" => "assistant",
                  "content" =>
                    Jason.encode!(%{"summary" => "Router summary.", "action_items" => []})
                }
              }
            ]
          })
        )
      end)

      transcript = create_transcript!(%{segments: sample_segments()})

      log =
        capture_log([level: :warning], fn ->
          assert :ok = Summarizer.run_summary(transcript)
        end)

      # Same mechanism as the detector, exercised for real.
      assert_receive {:external_dispatch, "/chat/completions"}

      # The legacy seam is wired and reachable in this test — it simply
      # was not used. That is the whole content of the control.
      refute_receive :legacy_llm_called, 200
      refute log =~ "Router fire failed for transcript"
      refute Meetings.get_transcript(transcript.id).status == "failed"
    end
  end

  # ── task 019fa56b-c81f stage 2 — one dispatch per transcript ────────────
  #
  # Stage 1 repaired the Router's event_topic adapter, so the
  # `meeting:finished` broadcast that `LivekitWebhookController`
  # `maybe_trigger_summary/1` emits now reaches the Router AND fires
  # `meetings.summarize`. The same controller call also runs
  # `Summarizer.summarize_async/1`, whose `run_summary/1` fires
  # `meetings.summarize` directly (summarizer.ex:101). Two dispatch
  # decisions, two processes, one transcript. These tests pin that
  # exactly one of them survives.
  describe "meeting:finished dispatch is claimed once per transcript" do
    alias Platform.Repo
    alias Platform.Responsibilities.Router, as: RespRouter

    @claim_legacy_api_key_env "SUMMARIZER_CLAIM_ANTHROPIC_KEY"
    @fired_event [:platform, :responsibility, :fired]

    setup do
      {:ok, _} = Application.ensure_all_started(:req)

      # config/test.exs pins the logger to :warning, so the dedupe's
      # Logger.info lines would never reach capture_log otherwise.
      Logger.put_module_level(Platform.Meetings.Summarizer, :info)
      Logger.put_module_level(Platform.Responsibilities.Handlers.MeetingSummarize, :info)

      on_exit(fn ->
        Logger.delete_module_level(Platform.Meetings.Summarizer)
        Logger.delete_module_level(Platform.Responsibilities.Handlers.MeetingSummarize)
      end)

      Application.put_env(
        :platform,
        :external_agents_dispatcher_req_client,
        Req.new(plug: {Req.Test, :summarizer_external_dispatch_test})
      )

      System.put_env(@claim_legacy_api_key_env, "sk-summarizer-claim")
      previous_summary_cfg = Application.get_env(:platform, :meetings_summary)

      Application.put_env(:platform, :meetings_summary, %{
        provider: :anthropic,
        model: "claude-claim-test",
        api_key_env: @claim_legacy_api_key_env,
        max_tokens: 2048,
        temperature: 0.3
      })

      Application.put_env(
        :platform,
        :anthropic_req_client,
        Req.new(plug: {Req.Test, :summarizer_legacy_llm_test})
      )

      on_exit(fn ->
        Application.delete_env(:platform, :external_agents_dispatcher_req_client)
        Application.delete_env(:platform, :anthropic_req_client)
        System.delete_env(@claim_legacy_api_key_env)

        if previous_summary_cfg do
          Application.put_env(:platform, :meetings_summary, previous_summary_cfg)
        else
          Application.delete_env(:platform, :meetings_summary)
        end
      end)

      :ok
    end

    # Count dispatches exactly. `[:platform, :responsibility, :fired]` is
    # emitted once per successful dispatch (router.ex emit_fired_telemetry),
    # so the collected list length IS the dispatch count.
    defp attach_fired_telemetry!(test_pid) do
      handler_id = "summarizer-claim-fired-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        @fired_event,
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:responsibility_fired, metadata[:key]})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    defp collect(tag, acc \\ []) do
      receive do
        {^tag, value} -> collect(tag, [value | acc])
      after
        250 -> Enum.reverse(acc)
      end
    end

    # A per-transcript marker that survives into the rendered prompt, so
    # "exactly one dispatch" can be checked for IDENTITY and not just
    # arity. `[:platform, :responsibility, :fired]` metadata carries only
    # key/feature/dispatch_kind/agent_slug — no transcript_id — so the
    # dispatched request body is the honest identity channel.
    defp marked_segments(marker) do
      [
        %{
          "participant_identity" => "user_1",
          "speaker_name" => "Harper",
          "text" => "The single agenda item is #{marker}.",
          "start_time" => 0,
          "end_time" => 3000,
          "language" => "en",
          "final" => true
        }
      ]
    end

    defp stub_external_summary!(test_pid) do
      Req.Test.stub(:summarizer_external_dispatch_test, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:external_dispatch, body})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "choices" => [
              %{
                "message" => %{
                  "role" => "assistant",
                  "content" =>
                    Jason.encode!(%{"summary" => "Router summary.", "action_items" => []})
                }
              }
            ]
          })
        )
      end)
    end

    # The envelope the Router's event_topic fan-out hands to
    # `fire_trigger/3` after stage 1's adapter fix. Driving `fire/2` with
    # it exercises the identical dispatch pipeline without a second
    # PubSub hop — `router_test.exs` covers broadcast -> fire_trigger,
    # and this file covers fire_trigger -> exactly-one-dispatch.
    defp fire_as_router(transcript) do
      RespRouter.fire("meetings.summarize", %{
        kind: :event_topic,
        topic: "meeting:finished",
        payload: %{transcript_id: transcript.id, space_id: transcript.space_id}
      })
    end

    test "POSITIVE CONTROL — both paths, one transcript, EXACTLY ONE dispatch carrying its id" do
      _name = start_registry!()
      _agent = wire_external_scribe!()
      assert RespRouter.responsibility_filled?("meetings.summarize")

      test_pid = self()
      stub_legacy_llm!(test_pid)
      stub_external_summary!(test_pid)
      attach_fired_telemetry!(test_pid)

      marker = "MARKER-#{System.unique_integer([:positive])}"
      transcript = create_transcript!(%{segments: marked_segments(marker), space_id: nil})
      assert is_nil(transcript.router_dispatched_at)

      # Path A — the Summarizer's direct bridge fire (summarizer.ex:101).
      assert :ok = Summarizer.run_summary(transcript)

      claimed_at = Meetings.get_transcript(transcript.id).router_dispatched_at
      assert %DateTime{} = claimed_at

      # Path B — the broadcast the Router now actually delivers.
      capture_log([level: :info], fn ->
        assert {:error, {:context_gather_refused, :already_dispatched}} =
                 fire_as_router(transcript)
      end)

      # 1. COUNT. Not `<= 1` — zero is the trivially-passing answer and
      #    is precisely the pre-stage-1 regression.
      assert collect(:responsibility_fired) == ["meetings.summarize"]

      # 2. IDENTITY. The one dispatch carried THIS transcript's content.
      assert [body] = collect(:external_dispatch)
      assert body =~ marker

      # 3. The loser never reached the LLM at all — the claim is taken
      #    BEFORE the round-trip, not after it.
      # 4. And it did not silently divert into the legacy body.
      refute_receive :legacy_llm_called, 200

      # 5. router_dispatched_at moved nil -> non-nil exactly once; the
      #    losing path did not re-stamp it.
      assert DateTime.compare(
               Meetings.get_transcript(transcript.id).router_dispatched_at,
               claimed_at
             ) == :eq
    end

    test "the claim is PER ROW — a second, different transcript still dispatches" do
      _name = start_registry!()
      _agent = wire_external_scribe!()

      test_pid = self()
      stub_legacy_llm!(test_pid)
      stub_external_summary!(test_pid)
      attach_fired_telemetry!(test_pid)

      marker_one = "FIRST-#{System.unique_integer([:positive])}"
      marker_two = "SECOND-#{System.unique_integer([:positive])}"
      one = create_transcript!(%{segments: marked_segments(marker_one), space_id: nil})
      two = create_transcript!(%{segments: marked_segments(marker_two), space_id: nil})

      capture_log([level: :info], fn ->
        assert :ok = Summarizer.run_summary(one)
        assert {:error, {:context_gather_refused, :already_dispatched}} = fire_as_router(one)

        assert :ok = Summarizer.run_summary(two)
        assert {:error, {:context_gather_refused, :already_dispatched}} = fire_as_router(two)
      end)

      # Two transcripts, two dispatches — the claim is a per-row latch,
      # not a global one that suppresses everything after the first.
      assert collect(:responsibility_fired) == ["meetings.summarize", "meetings.summarize"]

      assert [body_one, body_two] = collect(:external_dispatch)
      assert body_one =~ marker_one
      assert body_two =~ marker_two

      refute is_nil(Meetings.get_transcript(one.id).router_dispatched_at)
      refute is_nil(Meetings.get_transcript(two.id).router_dispatched_at)
    end

    test "a lost claim returns :ok and does NOT fall through to the legacy body" do
      # THE SUBTLE BRANCH. `{:ok, :unfilled}` / `{:ok, :unknown_responsibility}`
      # mean nobody is producing a summary, so they MUST run the legacy
      # body (ADR-0046 member 1). A lost claim means the OTHER dispatch
      # path is producing it, so running legacy here would be the double
      # summary this stage exists to prevent.
      _name = start_registry!()
      _agent = wire_external_scribe!()
      assert RespRouter.responsibility_filled?("meetings.summarize")

      test_pid = self()
      stub_legacy_llm!(test_pid)
      stub_external_summary!(test_pid)
      attach_fired_telemetry!(test_pid)

      transcript = create_transcript!(%{segments: sample_segments()})

      # Simulate the Router's broadcast path having won the race first.
      assert {:ok, :claimed} = Meetings.claim_router_dispatch(transcript.id)

      log =
        capture_log([level: :info], fn ->
          assert :ok = Summarizer.run_summary(transcript)
        end)

      # Both halves of the refusal are visible: the handler declined
      # before the round-trip, and the bridge chose NOT to fall back.
      assert log =~ "[meetings.summarize] dispatch for transcript #{transcript.id} was already"
      assert log =~ "already holds a router dispatch claim"
      assert log =~ "NOT running the legacy body"

      # The legacy seam is wired and reachable in this test — it simply
      # was not used. Same shape as the ADR-0046 positive control.
      refute_receive :legacy_llm_called, 200
      assert collect(:external_dispatch) == []
      assert collect(:responsibility_fired) == []

      # Not marked failed: this is a healthy dedupe, not an error.
      refute Meetings.get_transcript(transcript.id).status == "failed"
    end

    test "the skip log states the row's OBSERVED status and claim time, not a live producer" do
      # Task 01a0826f stage 3. The old message asserted "the other path
      # is producing the summary" — a claim about a live producer that
      # this clause never checked (on prod 2026-09-08 the claimed work
      # had been dead six days and the line still said that). The log
      # must now report only what it read off the row.
      _name = start_registry!()
      _agent = wire_external_scribe!()

      test_pid = self()
      stub_legacy_llm!(test_pid)
      stub_external_summary!(test_pid)
      attach_fired_telemetry!(test_pid)

      transcript = create_transcript!(%{segments: sample_segments()})
      assert {:ok, :claimed} = Meetings.claim_router_dispatch(transcript.id)

      # Move the row to a status the message could only know by reading
      # it. `processing` is not the row's default (`recording`), so a
      # hardcoded or defaulted status cannot satisfy this.
      row =
        Meetings.get_transcript(transcript.id)
        |> Ecto.Changeset.change(%{status: "processing"})
        |> Repo.update!()

      log =
        capture_log([level: :info], fn ->
          assert :ok = Summarizer.run_summary(transcript)
        end)

      # Not merely "contains status=" — the VALUE must match the row we
      # set up, and the claim timestamp must be the one actually stored.
      assert log =~ "status=processing"
      assert log =~ "claimed_at=#{inspect(row.router_dispatched_at)}"

      # The unchecked assertion is gone in every phrasing it had.
      refute log =~ "is producing the summary"
      refute log =~ "producing the summary"

      # Control: behaviour is unchanged — still :ok, still no fallback.
      refute_receive :legacy_llm_called, 200
      assert collect(:external_dispatch) == []
    end

    test "CONTRAST — an unfilled responsibility STILL runs the legacy body" do
      # Without this, the previous test's "legacy did not run" would also
      # be satisfied by a bridge that never runs the legacy body at all.
      _name = start_registry!()
      refute RespRouter.responsibility_filled?("meetings.summarize")

      test_pid = self()
      stub_legacy_llm!(test_pid)
      attach_fired_telemetry!(test_pid)

      transcript = create_transcript!(%{segments: sample_segments()})

      capture_log([level: :warning], fn ->
        assert {:error, {:llm_failed, _}} = Summarizer.run_summary(transcript)
      end)

      assert_receive :legacy_llm_called

      # And an unfilled responsibility never takes the claim — the
      # transcript stays available for a later router dispatch.
      assert is_nil(Repo.reload!(transcript).router_dispatched_at)
    end
  end

  # ── task 019f2570 stage 2 — legacy path max_tokens regression (bug 2) ──
  describe "Config.summary/0 max_tokens (legacy fallback)" do
    test "Config.summary().max_tokens stays 2048 — external dispatch changes MUST NOT touch this" do
      # Stage 2 plumbs `max_tokens` through the *external* dispatcher
      # (Handlers.MeetingSummarize declares 2500 in metadata). The
      # legacy path — `Summarizer.run_summary_legacy` via
      # `Platform.Meetings.Config.summary().max_tokens` — is
      # deliberately left at 2048 to keep the Anthropic / OpenAI
      # legacy adapters bit-identical to their pre-019f2570 behaviour.
      assert Platform.Meetings.Config.summary().max_tokens == 2048
    end
  end

  # ── task 019ff6f3 stage 3 ────────────────────────────────────────────────
  #
  # Three failures that can regress independently:
  #
  #   1. A failed transcript that says nothing about why it failed.
  #   2. A router dispatch invisible to `SummarizerSweeper` because
  #      nothing stamps `router_dispatched_at` at hand-off.
  #   3. An empty row publishing a negative claim about a room that
  #      holds transcribed content on another row.
  describe "a failed transcript records why it failed" do
    test "a real LLM failure on a POPULATED row writes a failure_reason" do
      # A real failure, not a hand-written row: with no summary provider
      # configured, `call_llm/3` returns
      # `{:error, :no_summary_provider_configured}` and the legacy body
      # takes its `{:llm_failed, _}` branch. Writing the row directly
      # would prove only that Ecto stores strings.
      transcript = create_transcript!(%{segments: sample_segments()})

      log =
        capture_log(fn ->
          assert {:error, {:llm_failed, :no_summary_provider_configured}} =
                   Summarizer.run_summary(transcript)
        end)

      _ = log
      failed = Meetings.get_transcript(transcript.id)

      assert failed.status == "failed"
      assert failed.failure_reason =~ "llm_failed"
      assert failed.failure_reason =~ "no_summary_provider_configured"
    end

    test "INVARIANT: a transcript holding segments never ends failed with a NULL summary AND a NULL reason" do
      transcript = create_transcript!(%{segments: sample_segments()})

      capture_log(fn ->
        assert {:error, {:llm_failed, _}} = Summarizer.run_summary(transcript)
      end)

      failed = Meetings.get_transcript(transcript.id)

      assert failed.segments != [],
             "fixture defect: this invariant is only about rows that HOLD segments"

      assert failed.status == "failed"

      refute is_nil(failed.summary) and is_nil(failed.failure_reason),
             "transcript #{failed.id} holds #{length(failed.segments)} segments and ended " <>
               "at status=failed with summary=nil AND failure_reason=nil — the row is mute " <>
               "on every surface a human can reach"
    end

    test "fail_transcript/3 caps a huge reason instead of blowing the column" do
      transcript = create_transcript!(%{segments: sample_segments()})
      huge = String.duplicate("a", 5_000)

      capture_log(fn ->
        assert {:ok, _} = Meetings.fail_transcript(transcript.id, nil, huge)
      end)

      failed = Meetings.get_transcript(transcript.id)
      assert byte_size(failed.failure_reason) <= 500
      assert String.valid?(failed.failure_reason)
    end

    test "fail_transcript/1 and /2 keep their old behaviour and leave failure_reason nil" do
      one = create_transcript!(%{segments: sample_segments()})
      two = create_transcript!(%{segments: sample_segments()})

      capture_log(fn ->
        assert {:ok, _} = Meetings.fail_transcript(one.id)
        assert {:ok, _} = Meetings.fail_transcript(two.id, "human readable prose")
      end)

      assert %{status: "failed", summary: nil, failure_reason: nil} =
               Meetings.get_transcript(one.id)

      # The arity-2 position is still a SUMMARY, not a reason.
      assert %{status: "failed", summary: "human readable prose", failure_reason: nil} =
               Meetings.get_transcript(two.id)
    end
  end

  describe "a router dispatch is visible to the sweeper" do
    setup do
      previous_dispatcher =
        Application.get_env(:platform, :responsibility_router_native_dispatcher)

      Application.put_env(
        :platform,
        :responsibility_router_native_dispatcher,
        {NoopNativeDispatcher, :maybe_dispatch}
      )

      on_exit(fn ->
        if previous_dispatcher do
          Application.put_env(
            :platform,
            :responsibility_router_native_dispatcher,
            previous_dispatcher
          )
        else
          Application.delete_env(:platform, :responsibility_router_native_dispatcher)
        end
      end)

      :ok
    end

    test "run_summary/1 taking the router branch stamps router_dispatched_at" do
      _name = start_registry!()
      ensure_role_responsibility!("meeting_scribe", "meetings.summarize")
      agent = create_native_agent!()
      {:ok, _} = Platform.Roles.assign_role("meeting_scribe", agent.id)

      transcript = create_transcript!(%{segments: sample_segments()})

      # Anti-vacuity: NULL before, so the assertion below is about this
      # call and not about the fixture.
      assert is_nil(Platform.Repo.reload!(transcript).router_dispatched_at)

      capture_log(fn -> assert :ok = Summarizer.run_summary(transcript) end)

      refute is_nil(Platform.Repo.reload!(transcript).router_dispatched_at),
             "the router branch handed the summary off without stamping " <>
               "router_dispatched_at — `list_stalled_router_dispatches/1` requires the " <>
               "column to be NOT NULL, so a stall on this dispatch is invisible forever"
    end

    test "the sweeper picks up such a row once the stall window passes" do
      _name = start_registry!()
      ensure_role_responsibility!("meeting_scribe", "meetings.summarize")
      agent = create_native_agent!()
      {:ok, _} = Platform.Roles.assign_role("meeting_scribe", agent.id)

      transcript = create_transcript!(%{segments: sample_segments(), status: "processing"})

      capture_log(fn -> assert :ok = Summarizer.run_summary(transcript) end)

      # Nothing has stalled yet — a generous window sees no candidates.
      # This control is what makes the assertion below about the STALL
      # and not merely about the row existing.
      refute transcript.id in Enum.map(Meetings.list_stalled_router_dispatches(60_000), & &1.id)

      # A zero-length window means "anything dispatched before now".
      assert transcript.id in Enum.map(Meetings.list_stalled_router_dispatches(0), & &1.id)
    end
  end

  describe "an empty row cannot make a claim about the whole room" do
    # The load-bearing fixture: a populated row, and an EMPTY row
    # inserted MOST RECENTLY. Per-row emptiness is true of the newest
    # row and says nothing about the room.
    defp shadowed_room! do
      room_id = "space-#{Ecto.UUID.generate()}"

      populated =
        create_transcript!(%{
          room_id: room_id,
          segments: sample_segments(),
          status: "complete"
        })

      empty = create_transcript!(%{room_id: room_id, segments: [], status: "processing"})

      {room_id, populated, empty}
    end

    test "summarize_async/1 REFUSES to call an empty row silent when the room holds content" do
      {_room_id, populated, empty} = shadowed_room!()

      assert empty.segments == [], "fixture defect: the newest row must be the empty one"
      assert populated.segments != []

      {result, log} =
        with_log(fn -> Summarizer.summarize_async(empty) end)

      # The refusal leaves the row alone — it does NOT invent a summary
      # and does NOT mark the row failed. Assert the ROW first, and make
      # the failure message name both halves of the contradiction: the
      # prose that got emitted, and the row that contradicts it.
      reloaded = Meetings.get_transcript(empty.id)

      assert is_nil(reloaded.summary),
             "empty transcript #{empty.id} was summarised as #{inspect(reloaded.summary)}, " <>
               "which is a claim about room #{empty.room_id} as a whole — contradicted by " <>
               "populated transcript #{populated.id}, which holds " <>
               "#{length(populated.segments)} segments in that same room. A negative claim " <>
               "about a room is only true if it holds for every row in that room."

      assert reloaded.status == "processing"
      assert {:error, :room_has_populated_transcript} = result

      assert log =~ "REFUSING"
      assert log =~ populated.id
    end

    test "a genuinely silent room still gets the empty summary (the guard is not a blanket refusal)" do
      # Control for the test above: same code path, room with NO
      # content anywhere. Without this, deleting the whole empty-summary
      # branch would still pass the refusal test.
      empty =
        create_transcript!(%{
          room_id: "space-#{Ecto.UUID.generate()}",
          segments: [],
          status: "processing"
        })

      capture_log(fn -> assert {:ok, :empty} = Summarizer.summarize_async(empty) end)

      reloaded = Meetings.get_transcript(empty.id)
      assert reloaded.status == "complete"
      assert reloaded.summary == "This meeting had no transcribed content."
    end
  end

  # ── task 01a0826f stage 4 — the summariser call path against a SLOW provider ──
  #
  # The production failure (2026-09-02 SXI workshop) was not in the adapter in
  # isolation: `Summarizer.run_summary/1` -> `call_llm/3` (summarizer.ex:321)
  # -> `provider_adapter(:ollama)` (summarizer.ex:590) -> `adapter.chat/3`
  # (summarizer.ex:569) returned `{:error, %Req.TransportError{reason:
  # :timeout}}` after Req's 15s default, and the `{:error, reason}` branch at
  # summarizer.ex:343-346 wrote the row `failed` with `{:llm_failed, _}`.
  #
  # So the fixture has to be SLOW. A short transcript answered instantly
  # passes on unmodified `main` and proves nothing — that is precisely how the
  # bug reached production.
  describe "end-to-end summarisation against a provider slower than Req's default" do
    @tag :slow
    @tag timeout: 180_000
    test "a completion returned after 16s still lands the transcript complete with a summary" do
      {:ok, _} = Application.ensure_all_started(:req)

      base_url = start_slow_ollama!(16_000)

      previous_summary_cfg = Application.get_env(:platform, :meetings_summary)

      Application.put_env(:platform, :meetings_summary, %{
        provider: :ollama,
        model: "concierge",
        max_tokens: 2048,
        base_url: base_url
      })

      on_exit(fn ->
        if previous_summary_cfg do
          Application.put_env(:platform, :meetings_summary, previous_summary_cfg)
        else
          Application.delete_env(:platform, :meetings_summary)
        end
      end)

      # Config.summary/0 honours the injected map (config.ex:50-60); assert it
      # rather than trusting it, so a config regression fails HERE and not as a
      # mystery `:no_summary_provider_configured` twenty seconds later.
      cfg = Platform.Meetings.Config.summary()
      assert cfg.provider == :ollama
      assert cfg.base_url == base_url

      {:ok, space} = Platform.Chat.create_space(%{kind: "execution"})

      transcript =
        create_transcript!(%{space_id: space.id, segments: sample_segments()})

      capture_log(fn ->
        assert :ok = Summarizer.run_summary(transcript),
               "the summariser gave up on a provider that answers in 16s"
      end)

      reloaded = Meetings.get_transcript(transcript.id)

      assert reloaded.status == "complete",
             "expected status=complete, got #{inspect(reloaded.status)} " <>
               "failure_reason=#{inspect(reloaded.failure_reason)} — a " <>
               "%Req.TransportError{reason: :timeout} here is the 2026-09-02 regression"

      refute is_nil(reloaded.summary)
      assert reloaded.summary =~ "Q3 roadmap"
    end
  end

  # Starts a real Bandit server on a free loopback port that sleeps `sleep_ms`
  # before answering with a valid Ollama completion, and returns its base URL.
  defp start_slow_ollama!(sleep_ms) do
    port = free_port()

    start_supervised!(
      {Bandit,
       plug: {Platform.Meetings.SummarizerTest.SlowOllamaPlug, sleep_ms: sleep_ms},
       scheme: :http,
       ip: {127, 0, 0, 1},
       port: port,
       startup_log: false}
    )

    "http://127.0.0.1:#{port}"
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
