defmodule PlatformWeb.ChatLive.ChatListDataTest do
  @moduledoc """
  `ChatListData.sort_by_recency/3`, the phone Chat list's order inside a
  section (task 01a166bf stage 1). Pure, so no database.
  """

  use ExUnit.Case, async: true

  alias PlatformWeb.ChatLive.ChatListData

  defp space(id, name), do: %{id: id, name: name}
  defp at(iso), do: elem(DateTime.from_iso8601(iso), 1)

  test "sort_by_recency: newest first, no-excerpt rows last by name" do
    rows = [
      space("id-a", "zulu quiet"),
      space("id-b", "Older"),
      space("id-c", "alpha quiet"),
      space("id-d", "Newest"),
      space("id-e", "Middle"),
      space("id-f", "Bravo quiet"),
      # Same instant as Middle: the name breaks the tie.
      space("id-g", "Kilo tie")
    ]

    excerpts = %{
      # id-d is one microsecond after id-e. As strings, "…09:05:00Z" sorts
      # AFTER "…09:05:00.000001Z" ("Z" > "."), so only DateTime.compare/2
      # puts id-d first.
      "id-b" => %{inserted_at: at("2026-10-23T23:59:00Z")},
      "id-d" => %{inserted_at: at("2026-10-24T09:05:00.000001Z")},
      "id-e" => %{inserted_at: at("2026-10-24T09:05:00Z")},
      "id-g" => %{inserted_at: at("2026-10-24T09:05:00Z")}
    }

    sorted = ChatListData.sort_by_recency(rows, excerpts, & &1.name)

    # id-g and id-e share an instant: "kilo tie" < "middle". The quiet rows
    # follow by downcased name, so "Bravo" sits between "alpha" and "zulu".
    assert Enum.map(sorted, & &1.id) ==
             ["id-d", "id-g", "id-e", "id-b", "id-c", "id-f", "id-a"]

    # Pinned entries carry the space under `:space`; the same order applies.
    entries = Enum.map(rows, &%{kind: :channel, space: &1})
    sorted_entries = ChatListData.sort_by_recency(entries, excerpts, & &1.space.name)
    assert Enum.map(sorted_entries, & &1.space.id) == Enum.map(sorted, & &1.id)

    # Equal time and equal name: the id decides, so the order is total.
    twins = [space("id-2", "Same"), space("id-1", "same")]
    same = %{inserted_at: at("2026-10-24T09:00:00Z")}

    assert ChatListData.sort_by_recency(twins, %{"id-1" => same, "id-2" => same}, & &1.name)
           |> Enum.map(& &1.id) == ["id-1", "id-2"]

    # No excerpts at all: plain name order.
    assert ChatListData.sort_by_recency(rows, %{}, & &1.name) |> Enum.map(& &1.name) ==
             ["alpha quiet", "Bravo quiet", "Kilo tie", "Middle", "Newest", "Older", "zulu quiet"]
  end

  test "order_rows: no hold is recency; a hold keeps the snapshot and appends unknown ids by recency" do
    rows = [space("a", "A"), space("b", "B"), space("c", "C"), space("d", "D"), space("e", "E")]

    excerpts = %{
      "a" => %{inserted_at: at("2026-10-24T09:00:00Z")},
      "b" => %{inserted_at: at("2026-10-24T10:00:00Z")},
      "d" => %{inserted_at: at("2026-10-24T12:00:00Z")},
      "e" => %{inserted_at: at("2026-10-24T11:00:00Z")}
    }

    ids = &Enum.map(&1, fn row -> row.id end)

    assert ids.(ChatListData.order_rows(rows, excerpts, nil, & &1.name)) ==
             ids.(ChatListData.sort_by_recency(rows, excerpts, & &1.name))

    # The snapshot names c, a, b (and a gone id); d and e are new, d newer.
    assert ids.(ChatListData.order_rows(rows, excerpts, ["c", "gone", "a", "b"], & &1.name)) ==
             ["c", "a", "b", "d", "e"]

    # Pinned entries carry the space under :space.
    entries = Enum.map(rows, &%{kind: :channel, space: &1})

    assert entries
           |> ChatListData.order_rows(excerpts, ["e", "a"], & &1.space.name)
           |> Enum.map(& &1.space.id) == ["e", "a", "d", "b", "c"]
  end
