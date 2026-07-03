defmodule Platform.Meetings.IntentClassifierTest do
  @moduledoc """
  Tests for `Platform.Meetings.IntentClassifier` — the transcript-chunk
  subscriber that drives the Meeting Producer classifier pipeline
  (task 019f2452 stages 3–4).

  Stage 3 shipped the module SHELL: subscription, feature-flag gate,
  assignee-lookup gate, spam-suppressor MapSet.

  Stage 4 shipped the full pipeline in `classify_and_enqueue/3`:
  prompt render + LLM call + JSON parse + dedupe + `IntentQueue.enqueue/3`
  + terminal telemetry. Coverage below extends the stage-3 guard
  assertions with the pipeline's happy-path, idempotent-replay,
  template-fallback, model-error, and parse-error branches. The
  provider is stubbed via the `provider_module` opt on `start_link/1`
  so tests can pipe any response through without hitting a real Ollama.
  """

  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Agents.Agent
  alias Platform.Meetings.IntentClassifier
  alias Platform.Meetings.IntentQueue
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo
  alias Platform.Roles

  @responsibility_key "meetings.intent_classify"
  @prompt_slug "meetings.intent_classify.v1"

  # config/test.exs pins the Logger to :warning; bump this module to
  # :info so `capture_log/2` actually sees the boot + no-assignee lines
  # we assert on. Mirrors `Platform.Responsibilities.RouterTest`.
  setup do
    Logger.put_module_level(Platform.Meetings.IntentClassifier, :info)
    on_exit(fn -> Logger.delete_module_level(Platform.Meetings.IntentClassifier) end)
    :ok
  end

  # ── Provider stub ─────────────────────────────────────────────────────────

  defmodule StubProvider do
    @moduledoc """
    Provider stub — the classifier passes it in via `provider_module`.
    Tests drop a `fun` into an agent-based Process dictionary key so
    concurrent instances stay isolated, then this module reads the
    matching fun and calls it. Returns whatever the test set up.
    """

    def chat(credentials, messages, opts) do
      case Process.get(:intent_classifier_stub_fun) do
        nil -> {:error, :no_stub_configured}
        fun when is_function(fun, 3) -> fun.(credentials, messages, opts)
      end
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp start_classifier!(opts \\ []) do
    # ExUnit test names include the describe title, which for this suite
    # holds an em-dash and other Unicode — `binary_to_atom(_, :utf8)`
    # chokes on the byte-level slice. Use a unique-integer suffix so the
    # process name stays ASCII and collision-free across runs.
    name = :"intent_classifier_#{System.unique_integer([:positive])}"

    child_opts =
      opts
      |> Keyword.put_new(:provider_module, StubProvider)
      |> Keyword.put(:name, name)

    {:ok, pid} = start_supervised({IntentClassifier, child_opts})

    # The `StubProvider` module (see above) reads the stub fun out of
    # the process dictionary of whatever process it's called from —
    # which, for the classifier, IS the classifier's own process. The
    # `plant_stub_fun/2` helper below sends a `:__test_plant_stub`
    # message that the classifier handles by storing the fun in its
    # dict; that's the whole seam.
    {pid, name}
  end

  # Plant the stub fun in the CLASSIFIER's process dictionary — the stub
  # runs inside the classifier's handle_info loop, not the test process.
  defp plant_stub_fun(pid, fun) do
    ref = make_ref()
    send(pid, {:__test_plant_stub, self(), ref, fun})

    receive do
      {^ref, :ok} -> :ok
    after
      500 -> flunk("classifier did not ack stub fun plant")
    end
  end

  defp create_agent!(overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          slug: "intent-agent-#{System.unique_integer([:positive])}",
          name: "Intent Agent",
          status: "active"
        },
        overrides
      )

    %Agent{}
    |> Agent.changeset(attrs)
    |> Repo.insert!()
  end

  defp assign_intent_role!(agent) do
    # Task 019f2452: no "producer" role in the closed roster yet — use
    # the leaf-level responsibility override so `assignee_for/1`
    # resolves to this agent independent of role bundle wiring.
    {:ok, _} = Roles.set_override(@responsibility_key, agent.id)
    :ok
  end

  defp attach_recorder!(event_suffix, tag) do
    handler_id = "intent-classifier-test-#{tag}-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:platform, :meetings, :intent_classifier, event_suffix],
      fn _event, measurements, metadata, pid ->
        send(pid, {tag, measurements, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    handler_id
  end

  # The terminal `intent_classified` telemetry lives at a different
  # namespace (no `:intent_classifier` suffix); recorder helper mirrors
  # `attach_recorder!/2` for that event.
  defp attach_terminal_recorder!(tag) do
    handler_id = "intent-classified-test-#{tag}-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:platform, :meetings, :intent_classified],
      fn _event, measurements, metadata, pid ->
        send(pid, {tag, measurements, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    handler_id
  end

  defp broadcast_chunk(room_id, overrides \\ %{}) do
    overrides_map = if is_map(overrides), do: overrides, else: Enum.into(overrides, %{})

    payload =
      Map.merge(
        %{
          room_id: room_id,
          transcript_id: "transcript-#{System.unique_integer([:positive])}",
          segment: %{
            id: "seg-#{System.unique_integer([:positive])}",
            text: "we need to schedule a follow-up on the billing bug",
            speaker_name: "alice"
          },
          meeting_id: nil
        },
        overrides_map
      )

    :ok = MeetingsPubSub.broadcast_transcript_chunk(room_id, payload)
    payload
  end

  defp set_runtime_flag(value) do
    prior = Application.get_env(:platform, :meeting_producer_runtime_enabled, false)
    Application.put_env(:platform, :meeting_producer_runtime_enabled, value)
    on_exit(fn -> Application.put_env(:platform, :meeting_producer_runtime_enabled, prior) end)
    :ok
  end

  # ── Tests ──────────────────────────────────────────────────────────────────

  describe "init/1" do
    test "subscribes to the canonical transcript_chunk topic and logs on boot" do
      log =
        capture_log([level: :info], fn ->
          {_pid, _name} = start_classifier!()
          # Give init a beat to emit the log line.
          Process.sleep(20)
        end)

      assert log =~ "[IntentClassifier] started"
      assert log =~ "meeting:transcript_chunk"
    end
  end

  describe "handle_info/2 — flag off" do
    test "drops the chunk without calling Roles.assignee_for and emits :flag_off telemetry" do
      set_runtime_flag(false)
      _ = attach_recorder!(:skipped, :skipped)
      {_pid, _name} = start_classifier!()

      # Even with an assignee present, flag_off short-circuits before
      # the Roles lookup runs.
      agent = create_agent!()
      assign_intent_role!(agent)

      _payload = broadcast_chunk("room-flag-off")

      assert_receive {:skipped, %{count: 1}, %{reason: :flag_off, room_id: "room-flag-off"}}, 500
    end
  end

  describe "handle_info/2 — no assignee" do
    setup do
      set_runtime_flag(true)
      :ok
    end

    test "logs at :info the first time a room appears with no assignee" do
      _ = attach_recorder!(:skipped, :skipped)
      {_pid, _name} = start_classifier!()

      log =
        capture_log([level: :info], fn ->
          _ = broadcast_chunk("room-no-assignee-first")

          assert_receive {:skipped, %{count: 1},
                          %{reason: :no_assignee, room_id: "room-no-assignee-first"}},
                         500
        end)

      assert log =~ "[IntentClassifier] no assignee for meetings.intent_classify"
      assert log =~ "room=room-no-assignee-first"
    end

    test "second chunk from the same room does NOT re-log at :info" do
      _ = attach_recorder!(:skipped, :skipped)
      {_pid, _name} = start_classifier!()

      # Prime seen_rooms with the first chunk (may log; we don't care here).
      _ =
        capture_log(fn ->
          _ = broadcast_chunk("room-no-assignee-repeat")
          assert_receive {:skipped, _measurements, %{reason: :no_assignee}}, 500
        end)

      # Second chunk for the same room: telemetry still fires but no
      # info-level log line is emitted.
      log =
        capture_log([level: :info], fn ->
          _ = broadcast_chunk("room-no-assignee-repeat")

          assert_receive {:skipped, _measurements,
                          %{reason: :no_assignee, room_id: "room-no-assignee-repeat"}},
                         500
        end)

      refute log =~ "[IntentClassifier] no assignee"
    end

    test "does not crash the classifier when the responsibility has no assignee" do
      {pid, _name} = start_classifier!()

      _ = broadcast_chunk("room-liveness-check")
      Process.sleep(50)

      assert Process.alive?(pid)
    end
  end

  describe "classify_and_enqueue — happy path" do
    setup do
      set_runtime_flag(true)
      agent = create_agent!(%{slug: "intent-agent-happy"})
      assign_intent_role!(agent)
      IntentQueue.drop_for_room("room-happy")
      %{agent: agent}
    end

    test "parses the JSON response, writes to IntentQueue, fires intent_classified telemetry",
         %{agent: agent} do
      _ = attach_terminal_recorder!(:classified)
      {pid, _name} = start_classifier!()

      plant_stub_fun(pid, fn _creds, _messages, _opts ->
        {:ok,
         %{
           content:
             Jason.encode!(%{
               "intent" => "schedule_follow_up",
               "target_role" => "scribe",
               "confidence" => 0.87
             })
         }}
      end)

      _ = broadcast_chunk("room-happy", meeting_id: "meeting-happy")

      assert_receive {:classified, %{count: 1},
                      %{
                        room_id: "room-happy",
                        intent: "schedule_follow_up",
                        target_role: "scribe",
                        confidence: 0.87,
                        dedupe_key_hit_or_new: :inserted,
                        meeting_id: "meeting-happy"
                      }},
                     500

      # And the row landed in the queue.
      entries = IntentQueue.list_for_room("room-happy")
      assert length(entries) == 1
      [entry] = entries
      assert entry.intent == "schedule_follow_up"
      assert entry.target_role == "scribe"
      assert entry.confidence == 0.87
      assert entry.meeting_id == "meeting-happy"

      # Silence the "unused" compiler warning for the injected agent.
      assert agent.slug == "intent-agent-happy"
    end
  end

  describe "classify_and_enqueue — idempotent replay" do
    setup do
      set_runtime_flag(true)
      agent = create_agent!(%{slug: "intent-agent-idempotent"})
      assign_intent_role!(agent)
      IntentQueue.drop_for_room("room-idempotent")
      %{agent: agent}
    end

    test "same chunk twice produces :inserted then :duplicate; queue has one entry" do
      _ = attach_terminal_recorder!(:classified)
      {pid, _name} = start_classifier!()

      plant_stub_fun(pid, fn _c, _m, _o ->
        {:ok,
         %{
           content:
             Jason.encode!(%{
               "intent" => "assign_owner",
               "target_role" => "scribe",
               "confidence" => 0.9
             })
         }}
      end)

      # Broadcast the SAME payload twice — segment text is identical,
      # so the sha256(intent <> target_role <> chunk_text) dedupe key
      # collides.
      payload = %{
        room_id: "room-idempotent",
        transcript_id: "transcript-idem",
        segment: %{id: "seg-idem", text: "please own this bug", speaker_name: "bob"},
        meeting_id: nil
      }

      :ok = MeetingsPubSub.broadcast_transcript_chunk("room-idempotent", payload)
      assert_receive {:classified, _m, %{dedupe_key_hit_or_new: :inserted}}, 500

      :ok = MeetingsPubSub.broadcast_transcript_chunk("room-idempotent", payload)
      assert_receive {:classified, _m, %{dedupe_key_hit_or_new: :duplicate}}, 500

      assert IntentQueue.list_for_room("room-idempotent") |> length() == 1
    end
  end

  describe "classify_and_enqueue — template fallback" do
    setup do
      set_runtime_flag(true)
      agent = create_agent!(%{slug: "intent-agent-fallback"})
      assign_intent_role!(agent)
      IntentQueue.drop_for_room("room-fallback")

      # Nuke any pre-seeded row for the slug so `render_template/2`
      # definitely returns {:error, :not_found}.
      case PromptTemplates.get_template_by_slug(@prompt_slug) do
        nil -> :ok
        template -> PromptTemplates.delete_template(template)
      end

      %{agent: agent}
    end

    test "logs the warning, emits template_fallback telemetry, entry still lands" do
      _ = attach_recorder!(:template_fallback, :fallback)
      _ = attach_terminal_recorder!(:classified)
      {pid, _name} = start_classifier!()

      plant_stub_fun(pid, fn _c, _m, _o ->
        {:ok,
         %{
           content:
             Jason.encode!(%{
               "intent" => "capture_action",
               "target_role" => "scribe",
               "confidence" => 0.6
             })
         }}
      end)

      log =
        capture_log([level: :warning], fn ->
          _ = broadcast_chunk("room-fallback")

          assert_receive {:fallback, %{count: 1},
                          %{room_id: "room-fallback", slug: @prompt_slug}},
                         500

          assert_receive {:classified, _m, %{dedupe_key_hit_or_new: :inserted}}, 500
        end)

      assert log =~ "prompt template #{@prompt_slug} missing"
      assert IntentQueue.list_for_room("room-fallback") |> length() == 1
    end
  end

  describe "classify_and_enqueue — model error" do
    setup do
      set_runtime_flag(true)
      agent = create_agent!(%{slug: "intent-agent-model-error"})
      assign_intent_role!(agent)
      IntentQueue.drop_for_room("room-model-error")
      %{agent: agent}
    end

    test "logs :warning, emits model_error telemetry, no queue entry, subsequent chunk works" do
      _ = attach_recorder!(:model_error, :model_error)
      _ = attach_terminal_recorder!(:classified)
      {pid, _name} = start_classifier!()

      # First stub: HTTP 500 shape from the provider (mirrors
      # `Platform.Agents.Providers.Ollama.chat/3` failure shape).
      plant_stub_fun(pid, fn _c, _m, _o ->
        {:error, {:http_error, 500, %{"error" => "boom"}}}
      end)

      log =
        capture_log([level: :warning], fn ->
          _ = broadcast_chunk("room-model-error")

          assert_receive {:model_error, %{count: 1}, %{room_id: "room-model-error"}}, 500
        end)

      assert log =~ "LLM call failed"
      assert log =~ "room-model-error"
      assert IntentQueue.list_for_room("room-model-error") == []
      assert Process.alive?(pid), "classifier crashed on model error"

      # Second stub: now the provider returns cleanly. The classifier
      # should process this new chunk without any state corruption from
      # the earlier failure.
      plant_stub_fun(pid, fn _c, _m, _o ->
        {:ok,
         %{
           content:
             Jason.encode!(%{
               "intent" => "recovered",
               "target_role" => "scribe",
               "confidence" => 0.5
             })
         }}
      end)

      _ = broadcast_chunk("room-model-error", segment: %{id: "seg-2", text: "post-recovery"})

      assert_receive {:classified, _m, %{room_id: "room-model-error", intent: "recovered"}},
                     500

      assert IntentQueue.list_for_room("room-model-error") |> length() == 1
    end

    test "provider raising is trapped and reported as model_error" do
      _ = attach_recorder!(:model_error, :model_error)
      {pid, _name} = start_classifier!()
      plant_stub_fun(pid, fn _c, _m, _o -> raise "boom from stub" end)

      capture_log([level: :warning], fn ->
        _ = broadcast_chunk("room-model-error-raise")
        assert_receive {:model_error, %{count: 1}, %{room_id: "room-model-error-raise"}}, 500
      end)

      assert Process.alive?(pid)
    end
  end

  describe "classify_and_enqueue — parse error" do
    setup do
      set_runtime_flag(true)
      agent = create_agent!(%{slug: "intent-agent-parse-error"})
      assign_intent_role!(agent)
      IntentQueue.drop_for_room("room-parse-error")
      %{agent: agent}
    end

    test "emits parse_error telemetry on non-JSON content, no queue entry, no crash" do
      _ = attach_recorder!(:parse_error, :parse_error)
      {pid, _name} = start_classifier!()

      plant_stub_fun(pid, fn _c, _m, _o ->
        {:ok, %{content: "definitely not json {{{"}}
      end)

      capture_log([level: :warning], fn ->
        _ = broadcast_chunk("room-parse-error")
        assert_receive {:parse_error, %{count: 1}, %{room_id: "room-parse-error"}}, 500
      end)

      assert IntentQueue.list_for_room("room-parse-error") == []
      assert Process.alive?(pid)
    end

    test "emits parse_error when JSON decodes but required keys are missing" do
      _ = attach_recorder!(:parse_error, :parse_error)
      {pid, _name} = start_classifier!()

      plant_stub_fun(pid, fn _c, _m, _o ->
        {:ok, %{content: Jason.encode!(%{"intent" => "no_role_no_conf"})}}
      end)

      capture_log([level: :warning], fn ->
        _ = broadcast_chunk("room-parse-missing-keys")
        assert_receive {:parse_error, %{count: 1}, %{room_id: "room-parse-missing-keys"}}, 500
      end)

      assert IntentQueue.list_for_room("room-parse-missing-keys") == []
    end
  end

  describe "malformed events" do
    test "ignores unknown messages without crashing" do
      set_runtime_flag(false)
      {pid, _name} = start_classifier!()

      send(pid, :garbage)
      send(pid, {:unrelated_topic, %{}})
      Process.sleep(30)

      assert Process.alive?(pid)
    end
  end
end
