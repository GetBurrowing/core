defmodule Platform.Habits.StoreTest do
  @moduledoc """
  Task 01a1b6a1 stage 1 (`0061-learned-defaults.md` § 1, § 2): the
  `habit_signals` / `habit_patterns` tables, their constraints, the schemas'
  changesets and the action registry.
  """

  use Platform.DataCase, async: true

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Habits.Actions
  alias Platform.Habits.Pattern
  alias Platform.Habits.Signal
  alias Platform.Repo

  setup do
    unique = System.unique_integer([:positive])

    member_one =
      Repo.insert!(%User{
        email: "member-one-#{unique}@example.com",
        name: "Member One",
        oidc_sub: "oidc-member-one-#{unique}"
      })

    {:ok, room} =
      Chat.create_space(%{name: "room-x #{unique}", slug: "room-x-#{unique}", kind: "channel"})

    %{member_one: member_one, room: room, target_id: Ecto.UUID.generate()}
  end

  defp signal_attrs(ctx, overrides \\ %{}) do
    Map.merge(
      %{
        actor_user_id: ctx.member_one.id,
        space_id: ctx.room.id,
        action: "chat.message_attention",
        target_type: "user",
        target_id: ctx.target_id,
        outcome: "accepted",
        rung: "prefill"
      },
      overrides
    )
  end

  defp pattern_attrs(ctx, overrides) do
    Map.merge(
      %{
        user_id: ctx.member_one.id,
        space_id: nil,
        action: "chat.message_attention",
        target_type: "user",
        target_id: ctx.target_id
      },
      overrides
    )
  end

  describe "habit_signals" do
    test "a valid signal inserts", ctx do
      assert {:ok, %Signal{outcome: "accepted", rung: "prefill"}} =
               %Signal{} |> Signal.changeset(signal_attrs(ctx)) |> Repo.insert()
    end

    test "the CHECK constraint rejects an unknown outcome, below the changeset", ctx do
      row =
        ctx
        |> signal_attrs(%{outcome: "liked"})
        |> Map.merge(%{
          id: Ecto.UUID.generate(),
          actor_user_id: Ecto.UUID.dump!(ctx.member_one.id),
          space_id: Ecto.UUID.dump!(ctx.room.id),
          target_id: Ecto.UUID.dump!(ctx.target_id),
          inserted_at: DateTime.utc_now()
        })
        |> Map.update!(:id, &Ecto.UUID.dump!/1)

      error = assert_raise Postgrex.Error, fn -> Repo.insert_all("habit_signals", [row]) end
      assert error.postgres.constraint == "habit_signals_outcome_check"
    end

    test "the CHECK constraint rejects an unknown rung", ctx do
      changeset =
        %Signal{}
        |> Ecto.Changeset.change(signal_attrs(ctx, %{rung: "autopilot"}))
        |> Ecto.Changeset.check_constraint(:rung, name: :habit_signals_rung_check)

      assert {:error, changeset} = Repo.insert(changeset)

      assert {"is invalid", [constraint: :check, constraint_name: "habit_signals_rung_check"]} =
               changeset.errors[:rung]
    end

    test "the changeset refuses an unknown outcome and an unregistered action", ctx do
      changeset = Signal.changeset(%Signal{}, signal_attrs(ctx, %{outcome: "liked"}))
      assert {"is invalid", _} = changeset.errors[:outcome]

      changeset = Signal.changeset(%Signal{}, signal_attrs(ctx, %{action: "chat.react"}))
      assert changeset.errors[:action] == {"is not a registered action", []}
    end

    test "space_id may be nil for an org-level action", ctx do
      assert {:ok, %Signal{space_id: nil}} =
               %Signal{}
               |> Signal.changeset(
                 signal_attrs(ctx, %{space_id: nil, action: "chat.dm_target", outcome: "chosen"})
               )
               |> Repo.insert()
    end
  end

  describe "habit_patterns" do
    test "the unique index holds for space_id NULL: two inserts collide", ctx do
      assert {:ok, %Pattern{space_id: nil}} =
               %Pattern{} |> Pattern.changeset(pattern_attrs(ctx, %{})) |> Repo.insert()

      assert {:error, changeset} =
               %Pattern{} |> Pattern.changeset(pattern_attrs(ctx, %{})) |> Repo.insert()

      assert {"has already been taken",
              [constraint: :unique, constraint_name: "habit_patterns_tuple_index"]} =
               changeset.errors[:user_id]

      assert Repo.aggregate(
               from(p in Pattern, where: p.user_id == ^ctx.member_one.id and is_nil(p.space_id)),
               :count
             ) == 1
    end

    test "the unique index also holds for a real space", ctx do
      attrs = pattern_attrs(ctx, %{space_id: ctx.room.id})
      assert {:ok, _} = %Pattern{} |> Pattern.changeset(attrs) |> Repo.insert()
      assert {:error, _} = %Pattern{} |> Pattern.changeset(attrs) |> Repo.insert()
    end

    test "defaults to rung rank with zero accepted pre-fills", ctx do
      assert {:ok, %Pattern{rung: "rank", accepted_prefills: 0, stopped_at: nil}} =
               %Pattern{} |> Pattern.changeset(pattern_attrs(ctx, %{})) |> Repo.insert()
    end

    test "an agent target cannot sit at rung act", ctx do
      changeset =
        Pattern.changeset(%Pattern{}, pattern_attrs(ctx, %{target_type: "agent", rung: "act"}))

      assert changeset.errors[:rung] == {"exceeds the max rung for this action and target", []}

      assert Pattern.changeset(
               %Pattern{},
               pattern_attrs(ctx, %{target_type: "agent", rung: "prefill"})
             ).valid?

      assert Pattern.changeset(%Pattern{}, pattern_attrs(ctx, %{rung: "act"})).valid?
    end

    test "a capture-only action holds no pattern", ctx do
      changeset = Pattern.changeset(%Pattern{}, pattern_attrs(ctx, %{action: "chat.mention"}))
      assert changeset.errors[:rung] == {"exceeds the max rung for this action and target", []}
    end
  end

  describe "Platform.Habits.Actions" do
    test "registers one consumer and four capture-only keys" do
      assert Actions.keys() == [
               "chat.channel_route",
               "chat.dm_target",
               "chat.mention",
               "chat.message_attention",
               "tasks.assign_agent"
             ]

      assert Actions.consumer_keys() == ["chat.message_attention"]
      assert Actions.max_rung("chat.message_attention") == :act

      for key <- ~w(chat.mention chat.dm_target chat.channel_route tasks.assign_agent) do
        assert Actions.max_rung(key) == :none
      end

      assert Actions.max_rung("chat.react") == nil
    end

    test "attention is reversible for a human target only" do
      assert Actions.reversible?("chat.message_attention", %{target_type: "user"})
      refute Actions.reversible?("chat.message_attention", %{target_type: "agent"})
      refute Actions.reversible?("chat.mention", %{target_type: "user"})
      refute Actions.reversible?("chat.react", %{target_type: "user"})

      assert Actions.max_rung_for("chat.message_attention", %{target_type: "user"}) == :act
      assert Actions.max_rung_for("chat.message_attention", %{target_type: "agent"}) == :prefill
    end
  end
end
