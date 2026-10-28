defmodule Platform.Review.MeetingSummarizeE2EReviewTest do
  @moduledoc """
  Task 019f2570 stage 3 review — behavioural evidence for the four
  `e2e_behavior` validations on the task-level review host.

  Fast integration tests exercising the router-fired dispatch pipeline
  end-to-end (BEAM-in-process, HTTP stubbed via `Req.Test`). Each test
  maps 1:1 to a validation on the plan.

    * case 1 — broadcast → router → provider gather_context + build_prompt
      → dispatcher POSTs body carrying real transcript segments AND
      `max_tokens: 2500` (not the slug literal, not the concierge's
      implicit ~800).

    * case 2 — per-responsibility metadata['max_tokens'] override wins
      over the dispatcher's module default; both dispatches carry real
      transcript content.

    * case 3 — with the Meeting Scribe role UN-assigned,
      `Summarizer.run_summary_legacy` takes the legacy branch and the
      unchanged `Config.summary().max_tokens == 2048` rides through to
      the adapter (proved by inspection here + full behaviour in
      `Platform.Meetings.SummarizerTest`).

    * case 4 — empty-segments broadcast: the provider's `build_prompt/1`
      short-circuits with `{:error, :no_transcript_text}`, the router
      refuses the dispatch (no HTTP call), and the transcript is left in
      a non-processing state — no crash, no retry, no stuck-in-processing
      regression of the 2026-07-02 bug.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.ExternalAgents.EphemeralCredentials
  alias Platform.Meetings
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.BuiltIns
  alias Platform.Responsibilities.Handlers.MeetingSummarize
  alias Platform.Responsibilities.Registry
  alias Platform.Responsibilities.Router, as: ResponsibilityRouter
  alias Platform.Roles

  # ── setup ────────────────────────────────────────────────────────────────

  setup do
    Logger.put_module_level(Platform.Responsibilities.Router, :info)

    {:ok, _} = Application.ensure_all_started(:req)

    Application.put_env(
      :platform,
      :external_agents_dispatcher_req_client,
      Req.new(plug: {Req.Test, :review_meeting_summarize_dispatch_stub})
    )

    on_exit(fn ->
      Application.delete_env(:platform, :external_agents_dispatcher_req_client)
      Logger.delete_module_level(Platform.Responsibilities.Router)
    end)

    :ok
  end

  # Seed the built-in meetings.summarize row (register/0 defaults —
  # metadata carries max_tokens: 2500 already after stage 2).
  defp seed_meetings_summarize! do
    [attrs] = MeetingSummarize.register()
    {:ok, row} = Responsibilities.upsert_by_key(attrs)
    row
  end

  defp seed_meeting_scribe_agent! do
    role_key = "meeting_scribe"

    Repo.insert!(
      %Platform.Roles.Role{
        key: role_key,
        name: "Meeting Scribe",
        description: "review seed",
        icon: "hero-star"
      },
      on_conflict: :nothing,
      conflict_target: :key
    )

    Repo.insert!(
      %Platform.Roles.RoleResponsibility{
        role_key: role_key,
        responsibility_key: "meetings.summarize"
      },
      on_conflict: :nothing,
      conflict_target: [:role_key, :responsibility_key]
    )

    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "review-hermione-#{System.unique_integer([:positive])}",
        name: "Review Hermione",
        status: "active",
        kind: "external",
        endpoint_kind: "openai_compat",
        base_url: "https://api.example.test",
        model: "test-model",
        workspace_id: nil
      })
      |> Repo.insert!()

    :ok = EphemeralCredentials.put(agent.id, "sk-review-test")
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
          room_id: "review-room-#{System.unique_integer([:positive])}",
          space_id: nil,
          segments: []
        },
        overrides
      )

    {:ok, transcript} = Meetings.create_transcript(attrs)
    transcript
  end

  # Rich sample segments — >2000 chars total, 4 distinct speakers.
  defp long_dialogue_segments do
    [
      %{
        "speaker_name" => "Blake",
        "text" =>
          "Let's kick off the roadmap review for Q3. We need to lock the mobile focus this week " <>
            "so the design partners have a stable target. I'd like to walk through the pilot " <>
            "cohort's telemetry and then decide on the shutdown criteria for the legacy CLI.",
        "start_time" => 0,
        "end_time" => 14_000,
        "final" => true
      },
      %{
        "speaker_name" => "Alex",
        "text" =>
          "On mobile — I think we should pick iOS-first and commit. The Android team is already " <>
            "over-allocated on the compliance work. If we split now we'll ship neither by " <>
            "September. I'll write up the tradeoff doc by Wednesday and pull Amir in.",
        "start_time" => 14_500,
        "end_time" => 28_000,
        "final" => true
      },
      %{
        "speaker_name" => "Priya",
        "text" =>
          "Agreed. Also — the pilot cohort saw a 30% drop in day-two retention when we shipped " <>
            "the new onboarding. I want us to revert the flow before the mobile launch. That's " <>
            "an action item for me by Friday.",
        "start_time" => 28_500,
        "end_time" => 43_000,
        "final" => true
      },
      %{
        "speaker_name" => "Sam",
        "text" =>
          "Last thing — legacy CLI. Support tickets are down 80% since the deprecation notice " <>
            "went out. I want to fully retire the binary at the end of Q3 and remove the docs " <>
            "the same week. Any objections? Great, marking that as a decision.",
        "start_time" => 43_500,
        "end_time" => 60_000,
        "final" => true
      }
    ]
  end

  defp start_router_supervised! do
    name = Module.concat([ResponsibilityRouter, "Review#{System.unique_integer([:positive])}"])

    pid =
      start_supervised!(
        {ResponsibilityRouter,
         name: name, providers: BuiltIns.providers(), check_interval_ms: 60_000}
      )

    # DataCase sandbox owns the Repo connection on the test pid; allow
    # the Router process to share it so lookups + subscribes work.
    :ok = Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    {pid, name}
  end

  defp start_registry! do
    name = Module.concat([Registry, "Review#{System.unique_integer([:positive])}"])
    _pid = start_supervised!({Registry, name: name, providers: BuiltIns.providers()})
    name
  end

  # Stub that captures the outbound POST body and replies with a
  # canned OpenAI-compat completion.
  defp stub_dispatcher_ok(canned_content) do
    test_pid = self()

    Req.Test.stub(:review_meeting_summarize_dispatch_stub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:dispatch_body, body})

      Req.Test.json(conn, %{
        "choices" => [
          %{"message" => %{"role" => "assistant", "content" => canned_content}}
        ]
      })
    end)
  end

  # ── case 1 — broadcast → router → real transcript + max_tokens: 2500 ─────

  describe "case 1 — broadcast_meeting_finished → dispatch happy path" do
    test "POST body carries real transcript text (not the slug) AND max_tokens: 2500" do
      _ = seed_meetings_summarize!()
      _agent = seed_meeting_scribe_agent!()
      _registry = start_registry!()

      space = create_space!()

      transcript =
        create_transcript!(%{
          space_id: space.id,
          segments: long_dialogue_segments()
        })

      canned_summary =
        String.duplicate(
          "## Overview\nThe team locked the mobile roadmap and picked iOS-first. Retention " <>
            "regression flagged; Priya reverting onboarding. Legacy CLI retired end of Q3.\n",
          6
        )

      stub_dispatcher_ok(canned_summary)

      # Fire the router path synchronously — mirrors the code path
      # `Summarizer.run_summary/1` takes when
      # `responsibility_filled?("meetings.summarize")` is true. This
      # is the same seam `LivekitWebhookController.summarize_async/1`
      # eventually walks after the pubsub round-trip; skipping the
      # pubsub tick keeps the test synchronous without changing
      # semantics.
      capture_log(fn ->
        assert {:ok, :dispatched} =
                 ResponsibilityRouter.fire(:meetings_summarize, %{
                   kind: :event_topic,
                   topic: "meeting:finished",
                   payload: %{transcript_id: transcript.id, space_id: space.id}
                 })
      end)

      assert_receive {:dispatch_body, raw_body}, 5_000
      decoded = Jason.decode!(raw_body)

      # Shape:
      messages = decoded["messages"]
      assert is_list(messages)
      assert length(messages) == 2
      [system_msg, user_msg] = messages
      assert system_msg["role"] == "system"
      assert user_msg["role"] == "user"

      # Real transcript text:
      assert user_msg["content"] =~ "Please summarize the following meeting transcript:"
      assert user_msg["content"] =~ "Blake"
      assert user_msg["content"] =~ "roadmap review for Q3"
      assert user_msg["content"] =~ "Priya"
      refute user_msg["content"] =~ "meetings.summarize.v1"

      # max_tokens: 2500 rides through (per-responsibility hint):
      assert decoded["max_tokens"] == 2500

      # Downstream persistence: handle_output fired and marked complete.
      reloaded = Meetings.get_transcript(transcript.id)
      assert reloaded.status == "complete"
      assert Platform.Meetings.Transcript.summary_current?(reloaded)
      assert String.length(reloaded.summary) > 100
      assert reloaded.summary =~ "Overview"
    end
  end

  # ── case 2 — per-responsibility metadata override wins ───────────────────

  describe "case 2 — metadata['max_tokens'] override" do
    test "default 2500 (from register/0) then Repo.update!-bumped 800 both ride through" do
      row = seed_meetings_summarize!()
      _agent = seed_meeting_scribe_agent!()
      _registry = start_registry!()

      # Sanity — register/0 declared 2500.
      assert row.metadata["max_tokens"] == 2500

      space = create_space!()

      transcript_a =
        create_transcript!(%{
          space_id: space.id,
          segments: long_dialogue_segments()
        })

      canned = "## Overview\nCanned summary A.\n## Action Items\n- ok"

      stub_dispatcher_ok(canned)

      capture_log(fn ->
        assert {:ok, :dispatched} =
                 ResponsibilityRouter.fire(:meetings_summarize, %{
                   kind: :event_topic,
                   topic: "meeting:finished",
                   payload: %{transcript_id: transcript_a.id, space_id: space.id}
                 })
      end)

      assert_receive {:dispatch_body, raw_body_a}, 5_000
      decoded_a = Jason.decode!(raw_body_a)
      assert decoded_a["max_tokens"] == 2500

      # Real transcript content still present (case 1 invariant holds).
      user_a = Enum.find(decoded_a["messages"], &(&1["role"] == "user"))
      assert user_a["content"] =~ "roadmap review for Q3"

      # Now flip the metadata override in place.
      {:ok, _row} =
        Responsibilities.update_responsibility(row, %{
          metadata: Map.put(row.metadata, "max_tokens", 800)
        })

      transcript_b =
        create_transcript!(%{
          space_id: space.id,
          segments: long_dialogue_segments()
        })

      stub_dispatcher_ok(canned)

      capture_log(fn ->
        assert {:ok, :dispatched} =
                 ResponsibilityRouter.fire(:meetings_summarize, %{
                   kind: :event_topic,
                   topic: "meeting:finished",
                   payload: %{transcript_id: transcript_b.id, space_id: space.id}
                 })
      end)

      assert_receive {:dispatch_body, raw_body_b}, 5_000
      decoded_b = Jason.decode!(raw_body_b)
      assert decoded_b["max_tokens"] == 800

      user_b = Enum.find(decoded_b["messages"], &(&1["role"] == "user"))
      assert user_b["content"] =~ "roadmap review for Q3"
    end
  end

  # ── case 3 — legacy path unchanged when Meeting Scribe unfilled ──────────

  describe "case 3 — Meeting Scribe UN-assigned → legacy path stays at 2048" do
    test "Config.summary().max_tokens is 2048 and legacy branch handles the transcript" do
      # Do NOT seed the Meeting Scribe role → responsibility_filled? = false.
      _ = seed_meetings_summarize!()
      _registry = start_registry!()

      # Belt + braces — confirm the gate is off.
      refute ResponsibilityRouter.responsibility_filled?("meetings.summarize")

      # `Config.summary()` is the single source of truth for legacy
      # max_tokens. The stage 2 changes MUST NOT bleed here.
      assert Platform.Meetings.Config.summary().max_tokens == 2048

      transcript =
        create_transcript!(%{
          space_id: nil,
          segments: long_dialogue_segments()
        })

      # `Platform.Meetings.Config.summary/0` reads priv/meetings.yml;
      # in test env the file doesn't exist so the resolved provider is
      # `:none` by default. The legacy body's `call_llm/3` short-circuits
      # to `{:error, :no_summary_provider_configured}` — the cheapest
      # proof we're on the legacy branch and NOT the router path (the
      # router would have returned :ok via the stubbed HTTP dispatch).
      log =
        capture_log(fn ->
          assert {:error, {:llm_failed, :no_summary_provider_configured}} =
                   Platform.Meetings.Summarizer.run_summary(transcript)
        end)

      # Legacy body always emits this — proves the branch selection.
      assert log =~ "[Summarizer] LLM call failed for transcript"

      # Legacy path also marks the transcript failed on LLM error.
      assert Meetings.get_transcript(transcript.id).status == "failed"

      # And the stub was NEVER called (no external HTTP round-trip).
      refute_received {:dispatch_body, _}
    end
  end

  # ── case 4 — empty-segments broadcast is observably safe ─────────────────

  describe "case 4 — empty-segments broadcast" do
    test "no HTTP call, no crash, no retry, no stuck-in-processing" do
      _ = seed_meetings_summarize!()
      _agent = seed_meeting_scribe_agent!()
      {_pid, _name} = start_router_supervised!()

      space = create_space!()

      transcript =
        create_transcript!(%{
          space_id: space.id,
          # THE case 4 setup — empty segments.
          segments: []
        })

      initial_status = Meetings.get_transcript(transcript.id).status

      # Stub the HTTP surface with a canary — any hit fails the case.
      test_pid = self()

      Req.Test.stub(:review_meeting_summarize_dispatch_stub, fn conn ->
        send(test_pid, :unexpected_http_call)
        Req.Test.json(conn, %{"choices" => []})
      end)

      # Attach telemetry so we can prove exactly-once-safe behaviour.
      handler_id = "review-case4-telemetry-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler_id,
        [
          [:platform, :external_agent, :called],
          [:platform, :responsibility, :fired],
          [:platform, :responsibility, :failed]
        ],
        fn event, _measurements, metadata, pid ->
          send(pid, {:review_telemetry, event, metadata})
        end,
        test_pid
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      log =
        capture_log(fn ->
          # Fire path 1: direct router.fire (deterministic, no pubsub race).
          assert {:error, {:build_prompt_refused, :no_transcript_text}} =
                   ResponsibilityRouter.fire(:meetings_summarize, %{
                     kind: :event_topic,
                     topic: "meeting:finished",
                     payload: %{
                       transcript_id: transcript.id,
                       room_id: transcript.room_id,
                       space_id: space.id
                     }
                   })

          # Fire path 2: the actual production PubSub broadcast the
          # `LivekitWebhookController` uses. The task-level Router
          # instance we started_supervised! is the subscriber.
          MeetingsPubSub.broadcast_meeting_finished(transcript.room_id, %{
            transcript_id: transcript.id,
            room_id: transcript.room_id,
            space_id: space.id
          })

          # Let the router info handler drain.
          Process.sleep(200)
        end)

      # Outcome (B) — provider short-circuits with :no_transcript_text.
      # The router logs "provider build_prompt refused dispatch" and
      # emits :responsibility.failed telemetry with reason build_prompt_refused.
      assert log =~ "build_prompt refused dispatch"
      assert log =~ "no_transcript_text"

      # No external HTTP call happened.
      refute_received :unexpected_http_call
      refute_received {:review_telemetry, [:platform, :external_agent, :called], _}

      # :responsibility.failed telemetry fired (at least once, once per
      # fire path) with build_prompt_refused reason — not stuck, not
      # crashed, not retried indefinitely.
      assert_receive {:review_telemetry, [:platform, :responsibility, :failed], meta}
      assert meta.key == "meetings.summarize"
      assert meta.reason =~ "build_prompt_refused"

      # Transcript is NOT stuck in "processing" — the 2026-07-02
      # regression this task fixes. It stays in its initial "recording"
      # state (safe non-processing terminal-adjacent state; the webhook
      # flow's `summarize_async/1` empty-transcript path is the
      # canonical cleanup and is unchanged by this task).
      reloaded = Meetings.get_transcript(transcript.id)
      assert reloaded.status == initial_status
      assert reloaded.status != "processing"
      refute reloaded.status == "failed"
    end
  end
end
