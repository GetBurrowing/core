defmodule Platform.Chat.GroupMentionDeliveryTest do
  use Platform.DataCase, async: false
  import Platform.ExternalUserFixtures
  import Ecto.Query
  alias Platform.Chat
  alias Platform.Chat.{AttentionRouter, GroupMentionToken, MentionGroups, Participant}
  alias Platform.Agents.Agent
  alias Platform.Inbox.Item
  alias Platform.Repo

  defp route(message) do
    router = Process.whereis(AttentionRouter) || start_supervised!({AttentionRouter, []})
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), router)

    store =
      Process.whereis(Platform.Chat.ActiveAgentStore) ||
        start_supervised!({Platform.Chat.ActiveAgentStore, []})

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), store)
    AttentionRouter.route(message)
  end

  setup do
    values = [
      chat_agent_module: Platform.GroupMentionChatStub,
      chat_agent_dispatch_mode: :sync,
      group_mention_test_pid: self()
    ]

    previous = Enum.map(values, fn {key, _} -> {key, Application.get_env(:platform, key)} end)
    Enum.each(values, fn {key, value} -> Application.put_env(:platform, key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:platform, key)
        {key, value} -> Application.put_env(:platform, key, value)
      end)
    end)

    org = Platform.Tenancy.get_org!(Platform.TenancyFixtures.tenant_org_id("group-delivery"))
    admin = create_user!()
    plain_member!(admin, org, "admin")
    target = external_user!(org)
    space = channel!(%{org_id: org.id, agent_attention_policy: "on_mention"})
    author = add_user!(space.id, admin.id)
    target_p = add_user!(space.id, target.id)
    target_p = Repo.update!(Ecto.Changeset.change(target_p, attention_mode: "mention"))
    n = System.unique_integer([:positive])
    agent = Repo.insert!(Agent.changeset(%Agent{}, %{name: "Team #{n}", slug: "group-team-#{n}"}))
    {:ok, agent_p} = Chat.add_agent_participant(space.id, agent)

    {:ok, group} =
      MentionGroups.create_group(admin, org.id, %{
        name: agent.name,
        members: [%{type: "user", id: target.id}, %{type: "agent", id: agent.id}]
      })

    %{
      org: org,
      admin: admin,
      target: target,
      space: space,
      author: author,
      target_p: target_p,
      agent: agent,
      agent_p: agent_p,
      group: group
    }
  end

  defp attrs(c, content, extra \\ %{}) do
    Map.merge(
      %{
        space_id: c.space.id,
        participant_id: c.author.id,
        content_type: "text",
        content: content
      },
      extra
    )
  end

  test "mixed groups and direct overlaps produce one human inbox and one agent decision", c do
    {:ok, second} =
      MentionGroups.create_group(c.admin, c.org.id, %{name: "Overlap", members: c.group.members})

    content =
      GroupMentionToken.encode(c.group.id, c.group.name) <>
        " " <>
        GroupMentionToken.encode(second.id, second.name) <>
        " @[#{c.target.name}] @[#{c.agent.name}]"

    assert {:ok, msg} = Chat.post_message(attrs(c, content))
    assert length(msg.group_mention_recipients) == 2

    assert Repo.aggregate(
             from(i in Item, where: i.user_id == ^c.target.id and i.source_id == ^msg.id),
             :count
           ) == 1

    assert {:ok, decisions} = route(msg)
    assert Enum.count(decisions, &(&1.participant_id == c.agent_p.id)) == 1
    assert Enum.count(decisions, &(&1.participant_id == c.target_p.id)) == 1
    assert_receive :group_chat_called
    refute_receive :group_chat_called
  end

  test "attachment message variants snapshot their original audience", c do
    content = GroupMentionToken.encode(c.group.id, c.group.name)
    Chat.PubSub.subscribe(c.space.id)
    assert {:ok, msg, []} = Chat.post_message_with_attachments(attrs(c, content), [])
    assert {:ok, decisions} = route(msg)
    assert Enum.any?(decisions, &(&1.participant_id == c.agent_p.id))
    agent_participant_id = c.agent_p.id
    group_id = c.group.id

    assert_receive {:attention_needed,
                    %{
                      participant_id: ^agent_participant_id,
                      group_mention_only: true,
                      group_mentions: [%{id: ^group_id}]
                    }}

    assert length(Platform.Chat.GroupMentions.load(msg).group_mention_recipients) == 2
  end

  test "group membership never summons an absent agent", c do
    sibling = channel!(%{org_id: c.org.id})
    n = System.unique_integer([:positive])

    absent =
      Repo.insert!(Agent.changeset(%Agent{}, %{name: "Absent #{n}", slug: "group-absent-#{n}"}))

    {:ok, _} = Chat.add_agent_participant(sibling.id, absent)

    {:ok, group} =
      MentionGroups.create_group(c.admin, c.org.id, %{
        name: "Absent group",
        members: [%{type: "agent", id: absent.id}]
      })

    assert {:ok, msg} =
             Chat.post_message(attrs(c, GroupMentionToken.encode(group.id, group.name)))

    refute Repo.exists?(
             from(p in Participant,
               where:
                 p.space_id == ^c.space.id and p.participant_type == "agent" and
                   p.participant_id == ^absent.id
             )
           )

    assert Platform.Chat.GroupMentions.load(msg).group_mention_recipients == []
  end

  test "skip scan prevents group routing and inbox creation", c do
    assert {:ok, msg} =
             Chat.post_message(
               attrs(c, GroupMentionToken.encode(c.group.id, c.group.name), %{
                 metadata: %{"skip_mention_scan" => true}
               })
             )

    assert {:ok, decisions} = route(msg)
    refute Enum.any?(decisions, &(&1.participant_id == c.agent_p.id))
    refute Repo.exists?(from(i in Item, where: i.source_id == ^msg.id))
  end

  test "edits preserve original authorized context without addressing a new group", c do
    assert {:ok, msg} =
             Chat.post_message(attrs(c, GroupMentionToken.encode(c.group.id, c.group.name)))

    assert {:ok, edited} = Chat.edit_message(msg, "retracted group mention")
    assert c.agent_p.id in Chat.eligible_edit_recipients_for_message(edited)
    assert MapSet.member?(Chat.in_context_message_ids_for_agent(c.agent_p.id, c.space.id), msg.id)

    assert Repo.aggregate(
             from(i in Item, where: i.user_id == ^c.target.id and i.source_id == ^msg.id),
             :count
           ) == 1

    assert {:ok, plain} = Chat.post_message(attrs(c, "ordinary message"))

    assert {:ok, new_reference} =
             Chat.edit_message(plain, GroupMentionToken.encode(c.group.id, c.group.name))

    refute c.agent_p.id in Chat.eligible_edit_recipients_for_message(new_reference)
    refute Repo.exists?(from(i in Item, where: i.source_id == ^plain.id))
  end
end
