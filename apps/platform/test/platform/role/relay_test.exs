defmodule Platform.Role.RelayTest do
  @moduledoc """
  The web-to-full telemetry relay (task 01a155a6 stage 3).

  One VM plays both nodes. The web node's side of an event is emulated by
  calling, for that event, every handler attached in this VM EXCEPT the
  background consumers in `Relay.consumers/0`, which is exactly the set a web
  node has attached (it starts none of them, and `start/2` adds the relay).
  The full node's side is the real `RelayReceiver` re-executing the twin.

  NOT async: it sets the node role and starts named processes. The relay
  handler is never detached here: it is a boot handler (see the detach audit)
  and it is inert under `:full`, which every other test runs as.
  """

  use Platform.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.{AttentionRouter, ContextPlane, Message}
  alias Platform.Files.CatalogEmitter
  alias Platform.Repo
  alias Platform.Responsibilities.{CutoverMonitor, Router}
  alias Platform.Role.{Relay, RelayReceiver}
  alias Platform.Telemetry.HandlerGuardian

  @posted [:platform, :chat, :message_posted]

  defmodule StubAgentChat do
    def chat(message, opts) do
      if pid = Application.get_env(:platform, :chat_agent_test_pid) do
        send(pid, {:agent_chat_called, message, opts})
      end

      {:ok, %{content: "stub reply", model: "stub", usage: %{}}}
    end
  end

  setup do
    keys = [:chat_agent_module, :chat_agent_dispatch_mode, :chat_agent_test_pid, :role]
    previous = Map.new(keys, &{&1, Application.fetch_env(:platform, &1)})

    Application.put_env(:platform, :chat_agent_module, StubAgentChat)
    Application.put_env(:platform, :chat_agent_dispatch_mode, :sync)
    Application.put_env(:platform, :chat_agent_test_pid, self())

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, v} -> Application.put_env(:platform, key, v)
          :error -> Application.delete_env(:platform, key)
        end
      end
    end)

    router = Process.whereis(AttentionRouter) || start_supervised!({AttentionRouter, []})
    Sandbox.allow(Repo, self(), router)

    assert is_pid(Process.whereis(RelayReceiver)),
           "RelayReceiver is not running: the full role (which tests boot) must start it"

    :ok = Relay.attach()
    :ok
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp dm_with_agent do
    {:ok, space} =
      Chat.create_space(%{
        name: "Relay",
        slug: "relay-#{System.unique_integer([:positive])}",
        kind: "dm"
      })

    {:ok, user} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: "Avery",
        joined_at: DateTime.utc_now()
      })

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "relay-agent-#{System.unique_integer([:positive])}",
        name: "Zip",
        status: "active",
        max_concurrent: 1,
        sandbox_mode: "off",
        model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
      })
      |> Repo.insert()

    {:ok, _} = Chat.add_agent_participant(space.id, agent, display_name: "Zip")
    {space, user}
  end

  # The row is written the way any node writes it; the telemetry is emitted
  # separately so each test chooses which node emits it.
  defp insert_message(space, user, content) do
    %Message{}
    |> Message.changeset(%{
      space_id: space.id,
      participant_id: user.id,
      content_type: "text",
      content: content
    })
    |> Repo.insert!()
  end

  defp posted_metadata(message),
    do: %{
      space_id: message.space_id,
      message_id: message.id,
      participant_id: message.participant_id
    }

  # The module whose code a handler runs. A twin attachment's function is
  # `Relay.handle_twin/4` wrapping the consumer's own (stage 4), so it is
  # unwrapped to the consumer.
  defp handler_module(%{function: function, config: %{function: inner}}) do
    if function == (&Relay.handle_twin/4),
      do: function_module(inner),
      else: function_module(function)
  end

  defp handler_module(handler), do: function_module(handler.function)

  defp function_module(function) do
    {:module, module} = Function.info(function, :module)
    module
  end

  defp handler_ids(event) do
    event
    |> :telemetry.list_handlers()
    |> Enum.filter(&(&1.event_name == event))
    |> MapSet.new(& &1.id)
  end

  # What a web node runs for `event`: every handler attached to it except the
  # background consumers, which a web node never starts.
  defp emit_as_web_node(event, measurements, metadata) do
    consumers = MapSet.new(Relay.consumers())

    handlers =
      event
      |> :telemetry.list_handlers()
      |> Enum.filter(&(&1.event_name == event))
      |> Enum.reject(&MapSet.member?(consumers, handler_module(&1)))

    assert Enum.any?(handlers, &(handler_module(&1) == Relay)),
           "the relay is not attached to #{inspect(event)}; the emulated web node would relay nothing"

    for handler <- handlers, do: handler.function.(event, measurements, metadata, handler.config)
    :ok
  end

  defp settle do
    :ok = GenServer.call(RelayReceiver, :__drain__)
    :ok = GenServer.call(AttentionRouter, :__drain__)
  end

  # Rows recording the POST of `message_id`, under any event name: the twin of
  # `[:platform, :chat, :message_posted]` would be written by the chat handler
  # as "role.relay.platform.chat.message.posted", so the suffix is the match.
  # Routing writes its own "chat.attention.routed" row for the message, on the
  # node that routed it; that row is not a second record of the post.
  defp audit_rows_for(message_id) do
    Repo.aggregate(
      from(e in Platform.Audit.Event,
        where:
          fragment("?->>'message_id'", e.metadata) == ^message_id and
            like(e.event_type, "%message.posted")
      ),
      :count
    )
  end

  # ── exactly once ─────────────────────────────────────────────────────────

  describe "a message posted on a web node" do
    test "is routed to the agent once, on the full node, and audited once, on the web node" do
      Application.put_env(:platform, :role, :web)
      {space, user} = dm_with_agent()
      message = insert_message(space, user, "posted on exp")

      :ok =
        emit_as_web_node(@posted, %{system_time: System.system_time()}, posted_metadata(message))

      settle()

      assert_receive {:agent_chat_called, "posted on exp", _opts}, 1_000
      refute_receive {:agent_chat_called, "posted on exp", _opts}, 300

      assert audit_rows_for(message.id) == 1,
             "expected exactly one audit row (the web node's), got #{audit_rows_for(message.id)}"
    end
  end

  describe "a message posted on a full node" do
    test "never touches the relay: routed once and audited once, even with the relay attached" do
      Application.put_env(:platform, :role, :full)
      {space, user} = dm_with_agent()
      :ok = Phoenix.PubSub.subscribe(Platform.PubSub, Relay.topic())

      {:ok, message} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: user.id,
          content_type: "text",
          content: "posted on prod"
        })

      settle()

      refute_received {:role_relay, _, _, _}
      assert_receive {:agent_chat_called, "posted on prod", _opts}, 1_000
      refute_receive {:agent_chat_called, "posted on prod", _opts}, 300
      assert audit_rows_for(message.id) == 1
    end
  end

  # Task 01a155a6 stage 4. A web peer on another branch can relay metadata of
  # a shape this node's consumers do not expect. ContextPlane's handler
  # badmatches on it in the emitting process, which is the case :telemetry
  # punishes by detaching the handler for the life of the VM.
  describe "a malformed relayed event" do
    setup do
      unless Process.whereis(ContextPlane), do: start_supervised!({ContextPlane, []})
      :ok
    end

    test "leaves the original handler attached; the next twin and the next local post still land" do
      Application.put_env(:platform, :role, :full)
      original_id = "context-plane-handlers"
      twin_id = Relay.twin_handler_id(original_id)
      {space, user} = dm_with_agent()

      # Precondition on the original only: the behavioural assertions below
      # must be what fails when the twin shares the original's id.
      assert original_id in handler_ids(@posted)

      ExUnit.CaptureLog.capture_log(fn ->
        :telemetry.execute(Relay.twin(@posted), %{system_time: System.system_time()}, %{
          space_id: space.id,
          shape: :from_another_branch
        })
      end)

      assert original_id in handler_ids(@posted),
             "the malformed twin detached ContextPlane's ORIGINAL-event handler"

      relayed = insert_message(space, user, "relayed after the malformed one")

      :telemetry.execute(
        Relay.twin(@posted),
        %{system_time: System.system_time()},
        posted_metadata(relayed)
      )

      assert Enum.any?(
               ContextPlane.get_recent_activity(space.id),
               &(&1.message_id == relayed.id)
             ),
             "a well-formed twin after the malformed one was not handled"

      {:ok, local} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: user.id,
          content_type: "text",
          content: "posted on prod after the malformed twin"
        })

      settle()

      assert_receive {:agent_chat_called, "posted on prod after the malformed twin", _opts}, 1_000

      assert Enum.any?(ContextPlane.get_recent_activity(space.id), &(&1.message_id == local.id)),
             "a local post after the malformed twin was not handled by ContextPlane"

      assert twin_id in handler_ids(Relay.twin(@posted)),
             "the malformed twin detached ContextPlane's twin handler"
    end
  end

  describe "RelayReceiver" do
    test "re-executes a relayed event as its twin, and drops an event no consumer reads" do
      test_pid = self()
      id = "relay-test-#{System.unique_integer([:positive])}"
      unrelayed = [:platform, :relay_test, :unknown]

      :ok =
        :telemetry.attach_many(
          id,
          [Relay.twin(@posted), Relay.twin(unrelayed)],
          fn event, _m, metadata, _c -> send(test_pid, {:twin, event, metadata}) end,
          nil
        )

      on_exit(fn -> :telemetry.detach(id) end)

      Phoenix.PubSub.broadcast(
        Platform.PubSub,
        Relay.topic(),
        {:role_relay, @posted, %{system_time: System.system_time()},
         %{
           space_id: Ecto.UUID.generate(),
           message_id: Ecto.UUID.generate(),
           participant_id: Ecto.UUID.generate(),
           probe: 1
         }}
      )

      Phoenix.PubSub.broadcast(
        Platform.PubSub,
        Relay.topic(),
        {:role_relay, unrelayed, %{}, %{probe: 2}}
      )

      :ok = GenServer.call(RelayReceiver, :__drain__)

      assert_received {:twin, [:platform, :role_relay, :platform, :chat, :message_posted],
                       %{probe: 1}}

      refute_received {:twin, _, %{probe: 2}}
    end
  end

  # ── the relay list is derived from the twin attachments ──────────────────

  describe "Relay.events/0" do
    setup do
      unless Process.whereis(ContextPlane), do: start_supervised!({ContextPlane, []})

      tag = System.unique_integer([:positive])
      router = start_supervised!({Router, name: Module.concat(Router, "Relay#{tag}")})
      Sandbox.allow(Repo, self(), router)
      start_supervised!({CutoverMonitor, name: Module.concat(CutoverMonitor, "Relay#{tag}")})
      start_supervised!({CatalogEmitter, name: Module.concat(CatalogEmitter, "Relay#{tag}")})
      :ok
    end

    test "equals the union of the events the running consumers attach as twins" do
      twin_handlers = :telemetry.list_handlers([:platform, :role_relay])

      attached =
        twin_handlers
        |> Enum.map(fn %{event_name: [:platform, :role_relay | event]} -> event end)
        |> MapSet.new()

      assert attached == MapSet.new(Relay.events()), """
      The relay forwards #{inspect(Enum.sort(Relay.events()))}
      but the running consumers attach twins of #{inspect(Enum.sort(attached))}.
      """
    end

    test "every consumer attaches each event it consumes AND its twin, nothing else" do
      handlers = :telemetry.list_handlers([])

      for consumer <- Relay.consumers() do
        own = Enum.filter(handlers, &(handler_module(&1) == consumer))
        refute own == [], "#{inspect(consumer)} is running but attaches no telemetry handler"

        {twins, originals} = Enum.split_with(own, &Relay.twin?(&1.event_name))
        originals = originals |> Enum.map(& &1.event_name) |> MapSet.new()

        twins =
          MapSet.new(twins, fn %{event_name: [:platform, :role_relay | e]} -> e end)

        assert originals == MapSet.new(consumer.relayed_events()),
               "#{inspect(consumer)} consumes #{inspect(originals)} but reports #{inspect(consumer.relayed_events())}"

        assert twins == originals,
               "#{inspect(consumer)} attaches twins of #{inspect(twins)} for originals #{inspect(originals)}"
      end
    end

    test "every consumer's twins are under <id>.relay with the guarded handler, never the original id" do
      handlers = :telemetry.list_handlers([])

      for consumer <- Relay.consumers() do
        own = Enum.filter(handlers, &(handler_module(&1) == consumer))
        {twins, originals} = Enum.split_with(own, &Relay.twin?(&1.event_name))

        original_ids = MapSet.new(originals, & &1.id)
        twin_ids = MapSet.new(twins, & &1.id)

        refute twins == [], "#{inspect(consumer)} attaches no twin"

        assert twin_ids == MapSet.new(original_ids, &Relay.twin_handler_id/1), """
        #{inspect(consumer)} attaches twins under #{inspect(twin_ids)} for originals under
        #{inspect(original_ids)}: a twin sharing an original's id would take the original
        down with it when :telemetry detaches it.
        """

        assert MapSet.disjoint?(twin_ids, original_ids)

        for twin <- twins do
          assert twin.function == (&Relay.handle_twin/4),
                 "#{inspect(consumer)}'s twin #{inspect(twin.event_name)} is not guarded"
        end
      end
    end

    test "only the background consumers attach to a twin: no audit or other boot handler does" do
      boot = HandlerGuardian.boot_handlers() |> Map.values() |> MapSet.new()
      consumers = MapSet.new(Relay.consumers())

      for module <- boot, do: :ok = module.attach()

      twin_modules =
        [:platform, :role_relay]
        |> :telemetry.list_handlers()
        |> MapSet.new(&handler_module/1)

      assert MapSet.subset?(twin_modules, consumers),
             "non-consumers attached to relayed twins: #{inspect(MapSet.difference(twin_modules, consumers))}"

      assert MapSet.disjoint?(twin_modules, boot)
    end
  end
end
