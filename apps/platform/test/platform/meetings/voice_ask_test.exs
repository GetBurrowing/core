defmodule Platform.Meetings.VoiceAskTest do
  @moduledoc """
  The `voice_ask` bundle (task 01a17b10 stage 4): the meeting voice persona
  asks the install's Burrow agent through the ordinary attention path and
  reads the streamed answer back.

  `async: false`: Burrow and the seeded voice persona are install-wide
  identities (fixed slugs), and the router is one named process.
  """
  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Platform.TenancyFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Mix.Tasks.Platform.SeedMeetingVoiceAgent
  alias Platform.Agents.Burrow
  alias Platform.Chat
  alias Platform.Chat.{ActiveAgentStore, AttentionRouter}
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Federation.{ToolAuthorization, ToolCall, ToolSurface}
  alias Platform.Meetings.VoiceAsk
  alias Platform.Repo

  setup do
    previous_token = Application.get_env(:platform, :agent_host_token)
    previous_cfg = Application.get_env(:platform, VoiceAsk)
    Application.put_env(:platform, :agent_host_token, "voice-ask-token-01a17b10")
    Application.put_env(:platform, VoiceAsk, timeout_ms: 5_000, linger_ms: 1_000)

    on_exit(fn ->
      if previous_token,
        do: Application.put_env(:platform, :agent_host_token, previous_token),
        else: Application.delete_env(:platform, :agent_host_token)

      if previous_cfg,
        do: Application.put_env(:platform, VoiceAsk, previous_cfg),
        else: Application.delete_env(:platform, VoiceAsk)
    end)

    router = Process.whereis(AttentionRouter) || start_supervised!({AttentionRouter, []})
    Sandbox.allow(Repo, self(), router)
    store = Process.whereis(ActiveAgentStore) || start_supervised!({ActiveAgentStore, []})
    Sandbox.allow(Repo, self(), store)

    owner = root_admin!()
    {:ok, burrow} = Burrow.ensure(owner.id, "claude_code")
    {:ok, %{agent: voice, runtime: voice_runtime}} = SeedMeetingVoiceAgent.seed!(owner)

    {:ok, space} =
      Chat.create_space(%{
        name: "Voice ask",
        slug: "voice-ask-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    {:ok, human} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: owner.id,
        display_name: "Host",
        joined_at: DateTime.utc_now()
      })

    {:ok, voice_p} = Chat.add_agent_participant(space.id, voice, display_name: voice.name)
    {:ok, _} = Chat.add_space_agent(space.id, burrow.id, role: "member")
    burrow_p = Chat.get_agent_participant(space.id, burrow.id)

    %{
      burrow: burrow,
      burrow_p: burrow_p,
      voice: voice,
      voice_p: voice_p,
      runtime: voice_runtime,
      space: space,
      human: human
    }
  end

  defp ask!(ctx, extra \\ %{}) do
    args = Map.merge(%{"space_id" => ctx.space.id, "question" => "is the deploy green?"}, extra)
    assert {:ok, result} = ToolCall.invoke("voice_ask_agent", args, ctx.runtime)
    result
  end

  defp poll(ctx, ask_id, since, wait_ms \\ 1_000) do
    ToolCall.invoke(
      "voice_ask_poll",
      %{"ask_id" => ask_id, "since" => since, "wait_ms" => wait_ms},
      ctx.runtime
    )
  end

  defp chunk(ctx, text, opts \\ []) do
    ChatPubSub.broadcast(
      ctx.space.id,
      {:agent_reply_chunk,
       %{
         space_id: ctx.space.id,
         chunk_id: Keyword.get(opts, :chunk_id, "c1"),
         text: text,
         done: Keyword.get(opts, :done, false),
         participant_id: Keyword.get(opts, :participant_id, ctx.burrow_p.id)
       }}
    )
  end

  defp drain, do: :ok = GenServer.call(AttentionRouter, :__drain__)

  describe "the bundle" do
    test "is its own bundle, granted to the voice persona without meetings", ctx do
      assert ~w(voice_ask_agent voice_ask_poll) ==
               ToolSurface.tool_definitions()
               |> Enum.filter(&(&1.bundle == "voice_ask"))
               |> Enum.map(& &1.name)

      assert :ok = ToolAuthorization.authorize("voice_ask_agent", ctx.runtime)
      assert :ok = ToolAuthorization.authorize("voice_ask_poll", ctx.runtime)
      assert {:error, :forbidden} = ToolAuthorization.authorize("meeting_create", ctx.runtime)
      assert {:error, :forbidden} = ToolAuthorization.authorize("intent_ack", ctx.runtime)
    end
  end

  describe "voice_ask_agent" do
    test "posts one message by the caller, mentioning Burrow, that the router routes to Burrow",
         ctx do
      result = ask!(ctx, %{"meeting_id" => "m-1"})
      drain()

      assert result.status == "pending"
      assert result.agent_id == ctx.burrow.id
      assert is_binary(result.ask_id)

      [message] =
        Repo.all(
          from(m in Chat.Message,
            where: m.space_id == ^ctx.space.id and m.participant_id == ^ctx.voice_p.id
          )
        )

      assert message.id == result.message_id
      assert message.content =~ "@[Burrow] is the deploy green?"
      assert message.content =~ VoiceAsk.instruction()

      assert message.metadata["voice_ask"] == %{
               "ask_id" => result.ask_id,
               "routed_to" => ctx.burrow.id,
               "variant" => "burrow",
               "asked_by" => ctx.voice.id,
               "meeting_id" => "m-1"
             }

      burrow_pid = ctx.burrow_p.id

      assert {:ok, decisions} = AttentionRouter.route(message)
      assert [%{participant_id: ^burrow_pid, reason: :mention}] = agent_decisions(ctx, decisions)
      drain()
    end

    test "refuses a target that is not on the space's roster", ctx do
      Repo.delete!(ctx.burrow_p)

      assert {:error, %{code: "agent_not_in_space"}} =
               ToolCall.invoke(
                 "voice_ask_agent",
                 %{"space_id" => ctx.space.id, "question" => "hello?"},
                 ctx.runtime
               )

      assert Repo.aggregate(from(m in Chat.Message, where: m.space_id == ^ctx.space.id), :count) ==
               0
    end
  end

  describe "voice_ask_poll" do
    test "streams Burrow's chunks, ignores other participants, and the posted reply is done",
         ctx do
      %{ask_id: ask_id} = ask!(ctx)

      chunk(ctx, "The deploy", chunk_id: "x", participant_id: ctx.voice_p.id)
      chunk(ctx, "The deploy")

      assert {:ok, %{text: "The deploy", done: false, status: "streaming"}} =
               poll(ctx, ask_id, 0)

      # A chunk from a different participant does not move the text.
      chunk(ctx, "SOMEONE ELSE talking", participant_id: ctx.human.id)
      chunk(ctx, "The deploy is green")

      assert {:ok, %{text: "The deploy is green", done: false}} = poll(ctx, ask_id, 10)

      {:ok, _reply} =
        Chat.post_message(%{
          space_id: ctx.space.id,
          participant_id: ctx.burrow_p.id,
          content_type: "text",
          content: "The deploy is green on main."
        })

      assert {:ok, %{text: "The deploy is green on main.", done: true, status: "done"}} =
               poll(ctx, ask_id, 19)

      drain()
    end

    test "with since at the current length and no new text, returns after wait_ms", ctx do
      %{ask_id: ask_id} = ask!(ctx)
      chunk(ctx, "Hold on")
      assert {:ok, %{text: "Hold on"}} = poll(ctx, ask_id, 0)

      started = System.monotonic_time(:millisecond)

      assert {:ok, %{text: "Hold on", done: false, status: "streaming"}} =
               poll(ctx, ask_id, 7, 200)

      assert System.monotonic_time(:millisecond) - started >= 190
      drain()
    end

    test "times out when nothing arrives", ctx do
      Application.put_env(:platform, VoiceAsk, timeout_ms: 150, linger_ms: 1_000)
      %{ask_id: ask_id} = ask!(ctx)

      assert {:ok, %{status: "timeout", done: true, text: ""}} = poll(ctx, ask_id, 0, 2_000)
      drain()
    end

    test "answered_by is Burrow, never the caller", ctx do
      %{ask_id: ask_id} = ask!(ctx)
      chunk(ctx, "Yes.", done: true)

      assert {:ok, %{answered_by: answered_by, variant: "burrow", done: true}} =
               poll(ctx, ask_id, 0)

      assert answered_by == ctx.burrow.id
      refute answered_by == ctx.voice.id
      drain()
    end

    test "another agent cannot poll the ask", ctx do
      %{ask_id: ask_id} = ask!(ctx)

      assert {:error, %{code: "forbidden"}} =
               VoiceAsk.poll(%{"ask_id" => ask_id}, %{agent_id: ctx.burrow.id})

      assert {:ok, %{status: "pending"}} = poll(ctx, ask_id, 0, 50)
      drain()
    end

    test "an unknown ask reads as unknown", ctx do
      assert {:ok, %{status: "unknown", done: true}} = poll(ctx, Ecto.UUID.generate(), 0, 50)
    end
  end

  defp agent_decisions(ctx, decisions) do
    agent_ids = MapSet.new([ctx.burrow_p.id, ctx.voice_p.id])
    Enum.filter(decisions, &MapSet.member?(agent_ids, &1.participant_id))
  end
end
