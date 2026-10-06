defmodule Platform.Chat.AttentionRouterAgentDmPushTest do
  @moduledoc """
  Task 01a111bb stage 2: an AGENT's reply in a user-to-agent DM must produce a
  push decision for the user, and the notification built for it must name the
  agent as author. Burrow's AskAgent timeout fallback (stage 5) relies on
  that reply arriving as an ordinary chat push.
  """
  use Platform.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.{ActiveAgentStore, AttentionRouter, Message, Participant}
  alias Platform.Repo

  setup do
    router = Process.whereis(AttentionRouter) || start_supervised!({AttentionRouter, []})
    Sandbox.allow(Repo, self(), router)
    store = Process.whereis(ActiveAgentStore) || start_supervised!({ActiveAgentStore, []})
    Sandbox.allow(Repo, self(), store)
    :ok
  end

  defp user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%Platform.Accounts.User{
      name: "Dm User #{n}",
      email: "dm-push-#{n}@example.com",
      oidc_sub: "dm-push-#{n}"
    })
  end

  defp agent! do
    n = System.unique_integer([:positive])
    Repo.insert!(%Agent{slug: "dm-push-#{n}", name: "Helper #{n}", status: "active"})
  end

  defp participant!(space_id, type, id) do
    Repo.get_by!(Participant, space_id: space_id, participant_type: type, participant_id: id)
  end

  test "an agent's un-mentioned reply in a user-agent DM yields a push decision for the user" do
    user = user!()
    agent = agent!()
    {:ok, dm} = Chat.find_or_create_dm(user.id, "agent", agent.id)
    user_p = participant!(dm.id, "user", user.id)
    agent_p = participant!(dm.id, "agent", agent.id)

    {:ok, reply} =
      %Message{}
      |> Message.changeset(%{
        space_id: dm.id,
        participant_id: agent_p.id,
        content_type: "text",
        content: "The build is green."
      })
      |> Repo.insert()

    {:ok, decisions} = AttentionRouter.route(reply)
    :ok = GenServer.call(AttentionRouter, :__drain__)

    assert [%{reason: reason}] = Enum.filter(decisions, &(&1.participant_id == user_p.id))
    # The user is offline (no presence in the test): the decision must push.
    assert AttentionRouter.send_push?(reason, false)

    notification =
      AttentionRouter.push_notification(agent_p, reply, reason, dm, [], "Helper")

    assert notification.author_id == agent.id
    assert notification.author_type == "agent"
    assert notification.message_id == reply.id
    assert notification.space_id == dm.id
  end
end
