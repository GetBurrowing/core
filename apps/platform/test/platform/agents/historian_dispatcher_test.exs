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
