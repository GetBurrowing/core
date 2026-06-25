defmodule Platform.Meetings.SummarizerTest do
  @moduledoc false
  # M8 stage 4 added bridge tests that toggle global resources (Role
  # seeds, per-case Registry, telemetry handlers, Config app env), so
  # this case must run synchronously to keep the toggles from leaking
  # across processes.
  use Platform.DataCase, async: false

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

      # `:fired` is the happy path (native dispatch + noop dispatcher);
      # `:failed` is acceptable if the native dispatch raises for any
      # reason; `:unfilled` would be a bug (we just asserted the gate
      # is filled).
      assert ev in [:fired, :failed]

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
end
