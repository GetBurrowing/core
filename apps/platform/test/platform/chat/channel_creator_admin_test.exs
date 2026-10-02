defmodule Platform.Chat.ChannelCreatorAdminTest do
  @moduledoc """
  Task 01a0fd62-a7ef-7001-8477-bd17e47bbaca stage 1.

  `Chat.create_space/1` seats a channel's recorded creator (`created_by`) as an
  admin participant. Before this, no production path produced an admin row in
  a channel, so `mention_summon_authorized?/2` refused every human author.

  Every assertion reads `chat_participants` rows back. The `{:ok, space}`
  returned by `create_channel/1` is the same whether or not a row was written,
  so it is not the evidence.
  """

  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Chat
  alias Platform.Chat.Participant
  alias Platform.Repo

  defp user!(label \\ "creator") do
    n = System.unique_integer([:positive])

    Repo.insert!(%Platform.Accounts.User{
      name: "Creator #{label} #{n}",
      email: "creator-#{label}-#{n}@example.com",
      oidc_sub: "sub-creator-#{label}-#{n}"
    })
  end

  defp user_rows(space_id) do
    Repo.all(
      from(p in Participant,
        where: p.space_id == ^space_id and p.participant_type == "user",
        order_by: [asc: p.joined_at]
      )
    )
  end

  defp admin_rows(space_id) do
    Repo.all(from(p in Participant, where: p.space_id == ^space_id and p.role == "admin"))
  end

  defp channel_attrs(extra \\ %{}) do
    n = System.unique_integer([:positive])
    Map.merge(%{name: "Creator Chan #{n}", slug: "creator-chan-#{n}"}, extra)
  end

  describe "create_channel/1" do
    test "with created_by seats exactly one admin row for the creator" do
      creator = user!()

      {:ok, space} = Chat.create_channel(channel_attrs(%{created_by: creator.id}))

      assert [row] = user_rows(space.id)
      assert row.participant_id == creator.id
      assert row.role == "admin"
      assert row.display_name == creator.name
      assert %DateTime{} = row.joined_at
    end

    test "without created_by seats no user row" do
      {:ok, space} = Chat.create_channel(channel_attrs())

      assert user_rows(space.id) == []
      assert admin_rows(space.id) == []
    end
  end

  describe "DM and group creation are unchanged" do
    test "find_or_create_dm seats both users as members and no admin" do
      a = user!("dm-a")
      b = user!("dm-b")

      assert {:ok, space} = Chat.find_or_create_dm(a.id, "user", b.id)

      rows = user_rows(space.id)
      assert length(rows) == 2
      assert Enum.all?(rows, &(&1.role == "member"))
      assert admin_rows(space.id) == []
    end

    test "create_group_conversation seats each user once as a member and no admin" do
      creator = user!("grp-c")
      b = user!("grp-b")
      c = user!("grp-c2")

      assert {:ok, space} =
               Chat.create_group_conversation(creator.id, [
                 %{type: "user", id: b.id},
                 %{type: "user", id: c.id}
               ])

      rows = user_rows(space.id)
      assert length(rows) == 3
      assert rows |> Enum.map(& &1.participant_id) |> Enum.uniq() |> length() == 3
      assert Enum.all?(rows, &(&1.role == "member"))
      assert admin_rows(space.id) == []
    end
  end
end
