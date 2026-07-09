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

  describe "handle_info/2 — no assignee" do
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
      {pid, _name} = start_classifier!()

      send(pid, :garbage)
      send(pid, {:unrelated_topic, %{}})
      Process.sleep(30)

      assert Process.alive?(pid)
    end
  end

  describe "chunk buffer — sliding window" do
    test "prepends the current chunk into state.recent_chunks (head-first)" do
      {pid, _name} = start_classifier!(context_window_size: 3)

      _ =
        broadcast_chunk("room-buffer-1",
          segment: %{id: "seg-1", text: "first chunk", speaker_name: "alice"}
        )

      # Give the classifier's handle_info a beat to process.
      Process.sleep(30)

      state = :sys.get_state(pid)
      assert Map.has_key?(state.recent_chunks, "room-buffer-1")
      [head] = state.recent_chunks["room-buffer-1"]
      assert head.text == "first chunk"
      assert head.speaker == "alice"
    end

    test "keeps at most context_window_size + 1 entries per room (head = current)" do
      {pid, _name} = start_classifier!(context_window_size: 3)

      for i <- 1..5 do
        _ =
          broadcast_chunk("room-buffer-window",
            segment: %{id: "seg-#{i}", text: "chunk #{i}", speaker_name: "alice"}
          )
      end

      Process.sleep(50)

      state = :sys.get_state(pid)
      window = state.recent_chunks["room-buffer-window"]

      # window size 3 => head + prior 3 => 4 stored entries max.
      assert length(window) == 4

      # Most-recent-first: head is chunk 5, oldest kept is chunk 2.
      assert Enum.map(window, & &1.text) ==
               ["chunk 5", "chunk 4", "chunk 3", "chunk 2"]
    end

    test "buffers are per-room isolated — interleaved chunks stay separate" do
      {pid, _name} = start_classifier!(context_window_size: 3)

      _ =
        broadcast_chunk("room-A", segment: %{id: "a1", text: "A1", speaker_name: "alice"})

      _ =
        broadcast_chunk("room-B", segment: %{id: "b1", text: "B1", speaker_name: "bob"})

      _ =
        broadcast_chunk("room-A", segment: %{id: "a2", text: "A2", speaker_name: "alice"})

      Process.sleep(50)

      state = :sys.get_state(pid)
      assert Enum.map(state.recent_chunks["room-A"], & &1.text) == ["A2", "A1"]
      assert Enum.map(state.recent_chunks["room-B"], & &1.text) == ["B1"]
    end

    test "buffer stays populated even when there is no assignee (warms the window)" do
      _ = attach_recorder!(:skipped, :skipped)
      {pid, _name} = start_classifier!(context_window_size: 3)

      # No assign_intent_role! call — assignee lookup returns nil.
      _ =
        capture_log(fn ->
          _ =
            broadcast_chunk("room-no-assignee-warm",
              segment: %{id: "warm-1", text: "warm chunk", speaker_name: "carol"}
            )

          assert_receive {:skipped, %{count: 1}, %{reason: :no_assignee}}, 500
        end)

      state = :sys.get_state(pid)
      assert [entry] = state.recent_chunks["room-no-assignee-warm"]
      assert entry.text == "warm chunk"
      assert entry.speaker == "carol"
    end
  end

  describe "chunk buffer — cleanup on meeting_finished" do
    test "clears the per-room buffer when meeting_finished fires for that room" do
      {pid, _name} = start_classifier!(context_window_size: 3)

      _ = broadcast_chunk("room-cleanup", segment: %{id: "c1", text: "c1"})
      _ = broadcast_chunk("room-cleanup", segment: %{id: "c2", text: "c2"})
      Process.sleep(30)

      assert Map.has_key?(:sys.get_state(pid).recent_chunks, "room-cleanup")

      :ok =
        MeetingsPubSub.broadcast_meeting_finished("room-cleanup", %{
          room_id: "room-cleanup",
          transcript_id: "t-cleanup",
          space_id: "s-cleanup"
        })

      Process.sleep(30)

      refute Map.has_key?(:sys.get_state(pid).recent_chunks, "room-cleanup")
      assert Process.alive?(pid)
    end

    test "cleanup is scoped — a different room's buffer is untouched" do
      {pid, _name} = start_classifier!(context_window_size: 3)

      _ = broadcast_chunk("room-keep", segment: %{id: "k1", text: "k1"})
      _ = broadcast_chunk("room-drop", segment: %{id: "d1", text: "d1"})
      Process.sleep(30)

      :ok =
        MeetingsPubSub.broadcast_meeting_finished("room-drop", %{
          room_id: "room-drop",
          transcript_id: "t-drop",
          space_id: "s-drop"
        })

      Process.sleep(30)

      state = :sys.get_state(pid)
      refute Map.has_key?(state.recent_chunks, "room-drop")
      assert Enum.map(state.recent_chunks["room-keep"], & &1.text) == ["k1"]
    end
  end

  # ── Stage 2 (task 019f474d) — prompt context injection ────────────────────
  #
  # These tests capture the messages the classifier hands to the
  # provider so we can assert on the rendered prompt string. The
  # stub returns a fixed happy-path JSON so the pipeline still runs
  # to completion (queue write + terminal telemetry) and we can
  # correlate rendered prompt to enqueue result.

  # Delete the DB template so `resolve_prompt/5` walks the inline
  # fallback branch. That's the only prompt content we can assert
  # exact strings on from within the test — the DB template body is
  # rewritten by a migration whose exact wording lives elsewhere.
  defp force_fallback_prompt! do
    case PromptTemplates.get_template_by_slug(@prompt_slug) do
      nil -> :ok
      template -> PromptTemplates.delete_template(template)
    end
  end

  # Stub that captures every messages list it is called with into the
  # test's mailbox and returns a fixed valid intent JSON — so the
  # classifier makes it all the way to enqueue + terminal telemetry.
  defp capture_prompt_stub(test_pid) do
    fn _creds, messages, _opts ->
      send(test_pid, {:captured_prompt, messages})

      {:ok,
       %{
         content:
           Jason.encode!(%{
             "intent" => "brief_worthy",
             "target_role" => "meeting_scribe",
             "confidence" => 0.8
           })
       }}
    end
  end

  describe "classify_and_enqueue — context injection" do
    setup do
      agent = create_agent!(%{slug: "intent-agent-context"})
      assign_intent_role!(agent)
      IntentQueue.drop_for_room("room-context")
      force_fallback_prompt!()
      %{agent: agent}
    end

    test "3rd chunk's prompt lists chunks 1-2 as prior context with do-not-classify framing and excludes the current chunk" do
      {pid, _name} = start_classifier!(context_window_size: 3)
      plant_stub_fun(pid, capture_prompt_stub(self()))

      capture_log(fn ->
        _ =
          broadcast_chunk("room-context",
            segment: %{
              id: "seg-c1",
              text: "first chunk about billing",
              speaker_name: "alice",
              timestamp_ms: 5_000
            }
          )

        _ = assert_receive {:captured_prompt, _}, 500

        _ =
          broadcast_chunk("room-context",
            segment: %{
              id: "seg-c2",
              text: "second chunk about the bug",
              speaker_name: "bob",
              timestamp_ms: 12_000
            }
          )

        _ = assert_receive {:captured_prompt, _}, 500

        _ =
          broadcast_chunk("room-context",
            segment: %{
              id: "seg-c3",
              text: "third chunk should be classified",
              speaker_name: "carol",
              timestamp_ms: 20_000
            }
          )

        assert_receive {:captured_prompt, messages}, 500

        prompt =
          messages
          |> Enum.find(fn %{role: role} -> role == "system" end)
          |> Map.fetch!(:content)

        # do-not-classify framing must be present
        assert prompt =~ "DO NOT classify these lines"

        # chunks 1 and 2 appear in chronological order (oldest first)
        idx_1 = :binary.match(prompt, "first chunk about billing") |> elem(0)
        idx_2 = :binary.match(prompt, "second chunk about the bug") |> elem(0)
        assert idx_1 < idx_2, "prior context must be rendered oldest-first"

        # timestamps + speakers render as `- [MM:SS] speaker: text`
        assert prompt =~ "- [00:05] alice: first chunk about billing"
        assert prompt =~ "- [00:12] bob: second chunk about the bug"

        # current chunk MUST NOT appear inside the prior-context block —
        # it's rendered as the Transcript chunk line in the fallback
        # template. We assert absence by pattern: the third chunk's
        # text must not appear preceded by the `- [` list marker.
        refute prompt =~ "- [00:20] carol: third chunk should be classified"

        # It DOES appear as the current utterance in the fallback
        # template.
        assert prompt =~ "third chunk should be classified"
      end)
    end
  end

  describe "classify_and_enqueue — sliding window in prompt" do
    setup do
      agent = create_agent!(%{slug: "intent-agent-window"})
      assign_intent_role!(agent)
      IntentQueue.drop_for_room("room-window")
      force_fallback_prompt!()
      %{agent: agent}
    end

    test "with window size 3 and 5 chunks, the 5th sees chunks 2..4 as prior context — chunk 1 evicted" do
      {pid, _name} = start_classifier!(context_window_size: 3)
      plant_stub_fun(pid, capture_prompt_stub(self()))

      capture_log(fn ->
        # Broadcast 5 chunks; capture each rendered prompt in order.
        prompts =
          for i <- 1..5 do
            _ =
              broadcast_chunk("room-window",
                segment: %{
                  id: "seg-w#{i}",
                  text: "window chunk #{i}",
                  speaker_name: "spk-#{i}",
                  timestamp_ms: i * 1_000
                }
              )

            assert_receive {:captured_prompt, messages}, 500

            messages
            |> Enum.find(fn %{role: role} -> role == "system" end)
            |> Map.fetch!(:content)
          end

        fifth_prompt = List.last(prompts)

        # Chunks 2, 3, 4 land in the prior-context block for chunk 5.
        assert fifth_prompt =~ "- [00:02] spk-2: window chunk 2"
        assert fifth_prompt =~ "- [00:03] spk-3: window chunk 3"
        assert fifth_prompt =~ "- [00:04] spk-4: window chunk 4"

        # Chunk 1 must have been evicted from the 3-wide window when
        # chunk 5 renders — its formatted line must not appear.
        refute fifth_prompt =~ "- [00:01] spk-1: window chunk 1",
               "chunk 1 must be evicted from a 3-wide window when chunk 5 renders"

        # Chunk 5 is the CURRENT utterance, not in the prior list.
        refute fifth_prompt =~ "- [00:05] spk-5: window chunk 5"
        assert fifth_prompt =~ "window chunk 5"
      end)
    end
  end

  describe "classify_and_enqueue — dedupe key unchanged by context" do
    setup do
      agent = create_agent!(%{slug: "intent-agent-dedupe"})
      assign_intent_role!(agent)
      IntentQueue.drop_for_room("room-dedupe")
      %{agent: agent}
    end

    test "A -> B -> C -> A: the second A collides with the first even though the surrounding context differs" do
      _ = attach_terminal_recorder!(:classified)
      {pid, _name} = start_classifier!(context_window_size: 3)

      # Fixed happy-path stub — same intent+role for every chunk, so
      # the dedupe key depends solely on `chunk_text`.
      plant_stub_fun(pid, fn _c, _m, _o ->
        {:ok,
         %{
           content:
             Jason.encode!(%{
               "intent" => "brief_worthy",
               "target_role" => "meeting_scribe",
               "confidence" => 0.75
             })
         }}
      end)

      utter_a = "please summarise last quarter's revenue"
      utter_b = "we need to update the billing docs"
      utter_c = "who is on the release call"

      # First A
      :ok =
        MeetingsPubSub.broadcast_transcript_chunk("room-dedupe", %{
          room_id: "room-dedupe",
          transcript_id: "t-dedupe-a1",
          segment: %{id: "seg-a1", text: utter_a, speaker_name: "alice"}
        })

      assert_receive {:classified, _m,
                      %{dedupe_key_hit_or_new: :inserted, dedupe_key: dedupe_key_first}},
                     500

      # B
      :ok =
        MeetingsPubSub.broadcast_transcript_chunk("room-dedupe", %{
          room_id: "room-dedupe",
          transcript_id: "t-dedupe-b",
          segment: %{id: "seg-b", text: utter_b, speaker_name: "bob"}
        })

      assert_receive {:classified, _m, _md}, 500

      # C
      :ok =
        MeetingsPubSub.broadcast_transcript_chunk("room-dedupe", %{
          room_id: "room-dedupe",
          transcript_id: "t-dedupe-c",
          segment: %{id: "seg-c", text: utter_c, speaker_name: "carol"}
        })

      assert_receive {:classified, _m, _md}, 500

      # Second A — same utterance text, different surrounding context
      # (window now holds C+B before it, not empty).
      :ok =
        MeetingsPubSub.broadcast_transcript_chunk("room-dedupe", %{
          room_id: "room-dedupe",
          transcript_id: "t-dedupe-a2",
          segment: %{id: "seg-a2", text: utter_a, speaker_name: "alice"}
        })

      assert_receive {:classified, _m,
                      %{dedupe_key_hit_or_new: :duplicate, dedupe_key: dedupe_key_second}},
                     500

      # The dedupe key MUST NOT depend on prior context — it is a
      # function of `intent <> target_role <> chunk_text` only.
      assert dedupe_key_first == dedupe_key_second,
             "dedupe key must be identical for the same utterance regardless of context window"
    end
  end

  describe "chunk buffer — cleanup on meeting_finished clears prompt context" do
    setup do
      agent = create_agent!(%{slug: "intent-agent-cleanup-context"})
      assign_intent_role!(agent)
      IntentQueue.drop_for_room("room-cleanup-context")
      force_fallback_prompt!()
      %{agent: agent}
    end

    test "after meeting_finished, the next chunk renders (no prior context) instead of the pre-cleanup window" do
      {pid, _name} = start_classifier!(context_window_size: 3)
      plant_stub_fun(pid, capture_prompt_stub(self()))

      capture_log(fn ->
        # Warm the window with two chunks — third will see them as prior.
        _ =
          broadcast_chunk("room-cleanup-context",
            segment: %{
              id: "seg-x1",
              text: "warmup 1",
              speaker_name: "alice",
              timestamp_ms: 1_000
            }
          )

        assert_receive {:captured_prompt, _}, 500

        _ =
          broadcast_chunk("room-cleanup-context",
            segment: %{
              id: "seg-x2",
              text: "warmup 2",
              speaker_name: "bob",
              timestamp_ms: 2_000
            }
          )

        assert_receive {:captured_prompt, _}, 500

        # Fire the cleanup — this drops the room's buffer entry.
        :ok =
          MeetingsPubSub.broadcast_meeting_finished("room-cleanup-context", %{
            room_id: "room-cleanup-context",
            transcript_id: "t-cleanup-ctx",
            space_id: "s-cleanup-ctx"
          })

        # Wait for the cleanup to land in classifier state.
        Process.sleep(30)
        refute Map.has_key?(:sys.get_state(pid).recent_chunks, "room-cleanup-context")

        # Now broadcast a fresh chunk. Its prompt must render the
        # `(no prior context)` sentinel — NOT the warmup lines.
        _ =
          broadcast_chunk("room-cleanup-context",
            segment: %{
              id: "seg-x3",
              text: "post-cleanup utterance",
              speaker_name: "carol",
              timestamp_ms: 10_000
            }
          )

        assert_receive {:captured_prompt, messages}, 500

        prompt =
          messages
          |> Enum.find(fn %{role: role} -> role == "system" end)
          |> Map.fetch!(:content)

        assert prompt =~ "(no prior context)"
        refute prompt =~ "warmup 1"
        refute prompt =~ "warmup 2"
      end)
    end
  end
end
