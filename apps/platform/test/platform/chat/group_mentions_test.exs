defmodule Platform.Chat.GroupMentionsTest do
  use Platform.DataCase, async: false
  import Platform.ExternalUserFixtures
  alias Platform.Chat.{GroupMentions, GroupMentionToken, MentionGroups, Message}
  alias Platform.Repo
  import Ecto.Query

  setup do
    org = Platform.Tenancy.get_org!(Platform.TenancyFixtures.tenant_org_id("group-snapshots"))
    admin = create_user!()
    plain_member!(admin, org, "admin")
    target = external_user!(org)
    space = channel!(%{org_id: org.id})
    author = add_user!(space.id, admin.id)
    recipient = add_user!(space.id, target.id)
    {:ok, group} = MentionGroups.create_group(admin, org.id, %{name: "Team", members: [%{type: "user", id: target.id}]})
    %{org: org, admin: admin, target: target, space: space, author: author, recipient: recipient, group: group}
  end

  defp capture(c, content, attrs \\ %{}) do
    {:ok, message} = Repo.transaction(fn ->
      %Message{} |> Message.changeset(Map.merge(%{space_id: c.space.id, participant_id: c.author.id, content: content}, attrs)) |> Repo.insert!() |> GroupMentions.capture!()
    end)
    message
  end

  test "saved audience survives group changes and edit re-resolution", c do
    token = GroupMentionToken.encode(c.group.id, "Team")
    message = capture(c, token <> " " <> token)
    assert length(message.group_mentions) == 1
    assert length(message.group_mention_recipients) == 1
    assert GroupMentions.recipient?(c.recipient, message)
    assert MapSet.member?(GroupMentions.in_context_message_ids(c.recipient, c.space.id), message.id)
    {:ok, _} = MentionGroups.update_group(c.admin, c.group.id, %{name: "Renamed", members: []})
    {:ok, _} = MentionGroups.archive_group(c.admin, c.group.id)
    {:ok, again} = Repo.transaction(fn -> GroupMentions.capture!(%{message | content: "edited"}) end)
    assert again.group_mentions == message.group_mentions
    assert GroupMentions.recipient?(c.recipient, GroupMentions.load(message))
  end

  test "metadata cannot forge recipients", c do
    message = capture(c, "hello", %{metadata: %{"group_mention_recipients" => [%{"participant_id" => c.recipient.id}]}})
    refute GroupMentions.recipient?(c.recipient, message)
    assert GroupMentions.load(message).group_mention_recipients == []
  end

  test "org revocation and participant replacement prevent old delivery", c do
    message = capture(c, GroupMentionToken.encode(c.group.id, "Team"))
    Repo.delete_all(from m in Platform.Tenancy.OrgMembership, where: m.org_id == ^c.org.id and m.user_id == ^c.target.id)
    refute GroupMentions.recipient?(c.recipient, message)
    plain_member!(c.target, c.org)
    Repo.delete!(c.recipient)
    replacement = add_user!(c.space.id, c.target.id)
    refute GroupMentions.recipient?(replacement, message)
    refute GroupMentions.recipient?(c.recipient, message)
  end

  test "external authors and unknown references address nobody", c do
    message = capture(%{c | author: c.recipient}, GroupMentionToken.encode(c.group.id, "Team"))
    assert message.group_mentions == []
    assert message.group_mention_recipients == []
    assert capture(c, GroupMentionToken.encode(Ecto.UUID.generate(), "Unknown")).group_mentions == []
  end

  test "overlapping groups deduplicate and foreign or absent targets are excluded", c do
    absent = create_user!()
    plain_member!(absent, c.org)
    {:ok, second} = MentionGroups.create_group(c.admin, c.org.id, %{name: "Other", members: [%{type: "user", id: c.target.id}, %{type: "user", id: absent.id}]})
    message = capture(c, GroupMentionToken.encode(c.group.id, "Team") <> " " <> GroupMentionToken.encode(second.id, "Other"))
    assert length(message.group_mentions) == 2
    assert [row] = message.group_mention_recipients
    assert Enum.sort(row.group_ids) == Enum.sort([c.group.id, second.id])
    foreign = Platform.Tenancy.get_org!(Platform.TenancyFixtures.tenant_org_id("snapshot-foreign"))
    foreign_admin = create_user!()
    plain_member!(foreign_admin, foreign, "admin")
    {:ok, foreign_group} = MentionGroups.create_group(foreign_admin, foreign.id, %{name: "Secret"})
    assert capture(c, GroupMentionToken.encode(foreign_group.id, "Secret")).group_mentions == []
  end

  test "zero-group captures cannot expand later", c do
    message = capture(c, "original")
    {:ok, replayed} = Repo.transaction(fn -> GroupMentions.capture!(%{message | content: GroupMentionToken.encode(c.group.id, "Team")}) end)
    assert replayed.group_mentions == []
    assert replayed.group_mention_recipients == []
  end

  test "archived users and spaces cannot receive", c do
    message = capture(c, GroupMentionToken.encode(c.group.id, "Team"))
    Repo.update!(Ecto.Changeset.change(c.target, archived_at: DateTime.utc_now()))
    refute GroupMentions.recipient?(c.recipient, message)
    assert capture(c, GroupMentionToken.encode(c.group.id, "Team")).group_mention_recipients == []
    Repo.update!(Ecto.Changeset.change(c.space, archived_at: DateTime.utc_now()))
    refute GroupMentions.recipient?(c.recipient, message)
  end

  test "current read denial excludes snapshot and later delivery", c do
    message = capture(c, GroupMentionToken.encode(c.group.id, "Team"))
    {:ok, _} = Platform.Access.Grants.deny(%{principal: {:user, c.target.id}, permission: "chat.read", resource: {:space, c.space.id}})
    refute GroupMentions.recipient?(c.recipient, message)
    assert capture(c, GroupMentionToken.encode(c.group.id, "Team")).group_mention_recipients == []
  end

  test "caller rollback removes audience and message atomically", c do
    {:error, :rolled_back} = Repo.transaction(fn ->
      message = %Message{} |> Message.changeset(%{space_id: c.space.id, participant_id: c.author.id, content: GroupMentionToken.encode(c.group.id, "Team")}) |> Repo.insert!() |> GroupMentions.capture!()
      assert message.group_mention_recipients != []
      Repo.rollback(:rolled_back)
    end)
    assert Repo.all(from m in Message, where: m.space_id == ^c.space.id) == []
  end
end
