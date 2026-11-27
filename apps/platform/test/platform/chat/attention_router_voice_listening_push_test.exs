defmodule Platform.Chat.AttentionRouterVoiceListeningPushTest do
  @moduledoc """
  Task 01a21e8d stage 1: an agent reply in a space where the recipient is
  listening on the Voice page (a `Chat.Presence` entry whose meta carries
  `surface: "voice"`) must not also go out as a push. The person is already
  hearing it.

  The push is observed through the router's `:notifications_module` seam,
  which makes `deliver_push/2` call `fan_out_to_user/2` synchronously (the
  same seam `attention_router_test.exs` uses for notification levels).

  Presence is tracked from a spawned helper pid, standing in for the Voice
  LiveView process that stage 2 tracks from.
  """
  use Platform.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.{ActiveAgentStore, AttentionRouter, Message, Participant, Presence}
  alias Platform.Repo

  @suppressed_event [:platform, :push, :suppressed_active_voice]

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

    test_pid = self()
    handler_id = "voice-listening-push-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        @suppressed_event,
        fn event, measurements, metadata, _config ->
          send(test_pid, {:suppressed_telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn ->
      :telemetry.detach(handler_id)

      if previous,
        do: Application.put_env(:platform, :notifications_module, previous),
        else: Application.delete_env(:platform, :notifications_module)

      :persistent_term.erase({PushRecorder, :owner})
    end)

    :ok
  end

  # ── Fixtures ───────────────────────────────────────────────────────────────

  defp user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%Platform.Accounts.User{
      name: "Voice User #{n}",
      email: "voice-push-#{n}@example.com",
      oidc_sub: "voice-push-#{n}"
    })
  end

  defp agent! do
    n = System.unique_integer([:positive])
    Repo.insert!(%Agent{slug: "voice-push-#{n}", name: "Partner #{n}", status: "active"})
  end

  defp participant!(space_id, type, id) do
    Repo.get_by!(Participant, space_id: space_id, participant_type: type, participant_id: id)
  end

  defp dm!(user, agent) do
    {:ok, dm} = Chat.find_or_create_dm(user.id, "agent", agent.id)
    {dm, participant!(dm.id, "agent", agent.id)}
  end

  defp channel! do
    n = System.unique_integer([:positive])
    {:ok, space} = Chat.create_space(%{name: "Voice", slug: "voice-#{n}", kind: "channel"})
    space
  end

  defp join!(space_id, attrs) do
    defaults = %{
      participant_type: "user",
      participant_id: Ecto.UUID.generate(),
      display_name: "Member",
      joined_at: DateTime.utc_now()
    }

    {:ok, participant} = Chat.add_participant(space_id, Map.merge(defaults, attrs))
    participant
  end

  defp post!(space_id, author_participant_id, content) do
    %Message{}
    |> Message.changeset(%{
      space_id: space_id,
      participant_id: author_participant_id,
      content_type: "text",
      content: content
    })
    |> Repo.insert!()
  end

  defp route!(message) do
    {:ok, decisions} = AttentionRouter.route(message)
    :ok = GenServer.call(AttentionRouter, :__drain__)
    decisions
  end

  # A stand-in for the LiveView process that owns the presence entry.
  defp holder! do
    pid = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp track_voice!(pid, space_id, user_id) do
    {:ok, _} =
      Presence.track_in_space(pid, space_id, user_id, %{
        participant_type: "user",
        surface: "voice"
      })

    :ok
  end

  defp track_chat!(pid, space_id, user_id) do
    {:ok, _} =
      Presence.track_in_space(pid, space_id, user_id, %{
        participant_type: "user",
        display_name: "Member"
      })

    :ok
  end

  defp await_untracked!(space_id, user_id, tries \\ 100) do
    cond do
      not Map.has_key?(Presence.list_space(space_id), user_id) ->
        :ok

      tries == 0 ->
        flunk("presence entry never cleared")

      true ->
        Process.sleep(20)
        await_untracked!(space_id, user_id, tries - 1)
    end
  end

  # ── Case 1: listening on Voice in that space ───────────────────────────────

  test "an agent reply to a user listening on Voice in that DM is not pushed, and telemetry fires once" do
    user = user!()
    agent = agent!()
    {dm, agent_p} = dm!(user, agent)
    track_voice!(holder!(), dm.id, user.id)

    route!(post!(dm.id, agent_p.id, "The build is green."))

    user_id = user.id
    refute_received {:voice_push, ^user_id, _}

    assert_received {:suppressed_telemetry, @suppressed_event, %{count: 1}, metadata}
    assert metadata == %{reason: :all}
    refute_received {:suppressed_telemetry, _, _, _}
  end

  # ── Case 2: after leaving Voice, the same reply is pushed ──────────────────

  test "after the Voice entry is untracked, an agent reply is pushed" do
    user = user!()
    agent = agent!()
    {dm, agent_p} = dm!(user, agent)
    holder = holder!()
    track_voice!(holder, dm.id, user.id)
    :ok = Presence.untrack_in_space(holder, dm.id, user.id)

    route!(post!(dm.id, agent_p.id, "The build is green."))

    user_id = user.id
    assert_received {:voice_push, ^user_id, %{kind: "chat_message"}}
    refute_received {:suppressed_telemetry, _, _, _}
  end

  test "after the Voice process exits, an agent reply is pushed" do
    user = user!()
    agent = agent!()
    {dm, agent_p} = dm!(user, agent)
    holder = holder!()
    track_voice!(holder, dm.id, user.id)

    ref = Process.monitor(holder)
    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^ref, :process, ^holder, :killed}
    await_untracked!(dm.id, user.id)

    route!(post!(dm.id, agent_p.id, "The build is green."))

    user_id = user.id
    assert_received {:voice_push, ^user_id, %{kind: "chat_message"}}
    refute_received {:suppressed_telemetry, _, _, _}
  end

  # ── Case 3: Voice open on a different space ────────────────────────────────

  test "Voice open on DM A does not silence an agent reply in DM B" do
    user = user!()
    {dm_a, _agent_a_p} = dm!(user, agent!())
    {dm_b, agent_b_p} = dm!(user, agent!())
    track_voice!(holder!(), dm_a.id, user.id)

    route!(post!(dm_b.id, agent_b_p.id, "Your other partner here."))

    user_id = user.id
    assert_received {:voice_push, ^user_id, %{kind: "chat_message"}}
    refute_received {:suppressed_telemetry, _, _, _}
  end

  # ── Case 4: a HUMAN posts where the user is a voice listener ───────────────

  test "a human's message in a channel keeps today's rules for a voice listener" do
    user = user!()
    space = channel!()

    _user_p =
      join!(space.id, %{participant_id: user.id, display_name: "Avery", attention_mode: "mention"})

    human = join!(space.id, %{display_name: "Blake"})
    track_voice!(holder!(), space.id, user.id)

    # A direct mention pushes regardless of presence (send_push?/2).
    route!(post!(space.id, human.id, "@[Avery] can you look?"))

    user_id = user.id
    assert_received {:voice_push, ^user_id, %{kind: "chat_mention"}}
    refute_received {:suppressed_telemetry, _, _, _}
  end

  # ── Case 5: plain chat presence keeps today's behaviour ────────────────────

  test "plain chat presence in a DM still suppresses an agent's :all reply" do
    user = user!()
    agent = agent!()
    {dm, agent_p} = dm!(user, agent)
    track_chat!(holder!(), dm.id, user.id)

    route!(post!(dm.id, agent_p.id, "The build is green."))

    user_id = user.id
    refute_received {:voice_push, ^user_id, _}
    refute_received {:suppressed_telemetry, _, _, _}
  end

  test "plain chat presence in a channel still pushes an agent's :mention" do
    user = user!()
    agent = agent!()
    space = channel!()

    _user_p =
      join!(space.id, %{participant_id: user.id, display_name: "Avery", attention_mode: "mention"})

    agent_p =
      join!(space.id, %{participant_type: "agent", participant_id: agent.id, display_name: "Zip"})

    track_chat!(holder!(), space.id, user.id)

    route!(post!(space.id, agent_p.id, "@[Avery] the build is green."))

    user_id = user.id
    assert_received {:voice_push, ^user_id, %{kind: "chat_mention"}}
    refute_received {:suppressed_telemetry, _, _, _}
  end

  test "a voice listener in a channel is not pushed an agent's :mention" do
    user = user!()
    agent = agent!()
    space = channel!()

    _user_p =
      join!(space.id, %{participant_id: user.id, display_name: "Avery", attention_mode: "mention"})

    agent_p =
      join!(space.id, %{participant_type: "agent", participant_id: agent.id, display_name: "Zip"})

    track_voice!(holder!(), space.id, user.id)

    route!(post!(space.id, agent_p.id, "@[Avery] the build is green."))

    user_id = user.id
    refute_received {:voice_push, ^user_id, _}
    assert_received {:suppressed_telemetry, @suppressed_event, %{count: 1}, %{reason: :mention}}
  end

  # ── Unit: send_push?/3 ─────────────────────────────────────────────────────

  describe "send_push?/3" do
    @reasons [:mention, :all, :active, :watch, :directed, :here, :heartbeat]

    test "a voice listener is never pushed, whatever the reason or presence" do
      for reason <- @reasons, online? <- [true, false] do
        refute AttentionRouter.send_push?(reason, online?, true), inspect({reason, online?})
      end
    end

    test "without a voice listener it is exactly send_push?/2" do
      for reason <- @reasons, online? <- [true, false] do
        assert AttentionRouter.send_push?(reason, online?, false) ==
                 AttentionRouter.send_push?(reason, online?),
               inspect({reason, online?})
      end
    end
  end

  # ── Unit: Presence.voice_listener_ids/1 ────────────────────────────────────

  describe "Presence.voice_listener_ids/1" do
    test "returns keys with a voice meta, atom or string keyed" do
      presences = %{
        "a" => %{metas: [%{participant_type: "user", surface: "voice", phx_ref: "1"}]},
        "b" => %{metas: [%{"participant_type" => "user", "surface" => "voice"}]},
        "c" => %{metas: [%{participant_type: "user", display_name: "Member"}]}
      }

      assert Presence.voice_listener_ids(presences) == MapSet.new(["a", "b"])
    end

    test "a key with a chat meta AND a voice meta is a voice listener" do
      presences = %{
        "a" => %{
          metas: [%{participant_type: "user"}, %{participant_type: "user", surface: "voice"}]
        }
      }

      assert Presence.voice_listener_ids(presences) == MapSet.new(["a"])
    end

    test "visible: false does not count; any other surface does not count" do
      presences = %{
        "a" => %{metas: [%{surface: "voice", visible: false}]},
        "b" => %{metas: [%{"surface" => "voice", "visible" => false}]},
        "c" => %{metas: [%{surface: "voice", visible: true}]},
        "d" => %{metas: [%{surface: "chat"}]},
        "e" => %{metas: []}
      }

      assert Presence.voice_listener_ids(presences) == MapSet.new(["c"])
    end

    test "an empty or malformed map yields an empty set" do
      assert Presence.voice_listener_ids(%{}) == MapSet.new()
      assert Presence.voice_listener_ids(%{"x" => %{}}) == MapSet.new()
    end
  end
end
