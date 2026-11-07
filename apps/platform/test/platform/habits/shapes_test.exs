defmodule Platform.Habits.ShapesTest do
  @moduledoc """
  Task 01a1b6a1 stage 2 (`0061-learned-defaults.md` § 9, Shape contract):
  `Platform.Habits.Shapes.aggregate/0`.
  """

  use Platform.DataCase, async: true

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Habits
  alias Platform.Habits.Shapes
  alias Platform.Repo

  @action "chat.message_attention"
  @uuid ~r/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i

  setup do
    unique = System.unique_integer([:positive])

    {:ok, room} =
      Chat.create_space(%{name: "room-x #{unique}", slug: "room-x-#{unique}", kind: "channel"})

    target = user!("Member Two", unique)
    %{unique: unique, room: room, target: target}
  end

  defp user!(name, unique) do
    slug = name |> String.downcase() |> String.replace(" ", "-")

    Repo.insert!(%User{
      email: "#{slug}-#{unique}@example.com",
      name: name,
      oidc_sub: "oidc-#{slug}-#{unique}"
    })
  end

  defp members!(ctx, prefix, n, outcome) do
    for i <- 1..n do
      member = user!("Member #{prefix} #{i}", ctx.unique)

      {:ok, _} =
        Habits.record(%{
          actor_user_id: member.id,
          space_id: ctx.room.id,
          action: @action,
          target_type: "user",
          target_id: ctx.target.id,
          outcome: outcome,
          rung: "rank",
          source_message_id: Ecto.UUID.generate()
        })

      member
    end
  end

  test "a bucket under 5 distinct users is suppressed", ctx do
    members!(ctx, "Accepting", 5, "accepted")
    members!(ctx, "Overriding", 4, "overridden")

    assert [shape] = Shapes.aggregate()

    assert shape == %{
             action: @action,
             rung: "rank",
             signal_count_bucket: "0-9",
             accept_rate_bucket: 1.0,
             variant: Platform.Experiments.Surfaces.LearnedDefaults.control(),
             user_count: 5
           }

    assert shape |> Map.keys() |> Enum.sort() == Enum.sort(Shapes.keys())
  end

  test "opted-out users are excluded, which can drop a bucket below the floor", ctx do
    [first | _] = members!(ctx, "Accepting", 5, "accepted")
    assert [_] = Shapes.aggregate()

    {:ok, _} = Habits.set_enabled(first.id, false)
    assert Shapes.aggregate() == []
  end

  test "the encoded result carries no UUID and no fixture name (sentinel scan)", ctx do
    members!(ctx, "Accepting", 6, "accepted")
    members!(ctx, "Choosing", 5, "chosen")

    shapes = Shapes.aggregate()
    assert length(shapes) == 2
    encoded = Jason.encode!(shapes)

    refute encoded =~ @uuid
    refute encoded =~ "Member"
    refute encoded =~ "room-x"
    refute encoded =~ "example.com"
    refute encoded =~ ctx.room.id
    refute encoded =~ ctx.target.id
  end

  test "count and rate buckets" do
    assert Shapes.count_bucket(0) == "0-9"
    assert Shapes.count_bucket(9) == "0-9"
    assert Shapes.count_bucket(10) == "10-49"
    assert Shapes.count_bucket(49) == "10-49"
    assert Shapes.count_bucket(50) == "50+"
    assert Shapes.rate_bucket(0, 0) == nil
    assert Shapes.rate_bucket(7, 3) == 0.7
    assert Shapes.rate_bucket(2, 1) == 0.6
    assert Shapes.rate_bucket(3, 0) == 1.0
  end
end