end

defmodule PlatformWeb.ChatLive.ChatListDataIdentitiesTest do
  @moduledoc """
  `ChatListData.load_identities/1`'s `human` entry (task 01a18940 stage 2):
  the other person of a one-to-one DM, by the message flow's rule
  (`PresenceHooks.participant_identity/3`): the participant row's
  `avatar_url`, else the user's, else no image. Needs the database, so it
  sits beside the pure order tests in its own module.
  """

  use Platform.DataCase, async: true

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo
  alias PlatformWeb.ChatLive.ChatListData

  defp user!(avatar_url) do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{
      email: "list-human-#{n}@example.com",
      name: "Person #{n}",
      oidc_sub: "list-human-#{n}",
      avatar_url: avatar_url
    })
    |> Repo.insert!()
  end

  defp join!(space, user_id, attrs \\ %{}) do
    {:ok, p} =
      Chat.add_participant(
        space.id,
        Map.merge(
          %{
            participant_type: "user",
            participant_id: user_id,
            display_name: "Someone",
            joined_at: DateTime.utc_now()
          },
          attrs
        )
      )

    p
  end

  # A DM between `viewer` and `other_id`, the other row carrying `own_url`.
  defp dm!(viewer, other_id, own_url) do
    {:ok, space} = Chat.create_space(%{kind: "dm", is_direct: true})
    _ = join!(space, viewer.id)
    _ = join!(space, other_id, %{avatar_url: own_url})
    space
  end

  defp identities(viewer, spaces) do
    ChatListData.load_identities(%{user_id: viewer.id, dm_conversations: spaces})
  end

  test "the other person's image: participant first, then the user, never the viewer's" do
    viewer = user!("/viewer.png")
    other = user!("/other-user.png")

    overridden = dm!(viewer, other.id, "/participant-override.png")
    fallback = dm!(viewer, other.id, nil)
    blank = dm!(viewer, other.id, "  ")

    ids = identities(viewer, [overridden, fallback, blank])

    assert ids[overridden.id].human == %{avatar_url: "/participant-override.png"}
    assert ids[fallback.id].human == %{avatar_url: "/other-user.png"}
    # A blank participant URL is no URL, so the user's answers.
    assert ids[blank.id].human == %{avatar_url: "/other-user.png"}

    for space <- [overridden, fallback, blank], do: assert(ids[space.id].agent == nil)
  end

  test "no image anywhere, or no user row at all, is no human image" do
    viewer = user!("/viewer.png")
    plain = user!(nil)

    none = dm!(viewer, plain.id, nil)
    ghost = dm!(viewer, Ecto.UUID.generate(), nil)

    ids = identities(viewer, [none, ghost])

    assert ids[none.id].human == nil
    assert ids[ghost.id].human == nil
    # Positive control: the same viewer's DM with an imaged user resolves.
    imaged = dm!(viewer, user!("/imaged.png").id, nil)
    assert identities(viewer, [imaged])[imaged.id].human == %{avatar_url: "/imaged.png"}
  end

  test "a group never carries a human image" do
    viewer = user!("/viewer.png")
    {:ok, group} = Chat.create_space(%{kind: "group"})
    _ = join!(group, viewer.id)
    _ = join!(group, user!("/other.png").id)

    assert identities(viewer, [group])[group.id].human == nil
  end

  test "users are read in ONE query for the whole list, not one per row" do
    viewer = user!("/viewer.png")
    spaces = for n <- 1..4, do: dm!(viewer, user!("/u#{n}.png").id, nil)

    test_pid = self()
    handler = "list-human-users-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:platform, :repo, :query],
        fn _event, _measurements, meta, _config ->
          if self() == test_pid and meta[:source] == "users",
            do: send(test_pid, {:users_query, handler})
        end,
        nil
      )

    ids =
      try do
        identities(viewer, spaces)
      after
        :telemetry.detach(handler)
      end

    assert Enum.map(spaces, &ids[&1.id].human.avatar_url) ==
             ["/u1.png", "/u2.png", "/u3.png", "/u4.png"]

    assert_received {:users_query, ^handler}
    refute_received {:users_query, ^handler}
  end
end
