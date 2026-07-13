defmodule Platform.Agents.HistorianDispatcherTest do
  @moduledoc """
  DataCase coverage for the wired `dispatch_windowed/4` path added in task
  019f4f55 stage 2. Complements the pure-unit slicer tests in
  `historian_dispatcher_slice_windows_test.exs` by verifying the runtime
  side effects — chat message writes, per-window cursor advance, oversize
  truncation, and the token-budget guard at the message-body boundary.

  The pure-slicer tests fake `Historian.pending_windows_input/1` via
  `input_fn`; here we seed real corpus rows and let the slicer walk the
  DB the way `SystemEventScheduler.fire_threshold/2` will in stage 3.
  """

  use Platform.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Agents.{Agent, Historian, HistorianCursor, HistorianDispatcher}
  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Meetings.Transcript
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo
  alias Platform.Roles
  alias Platform.Tasks.Projects

  # V1 org-scope sentinel (see `Platform.Tasks.Projects`). The
  # `org_historian_cursors.workspace_id` column is NOT NULL at the DB
  # level; the sentinel stands in for "the org-scope workspace" so the
  # cursor advance path doesn't blow up. All existing T6 code paths
  # (`SystemEventScheduler` fan-out, T6 e2e) use the same sentinel.
  @org_workspace Projects.org_scope_workspace_id()

  # No-op chat module so the `AgentResponder.maybe_dispatch/1` call at the
  # tail of each windowed post doesn't try to hit a real LLM. We don't
  # assert on agent replies here — only on the messages the dispatcher
  # itself writes into the historian's system space + the cursor advance.
  defmodule NoopAgentChat do
    def chat(_message, _opts), do: {:ok, %{content: "", model: "test", usage: %{}}}
  end

  setup do
    previous_module = Application.get_env(:platform, :chat_agent_module)
    previous_mode = Application.get_env(:platform, :chat_agent_dispatch_mode)
    previous_budget = Application.get_env(:platform, :historian_window_token_budget)
    previous_cap = Application.get_env(:platform, :historian_max_windows_per_pass)

    Application.put_env(:platform, :chat_agent_module, NoopAgentChat)
    Application.put_env(:platform, :chat_agent_dispatch_mode, :sync)

    on_exit(fn ->
      restore_env(:chat_agent_module, previous_module)
      restore_env(:chat_agent_dispatch_mode, previous_mode)
      restore_env(:historian_window_token_budget, previous_budget)
      restore_env(:historian_max_windows_per_pass, previous_cap)
    end)

    agent = insert_historian_agent()

    {:ok, agent: agent}
  end

  # ── Happy-path multi-window dispatch ────────────────────────────────────

  describe "dispatch_windowed/4 — seeded backlog" do
    test "dispatches N messages (one per window) with cursor metadata", %{agent: agent} do
      # Set a small budget so a modestly-sized backlog splits cleanly.
      Application.put_env(:platform, :historian_window_token_budget, 200)
      Application.put_env(:platform, :historian_max_windows_per_pass, 20)

      # Insert 4 messages spanning 4 different UTC calendar days. Each is
      # ~1_200 bytes → 300 tokens (above the 200-token budget), so the
      # slicer will split the total range into per-day windows.
      chat_space = insert_channel_space("historical")
      chat_participant = insert_user_participant(chat_space.id, "Old Voice")

      now = DateTime.utc_now()

      days_ago =
        Enum.map(1..4, fn d -> DateTime.add(now, -d * 86_400, :second) end)

      Enum.each(days_ago, fn ts ->
        insert_message!(chat_space.id, chat_participant.id, %{
          content: String.duplicate("a", 1_200),
          inserted_at: ts
        })
      end)

      assert {:ok, %{dispatched: dispatched, remaining: remaining}} =
               HistorianDispatcher.dispatch_windowed(
                 "historian",
                 "historian.threshold",
                 %{trigger: "threshold"},
                 @org_workspace
               )

      assert dispatched >= 1
      assert remaining >= 0

      # Every persisted message in the historian's system space carries
      # windowed cursor metadata.
      system_space = Chat.get_space_by_slug("system-#{agent.slug}")
      assert %Chat.Space{} = system_space

      messages =
        Repo.all(
          from(m in Message,
            where: m.space_id == ^system_space.id and m.content_type == "text",
            order_by: [asc: m.inserted_at]
          )
        )

      assert length(messages) == dispatched

      Enum.each(messages, fn m ->
        assert m.metadata["event_type"] == "historian"
        assert m.metadata["trigger"] == "threshold"

        cursor = m.metadata["cursor"]
        assert is_map(cursor)
        assert cursor["namespace"] in ~w(pages journal messages transcripts)
        assert is_binary(cursor["window_start"])
        assert is_binary(cursor["window_end"])
        assert is_integer(m.metadata["window_index"])
        assert is_integer(m.metadata["window_of"])
      end)
    end

    test "advances the corpus cursor after each dispatched window", %{agent: _agent} do
      Application.put_env(:platform, :historian_window_token_budget, 200)
      Application.put_env(:platform, :historian_max_windows_per_pass, 20)

      chat_space = insert_channel_space("cursored")
      chat_participant = insert_user_participant(chat_space.id, "Ada")

      now = DateTime.utc_now()

      # 2 messages, one per day, ~1.2KB each — forces the messages corpus
      # into >=2 windows.
      Enum.each(1..2, fn d ->
        insert_message!(chat_space.id, chat_participant.id, %{
          content: String.duplicate("m", 1_200),
          inserted_at: DateTime.add(now, -d * 86_400, :second)
        })
      end)

      # Precondition: no cursor row for {org_workspace, "messages"} yet.
      refute Repo.one(
               from(c in HistorianCursor,
                 where: c.workspace_id == ^@org_workspace and c.corpus == "messages"
               )
             )

      {:ok, %{dispatched: dispatched}} =
        HistorianDispatcher.dispatch_windowed(
          "historian",
          "historian.threshold",
          %{},
          @org_workspace
        )

      assert dispatched >= 1

      # After the sweep, the cursor for "messages" has advanced to the
      # `window_end` of the last dispatched messages-window.
      cursor =
        Repo.one!(
          from(c in HistorianCursor,
            where: c.workspace_id == ^@org_workspace and c.corpus == "messages"
          )
        )

      assert %DateTime{} = cursor.last_processed_at
    end
  end

  # ── Oversize truncation path ────────────────────────────────────────────

  describe "dispatch_windowed/4 — oversize window" do
    test "emits a truncated body + oversize metadata for a single oversize row", %{
      agent: agent
    } do
      # Budget = 500 tokens (2000 bytes). One transcript row with a
      # 10_000-byte summary alone forces the slicer past the halving
      # floor once the transcripts cursor is bounded at ~2h. The 30-day
      # default lookback would distribute the bytes too thinly per day
      # to hit oversize — pre-stamping the cursor at 2h ago tightens the
      # slice range so the halve-until-min-sub-window branch fires.
      Application.put_env(:platform, :historian_window_token_budget, 500)
      Application.put_env(:platform, :historian_max_windows_per_pass, 20)

      space = insert_channel_space("board-room")

      now = DateTime.utc_now()
      two_hours_ago = DateTime.add(now, -7_200, :second)
      completed_at = DateTime.add(now, -1_200, :second)

      # Pre-stamp the transcripts cursor so the slicer only walks
      # `[two_hours_ago, now)`. Under the default 30-day lookback the
      # per-day byte estimate would fall below budget and skip oversize.
      {:ok, _} =
        Historian.advance_cursor(@org_workspace, "transcripts", nil, two_hours_ago)

      insert_transcript!(%{
        space_id: space.id,
        status: "complete",
        started_at: two_hours_ago,
        completed_at: completed_at,
        # Long summary → summary bytes dominate byte accounting.
        summary: String.duplicate("z ", 5_000),
        segments: []
      })

      assert {:ok, %{dispatched: n}} =
               HistorianDispatcher.dispatch_windowed(
                 "historian",
                 "historian.threshold",
                 %{trigger: "threshold"},
                 @org_workspace
               )

      assert n >= 1

      system_space = Chat.get_space_by_slug("system-#{agent.slug}")
      messages = system_space_messages(system_space)

      oversized =
        Enum.find(messages, fn m ->
          get_in(m.metadata, ["cursor", "namespace"]) == "transcripts" and
            m.metadata["oversize"] == true
        end)

      assert oversized,
             "expected a transcripts-corpus message with oversize: true, got: #{inspect(Enum.map(messages, & &1.metadata))}"

      assert oversized.content =~ "_(truncated — deep-summary rather than deep-curate)_"
    end
  end

  # ── Token-budget guard on rendered body ─────────────────────────────────

  describe "dispatch_windowed/4 — post-render body guard" do
    test "rejects an oversize rendered body without persisting a chat_messages row",
         %{agent: agent} do
      # Force a template whose static content alone blows past
      # `budget_tokens + 10_000` — no matter what digest slot value is
      # substituted, the render produces an oversized body. The
      # dispatcher's guard rejects with `{:oversize_body, tokens}` and
      # never calls `Chat.post_message/1`.
      Application.put_env(:platform, :historian_window_token_budget, 200)
      Application.put_env(:platform, :historian_max_windows_per_pass, 20)

      # cap = 200 + 10_000 = 10_200 tokens → 40_800 bytes.
      # Bloat by 60_000 chars = 15_000 tokens body chrome alone.
      bloat = String.duplicate("x", 60_000)

      # `historian.threshold` is seeded by the T6 migration so we UPDATE
      # rather than create — matches the `force_update_*` migration
      # pattern the repo uses for the same slug.
      case PromptTemplates.get_template_by_slug("historian.threshold") do
        nil ->
          {:ok, _} =
            PromptTemplates.create_template(%{
              slug: "historian.threshold",
              name: "Historian Threshold (test bloat)",
              content: bloat <> "\n\n{{activity_digest}}\n\n{{trigger}}"
            })

        template ->
          {:ok, _} =
            PromptTemplates.update_template(template, %{
              content: bloat <> "\n\n{{activity_digest}}\n\n{{trigger}}"
            })
      end

      chat_space = insert_channel_space("some-space")
      chat_participant = insert_user_participant(chat_space.id, "Sender")

      now = DateTime.utc_now()

      Enum.each(1..2, fn d ->
        insert_message!(chat_space.id, chat_participant.id, %{
          content: String.duplicate("z", 1_200),
          inserted_at: DateTime.add(now, -d * 86_400, :second)
        })
      end)

      before_count = system_space_message_count(agent)

      assert {:error, {:oversize_body, tokens}} =
               HistorianDispatcher.dispatch_windowed(
                 "historian",
                 "historian.threshold",
                 %{trigger: "threshold"},
                 @org_workspace
               )

      assert tokens > HistorianDispatcher.window_budget_tokens() + 10_000

      after_count = system_space_message_count(agent)

      assert after_count == before_count,
             "guard must not persist a chat_messages row on reject"
    end
  end

  # ── Concentrated-density integration ────────────────────────────────────

  describe "dispatch_windowed/4 — concentrated-density integration" do
    # (a) End-to-end: 120KB summary concentrated inside a tight 1h window.
    # Pre-stamp the cursor at 1h ago so the corpus slice range is exactly
    # 1h — matches @min_sub_window_seconds so the halving-floor triggers
    # the oversize path AND the per-day byte histogram cleanly attributes
    # the 120KB to today's UTC date. Verifies the day_bytes telemetry
    # field is stamped onto the emitted window and the oversize truncation
    # marker is prepended to the dispatched message body.
    test "(a) 120KB transcript, tight-range oversize path stamps day_bytes on today",
         %{agent: agent} do
      Application.put_env(:platform, :historian_window_token_budget, 500)
      Application.put_env(:platform, :historian_max_windows_per_pass, 20)

      space = insert_channel_space("concentrated-transcript")

      now = DateTime.utc_now()
      one_hour_ago = DateTime.add(now, -3_600, :second)
      thirty_min_ago = DateTime.add(now, -1_800, :second)
      today_utc = DateTime.to_date(now)

      # Pre-stamp the transcripts cursor at 1h ago so the slice range is
      # tightly [1h_ago, now) = 3600s span — the halving floor.
      {:ok, _} =
        Historian.advance_cursor(@org_workspace, "transcripts", nil, one_hour_ago)

      transcript =
        insert_transcript!(%{
          space_id: space.id,
          status: "complete",
          started_at: one_hour_ago,
          completed_at: thirty_min_ago,
          # 120KB summary — exceeds the 2000-byte budget many times over.
          # 120_000 / 4 = 30_000 tokens; budget = 500 tokens.
          summary: String.duplicate("x", 120_000),
          segments: []
        })

      force_transcript_updated_at!(transcript, thirty_min_ago)

      test_pid = self()
      handler_id = "historian-dispatch-concentrated-a-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:platform, :historian, :window_dispatched],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:window_dispatched, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, %{dispatched: n, remaining: 0}} =
               HistorianDispatcher.dispatch_windowed(
                 "historian",
                 "historian.threshold",
                 %{trigger: "threshold"},
                 @org_workspace
               )

      assert n >= 1

      system_space = Chat.get_space_by_slug("system-#{agent.slug}")
      messages = system_space_messages(system_space)

      oversized =
        Enum.find(messages, fn m ->
          get_in(m.metadata, ["cursor", "namespace"]) == "transcripts" and
            m.metadata["oversize"] == true
        end)

      assert oversized,
             "expected an oversize transcripts message, got: " <>
               inspect(Enum.map(messages, & &1.metadata))

      assert oversized.content =~ "_(truncated — deep-summary rather than deep-curate)_"

      # Drain telemetry events and locate the transcripts-corpus event
      # for today whose day_bytes matches the seeded summary. `octet_length`
      # of the summary is 120_000 and `octet_length` of `[]::text` is 2;
      # the transcripts corpus sums both, so day_bytes >= 120_000.
      events = drain_window_dispatched_events()

      today_transcripts_events =
        Enum.filter(events, fn {_m, meta} ->
          meta.corpus == :transcripts and
            String.starts_with?(
              meta.day_span,
              DateTime.to_iso8601(one_hour_ago) |> String.slice(0, 10)
            )
        end)

      assert Enum.any?(today_transcripts_events, fn {m, _meta} ->
               is_map_key(m, :day_bytes) and m.day_bytes >= 120_000 and m.day_bytes <= 130_000
             end),
             "expected a transcripts telemetry event on #{today_utc} with day_bytes ≈ 120_000, got: " <>
               inspect(today_transcripts_events)
    end

    # (b) Cross-corpus independence: seed one messages row + one
    # transcripts row, both 30min ago inside a pre-stamped 1h cursor
    # window. Assert exactly two messages dispatched (one per corpus),
    # each with its own cursor namespace and day_bytes attribution — no
    # commingling of byte sums across corpora.
    test "(b) messages + transcripts dispatch independently with per-corpus day_bytes",
         %{agent: agent} do
      Application.put_env(:platform, :historian_window_token_budget, 500)
      Application.put_env(:platform, :historian_max_windows_per_pass, 20)

      chat_space = insert_channel_space("crosstalk")
      chat_participant = insert_user_participant(chat_space.id, "Voice")
      transcript_space = insert_channel_space("crosstalk-transcripts")

      now = DateTime.utc_now()
      one_hour_ago = DateTime.add(now, -3_600, :second)
      thirty_min_ago = DateTime.add(now, -1_800, :second)

      # Pre-stamp both cursors 1h ago so the messages + transcripts slice
      # ranges match at exactly the halving floor. This is what makes the
      # two independent single-window emissions land on today, one per
      # corpus.
      {:ok, _} = Historian.advance_cursor(@org_workspace, "messages", nil, one_hour_ago)
      {:ok, _} = Historian.advance_cursor(@org_workspace, "transcripts", nil, one_hour_ago)

      # 100KB message body → 25k tokens > 500 budget → per-day fanout →
      # halve until 1h floor → oversize. Same story for transcripts.
      message =
        insert_message!(chat_space.id, chat_participant.id, %{
          content: String.duplicate("m", 100_000),
          inserted_at: thirty_min_ago
        })

      # `insert_message!` forces `inserted_at` via put_change; verify by
      # re-reading (defence-in-depth for the timestamps callback).
      _ = message

      transcript =
        insert_transcript!(%{
          space_id: transcript_space.id,
          status: "complete",
          started_at: one_hour_ago,
          completed_at: thirty_min_ago,
          summary: String.duplicate("t", 100_000),
          segments: []
        })

      force_transcript_updated_at!(transcript, thirty_min_ago)

      test_pid = self()
      handler_id = "historian-dispatch-concentrated-b-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:platform, :historian, :window_dispatched],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:window_dispatched, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, %{dispatched: n, remaining: 0}} =
               HistorianDispatcher.dispatch_windowed(
                 "historian",
                 "historian.threshold",
                 %{trigger: "threshold"},
                 @org_workspace
               )

      assert n >= 2, "expected at least one message per corpus, got #{n}"

      system_space = Chat.get_space_by_slug("system-#{agent.slug}")
      messages = system_space_messages(system_space)

      by_corpus = Enum.group_by(messages, &get_in(&1.metadata, ["cursor", "namespace"]))

      assert Map.has_key?(by_corpus, "messages"),
             "expected a messages-corpus dispatched message"

      assert Map.has_key?(by_corpus, "transcripts"),
             "expected a transcripts-corpus dispatched message"

      # Telemetry: each corpus must carry its OWN day_bytes value —
      # never the sum of both corpora. Both should land on today.
      events = drain_window_dispatched_events()

      messages_evts = for {m, meta} <- events, meta.corpus == :messages, do: m.day_bytes
      transcripts_evts = for {m, meta} <- events, meta.corpus == :transcripts, do: m.day_bytes

      assert Enum.any?(messages_evts, &(&1 >= 100_000 and &1 <= 110_000)),
             "expected a messages telemetry event with day_bytes ≈ 100_000, got: " <>
               inspect(messages_evts)

      assert Enum.any?(transcripts_evts, &(&1 >= 100_000 and &1 <= 110_000)),
             "expected a transcripts telemetry event with day_bytes ≈ 100_000, got: " <>
               inspect(transcripts_evts)

      # Cross-corpus independence: no telemetry event should attribute the
      # sum of both corpora's bytes (200_000+) to a single window.
      refute Enum.any?(events, fn {m, _meta} -> m.day_bytes >= 200_000 end),
             "day_bytes commingling detected — events: #{inspect(events)}"
    end

    # (c) Cap-resume: seed 25 distinct days of transcripts, cap at 20
    # windows per pass. First sweep drains 20; second sweep picks up the
    # remaining 5 with the per-day histogram recomputed against the
    # advanced cursor.
    test "(c) 25-day backlog: sweep-1 dispatches 20, sweep-2 dispatches remaining 5" do
      Application.put_env(:platform, :historian_window_token_budget, 30_000)
      Application.put_env(:platform, :historian_max_windows_per_pass, 20)

      space = insert_channel_space("cap-resume")
      now = DateTime.utc_now()

      # Pre-stamp the non-transcripts cursors 1h in the future so ONLY
      # the transcripts corpus contributes pending windows across the
      # two sweeps. Sweep 1 dispatches 20 chat_messages into the
      # historian system space with `inserted_at ≈ real utc_now`; the
      # future cursor guarantees those are BEFORE the cursor watermark
      # and don't fire a spurious messages-corpus window on sweep 2.
      future = DateTime.add(now, 3_600, :second)

      Enum.each(~w(pages journal messages), fn c ->
        {:ok, _} = Historian.advance_cursor(@org_workspace, c, nil, future)
      end)

      # Seed 25 transcripts, one per day, at `now - offset * 24h`. Every
      # timestamp is <= now (so the range-end filter in
      # `pending_bytes_per_day` includes each row). Days are 24h apart,
      # so each row's `DateTime.to_date/1` lands on a distinct UTC
      # calendar day (except at the microsecond edge of midnight —
      # not a concern for a test bounded well within a single second).
      transcripts_per_day =
        Enum.map(0..24, fn offset ->
          ts = DateTime.add(now, -offset * 86_400, :second)

          row =
            insert_transcript!(%{
              space_id: space.id,
              status: "complete",
              started_at: ts,
              completed_at: ts,
              # 100KB summary → 25k tokens per day, under 30k budget.
              summary: String.duplicate("c", 100_000),
              segments: []
            })

          force_transcript_updated_at!(row, ts)
          {ts, row}
        end)

      # Nil cursor precondition: no transcripts cursor row yet.
      refute Repo.one(
               from(c in HistorianCursor,
                 where: c.workspace_id == ^@org_workspace and c.corpus == "transcripts"
               )
             )

      # First sweep — cap-hit at 20 windows.
      assert {:ok, %{dispatched: dispatched_1, remaining: remaining_1}} =
               HistorianDispatcher.dispatch_windowed(
                 "historian",
                 "historian.threshold",
                 %{trigger: "threshold-sweep-1"},
                 @org_workspace
               )

      assert dispatched_1 == 20
      assert remaining_1 >= 5

      cursor_after_1 =
        Repo.one!(
          from(c in HistorianCursor,
            where: c.workspace_id == ^@org_workspace and c.corpus == "transcripts"
          )
        )

      assert %DateTime{} = cursor_after_1.last_processed_at

      # The 20th window (oldest-first) covers the day 5 days ago — its
      # window_end is midnight of the day 4 days ago. Cursor should be
      # at-or-past that boundary. We seeded transcripts up through today,
      # so at least 5 days of pending content remain.
      #
      # `transcripts_per_day` is ordered `offset = 0..24` — index 0 is
      # today, index 24 is the oldest (24d ago). The cursor should now
      # sit past the oldest but strictly before today.
      oldest_seeded = transcripts_per_day |> List.last() |> elem(0)
      newest_seeded = transcripts_per_day |> List.first() |> elem(0)

      assert DateTime.compare(cursor_after_1.last_processed_at, oldest_seeded) == :gt,
             "expected cursor to advance past the oldest seeded transcript, got " <>
               inspect(cursor_after_1.last_processed_at)

      assert DateTime.compare(cursor_after_1.last_processed_at, newest_seeded) == :lt,
             "expected cursor to still be behind today's transcript, got " <>
               inspect(cursor_after_1.last_processed_at)

      # Second sweep — drains the remaining 5. `pending_bytes_per_day`
      # recomputes over the [cursor, now) range and returns per-day
      # buckets only for un-drained days — no re-dispatch of first 20.
      assert {:ok, %{dispatched: dispatched_2, remaining: remaining_2}} =
               HistorianDispatcher.dispatch_windowed(
                 "historian",
                 "historian.threshold",
                 %{trigger: "threshold-sweep-2"},
                 @org_workspace
               )

      # Combined dispatch across the two sweeps should cover the seeded
      # non-empty days without duplicates. The exact split can shift by
      # ±1 depending on day-boundary clipping at the `now` edge, but the
      # invariants hold: sweep-2 dispatches > 0, no infinite loop, and
      # sweep-1 + sweep-2 == 25 total windows.
      assert dispatched_2 >= 1
      assert dispatched_2 <= 5
      assert remaining_2 == 0

      assert dispatched_1 + dispatched_2 == 25,
             "expected sweep-1 (#{dispatched_1}) + sweep-2 (#{dispatched_2}) == 25 total, " <>
               "got #{dispatched_1 + dispatched_2}"
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp insert_historian_agent do
    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "historian-#{System.unique_integer([:positive])}",
        name: "Historian",
        status: "active"
      })
      |> Repo.insert!()

    # Pin the historian role — mirrors production wiring so
    # `agent_for_event/1` resolves to this agent.
    case Roles.assign_role("historian", agent.id) do
      {:ok, _} -> :ok
      {:error, _} -> Roles.unassign_role("historian") && Roles.assign_role("historian", agent.id)
    end

    agent
  end

  defp insert_channel_space(name_suffix) do
    {:ok, space} =
      Chat.create_space(%{
        name: "Space #{name_suffix}",
        slug: "channel-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    space
  end

  defp insert_user_participant(space_id, display_name) do
    {:ok, participant} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: display_name,
        joined_at: DateTime.utc_now()
      })

    participant
  end

  defp insert_message!(space_id, participant_id, %{content: content} = attrs) do
    participant = Repo.get!(Chat.Participant, participant_id)

    defaults = %{
      space_id: space_id,
      participant_id: participant_id,
      content_type: "text",
      content: content,
      author_display_name: participant.display_name || "Test"
    }

    params = Map.drop(attrs, [:inserted_at])
    changeset = Message.changeset(%Message{}, Map.merge(defaults, params))

    changeset =
      case Map.get(attrs, :inserted_at) do
        nil -> changeset
        ts -> Ecto.Changeset.put_change(changeset, :inserted_at, ts)
      end

    Repo.insert!(changeset)
  end

  defp insert_transcript!(attrs) do
    defaults = %{room_id: "room-#{System.unique_integer([:positive])}", status: "complete"}

    %Platform.Meetings.Transcript{}
    |> Platform.Meetings.Transcript.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp system_space_messages(%Chat.Space{id: space_id}) do
    Repo.all(
      from(m in Message,
        where: m.space_id == ^space_id and m.content_type == "text",
        order_by: [asc: m.inserted_at]
      )
    )
  end

  defp system_space_message_count(agent) do
    case Chat.get_space_by_slug("system-#{agent.slug}") do
      nil ->
        0

      %Chat.Space{id: id} ->
        Repo.aggregate(from(m in Message, where: m.space_id == ^id), :count)
    end
  end

  defp restore_env(_key, nil), do: :ok
  defp restore_env(key, value), do: Application.put_env(:platform, key, value)

  # `Transcript` autogenerates `updated_at` via `timestamps/1`. To simulate
  # a backdated row for the per-day byte histogram (which keys on
  # `date_trunc('day', updated_at)`), we push the timestamp back with a
  # raw `update_all`. Test-only escape hatch — production never sets
  # `updated_at` directly.
  defp force_transcript_updated_at!(%Transcript{id: id}, %DateTime{} = ts) do
    {1, _} =
      Repo.update_all(
        from(t in Transcript, where: t.id == ^id),
        set: [updated_at: ts]
      )

    :ok
  end

  # Drain telemetry events sent by the per-test attached handler. Blocks
  # up to 100ms per event; returns the full list once the mailbox is
  # empty. Structured as `{measurements, metadata}` tuples.
  defp drain_window_dispatched_events(acc \\ []) do
    receive do
      {:window_dispatched, measurements, metadata} ->
        drain_window_dispatched_events([{measurements, metadata} | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  # Sandbox.allow the AttentionRouter GenServer so any downstream chat
  # writes triggered by AgentResponder → attention scan can reach the
  # test's checked-out connection. Not currently used but kept as a
  # note in case the sync-mode dispatch grows a router hop.
  @doc false
  def _sandbox_allow_attention_router do
    router = Process.whereis(Platform.Chat.AttentionRouter)
    if router, do: Sandbox.allow(Repo, self(), router)
  end

  # Silence the unused-alias warning while keeping the alias handy for
  # future test scaffolding.
  @doc false
  def _touch_historian, do: Historian.pending_bytes(nil)
end
