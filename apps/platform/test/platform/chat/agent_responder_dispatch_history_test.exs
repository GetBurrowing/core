defmodule Platform.Chat.AgentResponderDispatchHistoryTest do
  @moduledoc """
  Task `01a16bf5` stage 2: TaskRouter posts never reach federated
  `payload.history`, and history is bounded in size.

  ## The incident

  Every `task_assigned` engagement the TaskRouter posts into an execution space
  is ALSO routed to the assignee through AttentionRouter -> AgentResponder, and
  `build_history/3` put the last 12 top-level text messages into
  `payload.history`. Those included earlier engagements (23-38KB each on prod),
  so the Nth dispatch carried up to 12 earlier dispatch bodies.

  ## The claim this file pins

  The Nth delivery's `payload.history` is no larger than the first's, because
  no TaskRouter post is ever a history entry (test (i)); human turns are kept
  with their author (ii); and an entry is capped at 4,096 bytes on a grapheme
  boundary, with the total capped at 32,768 bytes, dropping the oldest (iii).

  ## What would falsify it

  Any engagement marker appearing in the 15th payload's history, or its
  serialized history being larger than the first's. On origin/main the 15th
  carries 12 earlier 30KB bodies.
  """
  use Platform.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Chat
  alias Platform.Chat.AgentResponder
  alias Platform.Chat.AttentionRouter
  alias Platform.Federation.RuntimePresence
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Tasks

  defmodule StubAgentChat do
    def chat(message, _opts), do: {:ok, %{content: "stub: #{message}", model: "stub", usage: %{}}}
  end

  setup do
    previous_module = Application.get_env(:platform, :chat_agent_module)
    previous_mode = Application.get_env(:platform, :chat_agent_dispatch_mode)

    Application.put_env(:platform, :chat_agent_module, StubAgentChat)
    Application.put_env(:platform, :chat_agent_dispatch_mode, :sync)

    on_exit(fn ->
      Application.put_env(:platform, :chat_agent_module, previous_module)
      Application.put_env(:platform, :chat_agent_dispatch_mode, previous_mode)
    end)

    router =
      Process.whereis(AttentionRouter) ||
        start_supervised!({AttentionRouter, []})

    Sandbox.allow(Repo, self(), router)

    runtime_pres = Process.whereis(RuntimePresence) || start_supervised!(RuntimePresence)
    Sandbox.allow(Repo, self(), runtime_pres)

    :ok
  end

  # ── fixture ──────────────────────────────────────────────────────────────

  # An execution space for a task whose assignee is an external agent with a
  # PRESENT runtime, plus a human participant. The test process subscribes to
  # the runtime topic, which is where the federated payload lands.
  defp seed do
    unique = System.unique_integer([:positive])

    owner =
      Repo.insert!(%User{
        email: "dispatch-history-#{unique}@example.com",
        name: "Dispatch History Owner",
        oidc_sub: "oidc-dispatch-history-#{unique}"
      })

    runtime =
      Repo.insert!(%AgentRuntime{
        owner_user_id: owner.id,
        status: "active",
        runtime_id: "rt-dispatch-history-#{unique}",
        display_name: "dispatch-history-rt"
      })

    RuntimePresence.track(runtime.runtime_id)
    on_exit(fn -> RuntimePresence.untrack(runtime.runtime_id) end)

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "ext-dispatch-#{unique}",
        name: "Ext",
        status: "active",
        max_concurrent: 1,
        sandbox_mode: "off",
        model_config: %{"primary" => "anthropic/claude-sonnet-4-6"},
        runtime_type: "external",
        runtime_id: runtime.id
      })
      |> Repo.insert()

    {:ok, project} = Tasks.create_project(%{name: "Dispatch history #{unique}"})

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Dispatch history #{unique}",
        status: "in_progress",
        assignee_id: agent.id,
        assignee_type: "agent"
      })

    {:ok, space} = ExecutionSpace.find_or_create(task.id)
    {:ok, _system} = ExecutionSpace.ensure_system_participant(space.id)
    {:ok, _agent_participant} = Chat.add_agent_participant(space.id, agent, display_name: "Ext")

    {:ok, alice} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: "Alice",
        joined_at: DateTime.utc_now()
      })

    assert :ok = GenServer.call(AttentionRouter, :__drain__)

    topic = "runtime:#{runtime.runtime_id}"
    :ok = PlatformWeb.Endpoint.subscribe(topic)
    on_exit(fn -> PlatformWeb.Endpoint.unsubscribe(topic) end)

    %{space: space, alice: alice, topic: topic}
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp engagement_body(i), do: "ENGAGEMENT-MARKER-#{i} " <> String.duplicate("x", 30_000)

  # Posts through the production path (post_message -> telemetry ->
  # AttentionRouter -> AgentResponder) and returns the federated payload whose
  # current message is the one just posted. Fails if none arrives, so no
  # assertion below can pass against an absent payload.
  defp post_and_capture(ctx, post_fun, marker) do
    flush_broadcasts()
    post_fun.()
    assert :ok = GenServer.call(AttentionRouter, :__drain__)

    payloads = collect_history_payloads([])

    case Enum.filter(payloads, &message_content_contains?(&1, marker)) do
      [payload | _] ->
        payload

      [] ->
        flunk(
          "no federated payload with history arrived on #{ctx.topic} for #{marker}; " <>
            "got #{length(payloads)} other payload(s)"
        )
    end
  end

  defp collect_history_payloads(acc) do
    receive do
      %Phoenix.Socket.Broadcast{event: "attention", payload: %{history: _} = payload} ->
        collect_history_payloads([payload | acc])

      %Phoenix.Socket.Broadcast{} ->
        collect_history_payloads(acc)
    after
      1_000 -> Enum.reverse(acc)
    end
  end

  defp flush_broadcasts do
    receive do
      %Phoenix.Socket.Broadcast{} -> flush_broadcasts()
    after
      0 -> :ok
    end
  end

  defp message_content_contains?(payload, marker) do
    content = get_in(payload, [:message, :content]) || ""
    is_binary(content) and String.contains?(content, marker)
  end

  defp post_engagement!(space_id, i) do
    {:ok, _} =
      ExecutionSpace.post_engagement(space_id, engagement_body(i),
        metadata: %{"reason" => "task_assigned"}
      )

    :ok
  end

  defp post_human!(ctx, content) do
    {:ok, _} =
      Chat.post_message(%{
        space_id: ctx.space.id,
        participant_id: ctx.alice.id,
        content_type: "text",
        content: content
      })

    :ok
  end

  defp history_bytes(payload), do: byte_size(:erlang.term_to_binary(payload.history))

  # ── (i) ──────────────────────────────────────────────────────────────────

  test "(i) the 15th dispatch carries no earlier dispatch body and is no larger than the 1st" do
    ctx = seed()

    first =
      post_and_capture(ctx, fn -> post_engagement!(ctx.space.id, 1) end, "ENGAGEMENT-MARKER-1 ")

    for i <- 2..14, do: post_engagement!(ctx.space.id, i)
    assert :ok = GenServer.call(AttentionRouter, :__drain__)

    fifteenth =
      post_and_capture(ctx, fn -> post_engagement!(ctx.space.id, 15) end, "ENGAGEMENT-MARKER-15 ")

    # Anti-vacuity: the dispatch itself still arrives in full as the current
    # message. The prompt is never truncated.
    assert byte_size(fifteenth.message.content) >= 30_000

    offending =
      Enum.filter(fifteenth.history, &String.contains?(&1.content || "", "ENGAGEMENT-MARKER-"))

    assert offending == [],
           "#{length(offending)} earlier dispatch bodies rode along in payload.history"

    assert history_bytes(fifteenth) <= history_bytes(first),
           "history grew from #{history_bytes(first)} to #{history_bytes(fifteenth)} bytes"
  end

  # ── (ii) ─────────────────────────────────────────────────────────────────

  test "(ii) human turns still appear, with their author, around the dispatches" do
    ctx = seed()

    post_engagement!(ctx.space.id, 1)
    post_human!(ctx, "are you still on this?")
    assert :ok = GenServer.call(AttentionRouter, :__drain__)

    payload =
      post_and_capture(ctx, fn -> post_engagement!(ctx.space.id, 2) end, "ENGAGEMENT-MARKER-2 ")

    assert [%{author: "Alice", content: "are you still on this?"}] =
             Enum.map(payload.history, &Map.take(&1, [:author, :content]))
  end

  # ── (iii) ────────────────────────────────────────────────────────────────

  test "(iii) a 50KB human turn is cut to 4,096 bytes on a grapheme boundary, with the marker" do
    ctx = seed()

    # The marker for 50,000 bytes is 27 bytes, so the cut's budget is 4,069
    # bytes. The 4-byte emoji occupies bytes 4,067..4,070: it straddles the
    # budget, so a byte-level cut would split it and leave invalid UTF-8.
    head = String.duplicate("a", 4_066)
    big = head <> "🚀" <> String.duplicate("b", 50_000 - 4_070)
    assert byte_size(big) == 50_000

    post_human!(ctx, big)
    assert :ok = GenServer.call(AttentionRouter, :__drain__)

    payload =
      post_and_capture(ctx, fn -> post_engagement!(ctx.space.id, 1) end, "ENGAGEMENT-MARKER-1 ")

    assert [%{author: "Alice", content: cut}] = payload.history
    assert byte_size(cut) <= 4_096
    assert String.valid?(cut)
    assert cut =~ ~r/… \[truncated \d+ bytes\]\z/
    [_, dropped] = Regex.run(~r/\[truncated (\d+) bytes\]\z/, cut)
    kept = String.replace(cut, ~r/… \[truncated \d+ bytes\]\z/, "")
    assert byte_size(kept) + String.to_integer(dropped) == 50_000
    assert String.starts_with?(big, kept)
    assert kept == head, "the cut lands before the emoji, not inside it"
  end

  test "(iii) twelve 8KB human turns sum to at most 32,768 content bytes, newest kept" do
    ctx = seed()

    for i <- 1..12 do
      turn = "TURN-" <> String.pad_leading(Integer.to_string(i), 2, "0")
      post_human!(ctx, turn <> " " <> String.duplicate("y", 8_000))
    end

    assert :ok = GenServer.call(AttentionRouter, :__drain__)

    payload =
      post_and_capture(ctx, fn -> post_engagement!(ctx.space.id, 1) end, "ENGAGEMENT-MARKER-1 ")

    total = payload.history |> Enum.map(&byte_size(&1.content)) |> Enum.sum()
    assert total <= 32_768
    assert payload.history != []

    turns = Enum.map(payload.history, fn %{content: c} -> String.slice(c, 0, 7) end)

    assert List.last(turns) == "TURN-12", "the newest turn must survive the total cap"
    assert turns == Enum.sort(turns), "history stays oldest-first"
    refute "TURN-01" in turns, "the oldest turns are the ones dropped"
  end

  # ── unit: the cap helpers directly ───────────────────────────────────────

  test "cap_history_entry leaves short content untouched and never splits a character" do
    assert AgentResponder.cap_history_entry("short", 4_096) == "short"
    assert AgentResponder.cap_history_entry(nil, 4_096) == nil

    for n <- 0..8 do
      content = String.duplicate("a", n) <> String.duplicate("é🚀", 200)
      cut = AgentResponder.cap_history_entry(content, 64)
      assert byte_size(cut) <= 64
      assert String.valid?(cut)
    end
  end
end
