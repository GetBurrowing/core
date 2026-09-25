defmodule Platform.Chat.ReplyContextMentionTest do
  @moduledoc """
  Task 01a0d8de stage 2, case (f): the discriminating mention test for the
  `context` escape in `Platform.Chat.ReplyContext`.

  Mention consumers read message CONTENT, and an agent author fails the summon
  gate (task 01a0ac64), so "no participant was added after an agent reply" is
  true whether or not the escape exists. To test the escape itself, an
  AUTHORIZED author (a space admin user, the only kind that can summon) posts
  `normalize/3`'s context output as content. The positive control posts the
  raw token with the same author and fixture agent, and the agent IS added:
  without it the negative would pass against a parser that matched nothing.

  The last test documents that a runtime reply carrying the token only in
  `context` adds no participant. That is evidence metadata is not scanned; it
  is not evidence for the escape.

  Every token below is built at runtime from its parts.
  """

  use PlatformWeb.ChannelCase, async: false

  import Ecto.Query

  alias Platform.Chat
  alias Platform.Chat.Participant
  alias Platform.Chat.ReplyContext
  alias Platform.Federation
  alias Platform.Repo

  defp agent! do
    n = System.unique_integer([:positive])

    Repo.insert!(%Platform.Agents.Agent{
      name: "Ctx Mention Target #{n}",
      slug: "ctx-mention-target-#{n}",
      status: "active"
    })
  end

  defp user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%Platform.Accounts.User{
      name: "Ctx User #{n}",
      email: "ctx-mention-#{n}@example.com",
      oidc_sub: "sub-ctx-mention-#{n}"
    })
  end

  defp channel! do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{name: "Ctx Mention #{n}", slug: "ctx-mention-#{n}", kind: "channel"})

    space
  end

  defp admin!(space_id) do
    user = user!()

    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        role: "admin",
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

  defp token(agent), do: "@" <> "[" <> agent.slug <> "]"

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

  test "POSITIVE CONTROL: an admin posting the raw token as content adds the agent" do
    space = channel!()
    target = agent!()
    admin = admin!(space.id)

    assert agent_rows(space.id, target.id) == []

    post!(space.id, admin.id, "ask " <> token(target) <> " about it")

    assert [_row] = agent_rows(space.id, target.id)
  end

  test "an admin posting normalize/3's context output as content adds no agent" do
    space = channel!()
    target = agent!()
    admin = admin!(space.id)

    {%{"reply_context" => escaped}, []} =
      ReplyContext.normalize(
        %{"context" => "ask " <> token(target) <> " about it"},
        space.id,
        admin.id
      )

    msg = post!(space.id, admin.id, escaped)

    # The message posted and carries the escaped form, and nothing was added.
    assert msg.content == escaped
    assert agent_rows(space.id, target.id) == []
  end

  test "a runtime reply with the token only in context adds no participant" do
    owner = user!()
    replier = agent!()
    target = agent!()

    {:ok, runtime} =
      Federation.register_runtime(owner.id, %{
        runtime_id: "ctx-mention-rt-#{System.unique_integer([:positive])}"
      })

    {:ok, activated, raw_token} = Federation.activate_runtime(runtime)
    {:ok, _} = Federation.link_agent(activated, replier)
    runtime = Federation.get_runtime(activated.id)

    space = channel!()
    {:ok, _} = Chat.add_agent_participant(space.id, replier, display_name: replier.name)

    {:ok, socket} =
      connect(PlatformWeb.RuntimeSocket, %{
        "runtime_id" => runtime.runtime_id,
        "token" => raw_token
      })

    {:ok, _reply, socket} = subscribe_and_join(socket, "runtime:#{runtime.runtime_id}", %{})

    ref =
      push(socket, "reply", %{
        "space_id" => space.id,
        "content" => "plain answer",
        "context" => "loop in " <> token(target)
      })

    assert_reply ref, :ok, %{message_id: message_id}
    assert Repo.get!(Chat.Message, message_id).metadata["reply_context"] =~ target.slug
    # Deliberately no assertion on the escape here: this test must stay green
    # with the escape removed (recorded as the non-discriminating case), which
    # is what shows metadata is not scanned. The escape is pinned in
    # ReplyContextTest and the RuntimeChannelTest case (e).
    assert agent_rows(space.id, target.id) == []
  end
end
