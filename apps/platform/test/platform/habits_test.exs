defmodule Platform.HabitsTest do
  @moduledoc """
  Task 01a1b6a1 stage 2 (`0061-learned-defaults.md`): the `Platform.Habits`
  substrate — record, suggest, the trust ladder, decay, opt-out, Settings,
  retention and the emission seam.
  """

  use Platform.DataCase, async: true

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Experiments.SurfaceDefault
  alias Platform.Habits
  alias Platform.Habits.Pattern
  alias Platform.Habits.Signal
  alias Platform.Habits.TelemetryHandler
  alias Platform.Repo

  @action "chat.message_attention"

  setup do
    unique = System.unique_integer([:positive])

    {:ok, room_x} =
      Chat.create_space(%{name: "room-x #{unique}", slug: "room-x-#{unique}", kind: "channel"})

    {:ok, room_y} =
      Chat.create_space(%{name: "room-y #{unique}", slug: "room-y-#{unique}", kind: "channel"})

    %{
      one: user!("Member One", unique),
      two: user!("Member Two", unique),
      three: user!("Member Three", unique),
      agent: %{target_type: "agent", target_id: Ecto.UUID.generate()},
      room_x: room_x,
      room_y: room_y
    }
  end

  defp user!(name, unique) do
    slug = name |> String.downcase() |> String.replace(" ", "-")

    Repo.insert!(%User{
      email: "#{slug}-#{unique}@example.com",
      name: name,
      oidc_sub: "oidc-#{slug}-#{unique}"
    })
  end

  defp human(%User{id: id}), do: %{target_type: "user", target_id: id}

  defp record!(actor, space, target, outcome, rung, n \\ 1) do
    for _ <- 1..n do
      {:ok, %Signal{}} =
        Habits.record(%{
          actor_user_id: actor.id,
          space_id: space && space.id,
          action: @action,
          target_type: target.target_type,
          target_id: target.target_id,
          outcome: outcome,
          rung: rung
        })
    end
  end

  defp promote_default!(payload) do
    Repo.insert!(
      SurfaceDefault.changeset(%SurfaceDefault{}, %{
        surface_key: "habits.learned_defaults",
        surface_target: @action,
        seq: 1,
        kind: "promote",
        payload: payload
      })
    )
  end

  defp target_ids(%{ranked: ranked}), do: Enum.map(ranked, & &1.target_id)

  describe "isolation" do
    test "learning stays inside one user and one room", ctx do
      record!(ctx.one, ctx.room_x, human(ctx.two), "accepted", "rank", 4)

      assert [first | _] = Habits.suggest(ctx.one.id, ctx.room_x.id, @action).ranked
      assert first.target_id == ctx.two.id

      assert Habits.suggest(ctx.one.id, ctx.room_y.id, @action).ranked == [],
             "Member One's room-x habit leaked into room-y"

      assert Habits.suggest(ctx.three.id, ctx.room_x.id, @action).ranked == [],
             "Member One's habit leaked to Member Three"

      assert Habits.suggest(ctx.one.id, nil, @action).ranked == [],
             "a nil space must mean org-level only, never any room"
    end
  end

  describe "prefill" do
    test "appears at min_signals and is absent one signal below", ctx do
      record!(ctx.one, ctx.room_x, human(ctx.two), "chosen", "rank", 2)
      s = Habits.suggest(ctx.one.id, ctx.room_x.id, @action)
      assert target_ids(s) == [ctx.two.id]
      assert s.prefill == nil

      record!(ctx.one, ctx.room_x, human(ctx.two), "chosen", "rank")
      assert Habits.suggest(ctx.one.id, ctx.room_x.id, @action).prefill == human(ctx.two)
    end

    test "appears at confidence == threshold; a data row moves the boundary", ctx do
      # 3 of 5 = 0.6 confidence, the control threshold.
      record!(ctx.one, ctx.room_x, human(ctx.two), "chosen", "rank", 3)
      record!(ctx.one, ctx.room_x, human(ctx.three), "chosen", "rank", 2)

      s = Habits.suggest(ctx.one.id, ctx.room_x.id, @action)
      assert s.variant["prefill_threshold"] == 0.6
      assert s.prefill == human(ctx.two)

      promote_default!(%{"prefill_threshold" => 0.7})

      s = Habits.suggest(ctx.one.id, ctx.room_x.id, @action)
      assert s.variant["prefill_threshold"] == 0.7
      assert s.prefill == nil
      assert target_ids(s) == [ctx.two.id, ctx.three.id]
    end

    test "overridden weight is subtracted from the score", ctx do
      record!(ctx.one, ctx.room_x, human(ctx.two), "chosen", "rank", 3)
      record!(ctx.one, ctx.room_x, human(ctx.two), "overridden", "prefill", 3)

      assert Habits.suggest(ctx.one.id, ctx.room_x.id, @action) |> target_ids() == []
    end
  end

  describe "act" do
    test "appears only after act_after_accepts accepted prefills", ctx do
      record!(ctx.one, ctx.room_x, human(ctx.two), "accepted", "prefill", 4)
      s = Habits.suggest(ctx.one.id, ctx.room_x.id, @action)
      assert s.prefill == human(ctx.two)
      assert s.act == nil

      record!(ctx.one, ctx.room_x, human(ctx.two), "accepted", "prefill")
      assert Habits.suggest(ctx.one.id, ctx.room_x.id, @action).act == human(ctx.two)
    end

    test "never for an agent target", ctx do
      record!(ctx.one, ctx.room_x, ctx.agent, "accepted", "prefill", 8)
      s = Habits.suggest(ctx.one.id, ctx.room_x.id, @action)
      assert s.prefill == ctx.agent
      assert s.act == nil, "an agent target acted: a wake cannot be undone"
    end

    test "an undo drops the pattern to prefill and resets the count", ctx do
      record!(ctx.one, ctx.room_x, human(ctx.two), "accepted", "prefill", 5)
      record!(ctx.one, ctx.room_x, human(ctx.two), "accepted", "act")
      assert %Pattern{rung: "act", accepted_prefills: 5} = Repo.one!(Pattern)

      record!(ctx.one, ctx.room_x, human(ctx.two), "overridden", "act")
      assert %Pattern{rung: "prefill", accepted_prefills: 0} = Repo.one!(Pattern)
      assert Habits.suggest(ctx.one.id, ctx.room_x.id, @action).act == nil
    end

    test "never after stop/4, which still ranks", ctx do
      record!(ctx.one, ctx.room_x, human(ctx.two), "accepted", "prefill", 6)
      assert Habits.suggest(ctx.one.id, ctx.room_x.id, @action).act == human(ctx.two)

      assert {:ok, %Pattern{rung: "rank", stopped_at: %DateTime{}}} =
               Habits.stop(ctx.one.id, ctx.room_x.id, @action, human(ctx.two))

      assert Repo.exists?(from(s in Signal, where: s.outcome == "overridden" and s.rung == "act"))

      record!(ctx.one, ctx.room_x, human(ctx.two), "accepted", "prefill", 10)
      s = Habits.suggest(ctx.one.id, ctx.room_x.id, @action)
      assert target_ids(s) == [ctx.two.id]
      assert s.prefill == nil
      assert s.act == nil
    end
  end

  describe "decay" do
    test "a signal several half-lives old weighs a literal near-zero", ctx do
      now = DateTime.utc_now()
      old = DateTime.add(now, -300, :day)
      assert Habits.decayed_weight(old, now, 30) < 0.001
      assert_in_delta Habits.decayed_weight(now, now, 30), 1.0, 1.0e-12

      record!(ctx.one, ctx.room_x, human(ctx.two), "chosen", "rank")

      Repo.update_all(Signal,
        set: [inserted_at: DateTime.add(now, -150, :day)]
      )

      assert [%{score: score}] =
               Habits.suggest(ctx.one.id, ctx.room_x.id, @action, now: now).ranked

      assert_in_delta score, :math.pow(0.5, 5), 1.0e-6
      assert score < 0.05
    end
  end

  describe "opt-out" do
    test "record stores nothing and suggest returns empty, history kept", ctx do
      record!(ctx.one, ctx.room_x, human(ctx.two), "chosen", "rank", 3)
      assert {:ok, _} = Habits.set_enabled(ctx.one.id, false)
      refute Habits.enabled?(ctx.one.id)

      assert {:ok, :disabled} =
               Habits.record(%{
                 actor_user_id: ctx.one.id,
                 space_id: ctx.room_x.id,
                 action: @action,
                 target_type: "user",
                 target_id: ctx.two.id,
                 outcome: "chosen",
                 rung: "rank"
               })

      assert Repo.aggregate(Signal, :count) == 3, "opt-out must neither write nor delete"

      s = Habits.suggest(ctx.one.id, ctx.room_x.id, @action)
      assert s.ranked == [] and s.prefill == nil and s.act == nil

      assert {:ok, _} = Habits.set_enabled(ctx.one.id, true)
      assert Habits.suggest(ctx.one.id, ctx.room_x.id, @action).prefill == human(ctx.two)
    end
  end

  describe "Settings" do
    test "list_patterns groups the owner's patterns by space", ctx do
      record!(ctx.one, ctx.room_x, human(ctx.two), "chosen", "rank")
      record!(ctx.one, ctx.room_y, human(ctx.three), "chosen", "rank")
      record!(ctx.one, nil, human(ctx.two), "chosen", "rank")
      record!(ctx.three, ctx.room_x, human(ctx.two), "chosen", "rank")

      grouped = Habits.list_patterns(ctx.one.id)

      assert grouped |> Map.keys() |> Enum.sort_by(&to_string/1) ==
               Enum.sort_by([nil, ctx.room_x.id, ctx.room_y.id], &to_string/1)

      assert grouped |> Map.values() |> List.flatten() |> Enum.all?(&(&1.user_id == ctx.one.id))
    end

    test "forget deletes one pattern and its signals, owner only", ctx do
      record!(ctx.one, ctx.room_x, human(ctx.two), "chosen", "rank", 2)
      record!(ctx.one, ctx.room_y, human(ctx.two), "chosen", "rank")
      [pattern] = Habits.list_patterns(ctx.one.id) |> Map.fetch!(ctx.room_x.id)

      assert {:error, :not_found} = Habits.forget(ctx.three.id, pattern.id)
      assert Repo.aggregate(Signal, :count) == 3

      assert {:ok, %{signals: 2}} = Habits.forget(ctx.one.id, pattern.id)
      assert Repo.aggregate(Signal, :count) == 1
      refute Repo.get(Pattern, pattern.id)
      assert Habits.suggest(ctx.one.id, ctx.room_x.id, @action).ranked == []
    end
  end

  describe "boundary ids" do
    test "malformed ids suggest nothing and forget nothing, without raising", ctx do
      record!(ctx.one, ctx.room_x, human(ctx.two), "chosen", "rank", 3)
      [pattern] = Habits.list_patterns(ctx.one.id) |> Map.fetch!(ctx.room_x.id)

      assert Habits.suggest(ctx.one.id, "not-a-uuid", @action).ranked == []
      assert Habits.suggest("not-a-uuid", ctx.room_x.id, @action).ranked == []
      assert {:error, :not_found} = Habits.forget(ctx.one.id, "not-a-uuid")
      assert {:error, :not_found} = Habits.forget("not-a-uuid", pattern.id)
      assert Repo.aggregate(Signal, :count) == 3
    end
  end

  describe "retention" do
    test "prune_signals drops signals past 6 half-lives and keeps the pattern", ctx do
      now = DateTime.utc_now()
      record!(ctx.one, ctx.room_x, human(ctx.two), "chosen", "rank", 2)
      [a, b] = Repo.all(from(s in Signal, order_by: s.id))

      Repo.update_all(from(s in Signal, where: s.id == ^a.id),
        set: [inserted_at: DateTime.add(now, -181, :day)]
      )

      Repo.update_all(from(s in Signal, where: s.id == ^b.id),
        set: [inserted_at: DateTime.add(now, -179, :day)]
      )

      assert {:ok, 1} = Habits.prune_signals(now: now)
      assert [%Signal{id: id}] = Repo.all(Signal)
      assert id == b.id
      assert Repo.aggregate(Pattern, :count) == 1
    end
  end

  describe "emission seam" do
    test "a choice event is recorded by the boot-attached handler", ctx do
      :ok = TelemetryHandler.attach()

      :ok =
        Habits.emit_choice(%{
          actor_user_id: ctx.one.id,
          space_id: ctx.room_x.id,
          action: @action,
          target_type: "user",
          target_id: ctx.two.id,
          outcome: "chosen",
          rung: "rank",
          source_message_id: nil
        })

      assert [%Signal{actor_user_id: actor}] = Repo.all(Signal)
      assert actor == ctx.one.id
    end

    test "an invalid choice event is dropped without detaching the handler", ctx do
      :ok = TelemetryHandler.attach()
      :ok = Habits.emit_choice(%{actor_user_id: ctx.one.id, action: "nope"})
      assert Repo.aggregate(Signal, :count) == 0

      assert Enum.any?(
               :telemetry.list_handlers(Habits.choice_event()),
               &(&1.id == TelemetryHandler.handler_id())
             )
    end
  end
end
