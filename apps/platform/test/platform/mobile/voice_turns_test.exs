defmodule Platform.Mobile.VoiceTurnsTest do
  @moduledoc """
  Task 01a21e75 stage 2: `Platform.Mobile.VoiceTurns`, the native Voice turn
  (a control, Action button or widget with no web view). Fixture names are
  generic.
  """
  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Platform.ExternalUserFixtures

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.{Message, Participant}
  alias Platform.Meetings.OnDeviceVoice
  alias Platform.Mobile.VoiceTurns
  alias Platform.Repo

  defp agent!(status \\ "active") do
    n = System.unique_integer([:positive])
    Repo.insert!(%Agent{slug: "voice-agent-#{n}", name: "Build agent #{n}", status: status})
  end

  defp turn_id, do: "turn-#{System.unique_integer([:positive])}"

  defp user_turns(user) do
    from(m in Message,
      join: p in Participant,
      on: p.id == m.participant_id,
      where: p.participant_type == "user" and p.participant_id == ^user.id,
      where: fragment("? @> ?::jsonb", m.metadata, ^%{"input" => "on_device"})
    )
    |> Repo.all()
  end

  defp backdate!(%{message_id: id}, at) do
    Repo.update_all(from(m in Message, where: m.id == ^id), set: [inserted_at: at])
  end

  # Broadcasts `frame` on the DM topic every 25 ms until stopped, so a
  # waiter that subscribes at any point inside the window receives it.
  defp broadcast_until_stopped(space_id, frame) do
    pid =
      spawn(fn ->
        loop = fn loop, n ->
          receive do
            :stop -> :ok
          after
            25 ->
              Chat.PubSub.broadcast(space_id, frame)
              if n > 0, do: loop.(loop, n - 1), else: :ok
          end
        end

        loop.(loop, 200)
      end)

    on_exit(fn -> send(pid, :stop) end)
    pid
  end

  defp chunk(conn, text) do
    {:agent_reply_chunk,
     %{
       space_id: conn.space_id,
       chunk_id: "chunk-1",
       text: text,
       done: false,
       participant_id: conn.agent_participant_id
     }}
  end

  defp voice_metas(space_id, user_id) do
    space_id
    |> Platform.Chat.Presence.list_space()
    |> Map.get(user_id, %{metas: []})
    |> Map.fetch!(:metas)
    |> Enum.filter(&(Map.get(&1, :surface) == "voice"))
  end

  defp eventually(fun, tries \\ 40) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(25) && eventually(fun, tries - 1)
    end
  end

  # ── partner ────────────────────────────────────────────────────────────

  describe "last_partner/1" do
    test "nil with no on-device turn" do
      user = create_user!()
      assert VoiceTurns.last_partner(user) == nil
    end

    test "the agent of the one turn" do
      user = create_user!()
      agent = agent!()
      {:ok, turn} = VoiceTurns.send_turn(user, agent.id, "Hello", turn_id())

      assert %{agent_id: agent_id, name: name, last_used_at: %DateTime{}} =
               VoiceTurns.last_partner(user)

      assert {agent_id, name} == {agent.id, agent.name}
      assert is_binary(turn.space_id)
    end

    test "the newest turn wins across two agents" do
      user = create_user!()
      older = agent!()
      newer = agent!()
      {:ok, a} = VoiceTurns.send_turn(user, newer.id, "First", turn_id())
      {:ok, b} = VoiceTurns.send_turn(user, older.id, "Second", turn_id())
      backdate!(b, DateTime.add(DateTime.utc_now(), -3600, :second))
      _ = a

      assert VoiceTurns.last_partner(user).agent_id == newer.id
    end

    test "another user's turns never count" do
      user = create_user!()
      other = create_user!()
      {:ok, _} = VoiceTurns.send_turn(other, agent!().id, "Not mine", turn_id())

      assert VoiceTurns.last_partner(user) == nil
    end

    test "a typed DM message is not a Voice turn" do
      user = create_user!()
      agent = agent!()
      {:ok, _space, _msg} = Chat.post_to_agent_dm(user.id, agent.id, "typed")

      assert VoiceTurns.last_partner(user) == nil
    end

    test "an archived agent is skipped for the next newest" do
      user = create_user!()
      kept = agent!()
      gone = agent!()
      {:ok, old} = VoiceTurns.send_turn(user, kept.id, "Older", turn_id())
      backdate!(old, DateTime.add(DateTime.utc_now(), -3600, :second))
      {:ok, _} = VoiceTurns.send_turn(user, gone.id, "Newer", turn_id())
      Repo.update_all(from(a in Agent, where: a.id == ^gone.id), set: [status: "archived"])

      assert VoiceTurns.last_partner(user).agent_id == kept.id
    end
  end

  # ── send ───────────────────────────────────────────────────────────────

  describe "send_turn/4" do
    test "posts ONE plain DM message holding exactly the words" do
      user = create_user!()
      agent = agent!()
      id = turn_id()

      assert {:ok, %{space_id: space_id, path_segment: seg}} =
               VoiceTurns.send_turn(user, agent.id, "  What is on today?  ", id)

      assert [message] = user_turns(user)
      assert message.space_id == space_id
      assert message.content == "What is on today?"
      refute message.content =~ OnDeviceVoice.instruction()
      assert message.metadata == %{"input" => "on_device", "client_turn_id" => id}
      refute Map.has_key?(message.metadata, "source")
      assert Repo.get!(Chat.Space, space_id).kind == "dm"
      assert is_binary(seg) and seg != ""
    end

    test "the same client_turn_id twice posts once" do
      user = create_user!()
      agent = agent!()
      id = turn_id()

      {:ok, first} = VoiceTurns.send_turn(user, agent.id, "Once", id)
      {:ok, second} = VoiceTurns.send_turn(user, agent.id, "Once", id)

      assert first == second
      assert length(user_turns(user)) == 1
    end

    test "blank text, a missing turn id, an unknown or inactive agent are refused" do
      user = create_user!()
      agent = agent!()

      assert {:error, :blank} = VoiceTurns.send_turn(user, agent.id, "   ", turn_id())
      assert {:error, :blank} = VoiceTurns.send_turn(user, agent.id, nil, turn_id())
      assert {:error, :invalid} = VoiceTurns.send_turn(user, agent.id, "Hi", nil)
      assert {:error, :not_found} = VoiceTurns.send_turn(user, Ecto.UUID.generate(), "Hi", "t")
      assert {:error, :not_found} = VoiceTurns.send_turn(user, "nope", "Hi", "t")
      assert {:error, :forbidden} = VoiceTurns.send_turn(user, agent!("paused").id, "Hi", "t")
      assert user_turns(user) == []
    end
  end

  # ── reply ──────────────────────────────────────────────────────────────

  describe "await_reply/4" do
    setup do
      user = create_user!()
      agent = agent!()
      id = turn_id()
      {:ok, _} = VoiceTurns.send_turn(user, agent.id, "Tell me the plan", id)
      {:ok, conn} = OnDeviceVoice.open(user, agent)
      %{user: user, agent: agent, id: id, conn: conn}
    end

    test "two streamed chunks, then the posted reply, each sentence once", %{
      user: user,
      id: id,
      conn: conn
    } do
      p1 = broadcast_until_stopped(conn.space_id, chunk(conn, "First one. Sec"))

      assert {:ok, %{state: "speaking", sentences: ["First one."], spoken: 1, final: false}} =
               VoiceTurns.await_reply(user, id, 0, 5_000)

      send(p1, :stop)

      p2 =
        broadcast_until_stopped(conn.space_id, chunk(conn, "First one. Second one. Thi"))

      assert {:ok, %{state: "speaking", sentences: ["Second one."], spoken: 2, final: false}} =
               VoiceTurns.await_reply(user, id, 1, 5_000)

      send(p2, :stop)

      {:ok, _} =
        Chat.post_message(%{
          space_id: conn.space_id,
          participant_id: conn.agent_participant_id,
          content_type: "text",
          content: "First one. Second one. Third one."
        })

      assert {:ok, %{state: "done", sentences: ["Third one."], spoken: 3, final: true}} =
               VoiceTurns.await_reply(user, id, 2, 5_000)
    end

    test "a posted reply that arrives while waiting ends the wait", %{
      user: user,
      id: id,
      conn: conn
    } do
      parent = self()

      spawn(fn ->
        Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
        Process.sleep(150)

        {:ok, _} =
          Chat.post_message(%{
            space_id: conn.space_id,
            participant_id: conn.agent_participant_id,
            content_type: "text",
            content: "All done."
          })
      end)

      assert {:ok, %{state: "done", sentences: ["All done."], spoken: 1, final: true}} =
               VoiceTurns.await_reply(user, id, 0, 5_000)
    end

    test "nothing in time is thinking with no sentences, and the topic is released", %{
      user: user,
      id: id,
      conn: conn
    } do
      assert {:ok, %{state: "thinking", sentences: [], spoken: 0, final: false}} =
               VoiceTurns.await_reply(user, id, 0, 50)

      Chat.PubSub.broadcast(conn.space_id, chunk(conn, "Late. "))
      refute_receive {:agent_reply_chunk, _}, 100
    end

    test "the user's own echo and another participant's chunk are not the reply", %{
      user: user,
      id: id,
      conn: conn
    } do
      stranger = %{(chunk(conn, "Not it. ") |> elem(1)) | participant_id: Ecto.UUID.generate()}
      broadcast_until_stopped(conn.space_id, {:agent_reply_chunk, stranger})

      assert {:ok, %{state: "thinking", sentences: []}} =
               VoiceTurns.await_reply(user, id, 0, 200)
    end

    test "the wait is capped", %{user: user, id: id} do
      assert VoiceTurns.max_wait_ms() == 25_000
      assert {:ok, %{state: "thinking"}} = VoiceTurns.await_reply(user, id, 0, -5)
    end

    # The push rule itself (task 01a21e8d: no push to a user tracked with a
    # voice surface) is not on main yet; until it is, these assert the
    # presence entry it reads. Whichever branch merges second adds the
    # end-to-end push assertion.
    test "the caller is a voice listener in the DM only while waiting", %{
      user: user,
      id: id,
      conn: conn
    } do
      parent = self()

      spawn(fn ->
        Process.sleep(150)
        send(parent, {:during, voice_metas(conn.space_id, user.id)})
      end)

      assert voice_metas(conn.space_id, user.id) == []
      assert {:ok, %{state: "thinking"}} = VoiceTurns.await_reply(user, id, 0, 400)
      assert_receive {:during, [meta]}, 1_000
      assert Map.take(meta, [:participant_type, :surface]) == VoiceTurns.voice_meta()
      assert eventually(fn -> voice_metas(conn.space_id, user.id) == [] end)
    end

    test "the entry also goes when the request process dies mid-wait", %{
      user: user,
      id: id,
      conn: conn
    } do
      parent = self()

      waiter =
        spawn(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
          VoiceTurns.await_reply(user, id, 0, 5_000)
        end)

      assert eventually(fn -> voice_metas(conn.space_id, user.id) != [] end)
      Process.exit(waiter, :kill)
      assert eventually(fn -> voice_metas(conn.space_id, user.id) == [] end)
    end

    test "another user's client_turn_id is not_found", %{id: id} do
      assert {:error, :not_found} = VoiceTurns.await_reply(create_user!(), id, 0, 50)
      assert {:error, :not_found} = VoiceTurns.await_reply(create_user!(), "missing", 0, 50)
    end
  end
end
