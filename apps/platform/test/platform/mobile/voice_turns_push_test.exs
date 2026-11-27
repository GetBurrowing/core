defmodule Platform.Mobile.VoiceTurnsPushTest do
  @moduledoc """
  Task 01a21e75 stage 3, with task 01a21e8d's push rule now on main: while a
  native Voice turn waits in `VoiceTurns.await_reply/4`, the caller is a Voice
  listener in the turn's DM, so the agent's reply is NOT pushed (the device
  shows it in the Live Activity). Once the wait has returned, the next reply
  is pushed again.

  The push is observed through the router's `:notifications_module` seam,
  as `attention_router_voice_listening_push_test.exs` does. The reply rows
  are inserted without a broadcast, so the waiter keeps waiting while the
  router decides. Fixture names are generic.
  """
  use Platform.DataCase, async: false

  import Platform.ExternalUserFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.{ActiveAgentStore, AttentionRouter, Message, Presence}
  alias Platform.Meetings.OnDeviceVoice
  alias Platform.Mobile.VoiceTurns
  alias Platform.Repo

  defmodule PushRecorder do
    def fan_out_to_user(user_id, payload, _opts \\ []) do
      send(:persistent_term.get({__MODULE__, :owner}), {:voice_push, user_id, payload})
      :ok
    end

    def fan_out_to_humans(ids, payload, opts \\ []) do
      send(:persistent_term.get({__MODULE__, :owner}), {:voice_push_humans, ids, payload, opts})
      :ok
    end
  end

  setup do
    router = Process.whereis(AttentionRouter) || start_supervised!({AttentionRouter, []})
    Sandbox.allow(Repo, self(), router)
    store = Process.whereis(ActiveAgentStore) || start_supervised!({ActiveAgentStore, []})
    Sandbox.allow(Repo, self(), store)

    previous = Application.get_env(:platform, :notifications_module)
    Application.put_env(:platform, :notifications_module, PushRecorder)
    :persistent_term.put({PushRecorder, :owner}, self())

    on_exit(fn ->
      if previous,
        do: Application.put_env(:platform, :notifications_module, previous),
        else: Application.delete_env(:platform, :notifications_module)

      :persistent_term.erase({PushRecorder, :owner})
    end)

    user = create_user!()
    n = System.unique_integer([:positive])

    agent =
      Repo.insert!(%Agent{
        slug: "voice-push-turn-#{n}",
        name: "Build agent #{n}",
        status: "active"
      })

    id = "turn-#{n}"
    {:ok, _} = VoiceTurns.send_turn(user, agent.id, "What changed today?", id)
    {:ok, conn} = OnDeviceVoice.open(user, agent)
    %{user: user, id: id, conn: conn}
  end

  defp reply!(conn, content) do
    %Message{}
    |> Message.changeset(%{
      space_id: conn.space_id,
      participant_id: conn.agent_participant_id,
      content_type: "text",
      content: content
    })
    |> Repo.insert!()
  end

  defp route!(message) do
    {:ok, _decisions} = AttentionRouter.route(message)
    :ok = GenServer.call(AttentionRouter, :__drain__)
  end

  defp listening?(space_id, user_id) do
    space_id
    |> Presence.list_space()
    |> Presence.voice_listener_ids()
    |> MapSet.member?(user_id)
  end

  defp settles?(fun, tries \\ 100) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && settles?(fun, tries - 1)
    end
  end

  test "a reply that arrives during await_reply is not pushed; one after it returns is", %{
    user: user,
    id: id,
    conn: conn
  } do
    parent = self()

    waiter =
      spawn(fn ->
        Sandbox.allow(Repo, parent, self())
        send(parent, {:waited, VoiceTurns.await_reply(user, id, 0, 1_500)})
      end)

    assert settles?(fn -> listening?(conn.space_id, user.id) end), "the waiter never listened"

    route!(reply!(conn, "During the wait."))
    user_id = user.id
    refute_received {:voice_push, ^user_id, _}

    assert_receive {:waited, {:ok, _}}, 3_000
    refute Process.alive?(waiter)
    assert settles?(fn -> not listening?(conn.space_id, user.id) end)

    route!(reply!(conn, "After the wait."))
    assert_received {:voice_push, ^user_id, %{kind: "chat_message"}}
  end

  test "another user's turn id is refused and creates no DM for the caller", %{id: id} do
    stranger = create_user!()
    before = Repo.aggregate(Chat.Space, :count)

    assert {:error, :not_found} = VoiceTurns.await_reply(stranger, id, 0, 10)
    assert {:error, :not_found} = VoiceTurns.await_reply(stranger, "turn-nobody", 0, 10)
    assert Repo.aggregate(Chat.Space, :count) == before
  end
end
