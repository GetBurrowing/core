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
end
