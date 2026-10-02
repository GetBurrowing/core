defmodule Platform.Chat.SlugMentionRoutingTest do
  @moduledoc """
  Task 01a0fdfe stage 2: a bracketed SLUG mention must both summon the agent
  into the space AND be routed to it, through the real post path.

  Before stage 1 the summon path (`Chat.mentioned_summonable_agents/2`)
  matched a token against an agent's slug or name while the router
  (`AttentionRouter.mentioned?/3`) matched only the participant's cached
  display name. A slug token therefore added the agent and then never
  delivered the message to it. Stage 1 routed both through
  `Platform.Chat.MentionIdentity`; these tests pin the end-to-end outcome by
  driving `Chat.post_message/1`, not `AttentionRouter.route/1`, so the
  post-commit summon and the router's telemetry handler run in their
  production order.

  The tokens are string literals on purpose. Deriving them from `agent.slug`
  or `MentionIdentity.agent_keys/1` would let a defect shared by the fixture
  and the code under test make both sides agree.
  """

  use Platform.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Chat
  alias Platform.Chat.{ActiveAgentStore, AttentionRouter, Participant}
  alias Platform.Repo

  defmodule StubAgentChat do
    def chat(message, opts) do
      if pid = Application.get_env(:platform, :chat_agent_test_pid) do
        send(pid, {:agent_chat_called, message, opts})
      end

      {:ok, %{content: "stub reply", model: "stub", usage: %{}}}
    end
  end

  setup do
    previous_module = Application.get_env(:platform, :chat_agent_module)
    previous_mode = Application.get_env(:platform, :chat_agent_dispatch_mode)
    previous_pid = Application.get_env(:platform, :chat_agent_test_pid)

    Application.put_env(:platform, :chat_agent_module, StubAgentChat)
    Application.put_env(:platform, :chat_agent_dispatch_mode, :sync)
    Application.put_env(:platform, :chat_agent_test_pid, self())

    on_exit(fn ->
      Application.put_env(:platform, :chat_agent_module, previous_module)
      Application.put_env(:platform, :chat_agent_dispatch_mode, previous_mode)
      Application.put_env(:platform, :chat_agent_test_pid, previous_pid)
    end)

    router =
      Process.whereis(AttentionRouter) ||
        start_supervised!({AttentionRouter, []})

    Sandbox.allow(Repo, self(), router)

    store =
      Process.whereis(ActiveAgentStore) ||
        start_supervised!({ActiveAgentStore, []})

    Sandbox.allow(Repo, self(), store)

    test_pid = self()
    handler_id = "slug-mention-routing-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:platform, :chat, :attention_routed],
        fn _event, _measurements, metadata, _cfg ->
          send(test_pid, {:attention_routed, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  defp agent!(slug, name, status \\ "active") do
    Repo.insert!(%Platform.Agents.Agent{
      name: name,
      slug: slug,
      status: status,
      max_concurrent: 1,
      sandbox_mode: "off",
      model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
    })
  end

  defp user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%Platform.Accounts.User{
      name: "User #{n}",
      email: "slugroute-#{n}@example.com",
      oidc_sub: "sub-slugroute-#{n}"
    })
  end

  defp channel! do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{name: "Slug Route #{n}", slug: "slug-route-#{n}", kind: "channel"})

    space
  end

  defp user_participant!(space_id, user, role) do
    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        role: role,
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp agent_rows(space_id, agent_id) do
    Repo.all(
      from(p in Participant,
        where:
          p.space_id == ^space_id and p.participant_type == "agent" and
            p.participant_id == ^agent_id
      )
    )
  end

  defp post!(space_id, participant_id, content) do
    {:ok, msg} =
      Chat.post_message(%{
        space_id: space_id,
        participant_id: participant_id,
        content_type: "text",
        content: content
      })

    msg
  end

  defp drain do
    :ok = GenServer.call(AttentionRouter, :__drain__)
  end

  test "an admin's literal slug mention adds the agent AND routes the message to it" do
    space = channel!()
    agent = agent!("slugroute-probe", "Unrelated Display Name")
    author = user_participant!(space.id, user!(), "admin")

    assert agent_rows(space.id, agent.id) == []

    msg = post!(space.id, author.id, "hey @[slugroute-probe] hi")
    drain()

    assert [%Participant{id: agent_participant_id}] = agent_rows(space.id, agent.id)
    message_id = msg.id

    assert_receive {:attention_routed,
                    %{
                      reason: :mention,
                      message_id: ^message_id,
                      recipient_id: ^agent_participant_id
                    }},
                   500

    assert_receive {:agent_chat_called, "hey @[slugroute-probe] hi", _opts}, 500
    drain()
  end

  test "control: an admin's literal display-name mention routes identically" do
    space = channel!()
    agent = agent!("slugroute-name-probe", "Probe Display")
    author = user_participant!(space.id, user!(), "admin")

    msg = post!(space.id, author.id, "hey @[Probe Display] hi")
    drain()

    assert [%Participant{id: agent_participant_id}] = agent_rows(space.id, agent.id)
    message_id = msg.id

    assert_receive {:attention_routed,
                    %{
                      reason: :mention,
                      message_id: ^message_id,
                      recipient_id: ^agent_participant_id
                    }},
                   500

    assert_receive {:agent_chat_called, "hey @[Probe Display] hi", _opts}, 500
    drain()
  end

  test "a non-admin member's slug mention adds nothing and dispatches nothing" do
    space = channel!()
    agent = agent!("slugroute-member-probe", "Member Probe Name")
    author = user_participant!(space.id, user!(), "member")

    msg = post!(space.id, author.id, "hey @[slugroute-member-probe] hi")
    drain()

    assert msg.id
    assert agent_rows(space.id, agent.id) == []
    message_id = msg.id
    refute_received {:attention_routed, %{message_id: ^message_id}}
    refute_receive {:agent_chat_called, _, _}, 200
  end

  test "an archived agent's slug mention by an admin adds nothing and dispatches nothing" do
    space = channel!()
    agent = agent!("slugroute-archived-probe", "Archived Probe Name", "archived")
    author = user_participant!(space.id, user!(), "admin")

    msg = post!(space.id, author.id, "hey @[slugroute-archived-probe] hi")
    drain()

    assert msg.id
    assert agent_rows(space.id, agent.id) == []
    message_id = msg.id
    refute_received {:attention_routed, %{message_id: ^message_id}}
    refute_receive {:agent_chat_called, _, _}, 200
  end
end
