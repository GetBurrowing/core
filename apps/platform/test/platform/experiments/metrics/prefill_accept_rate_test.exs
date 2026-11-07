defmodule Platform.Experiments.Metrics.PrefillAcceptRateTest do
  @moduledoc """
  Task 01a1b6a1 stage 1: `habits.prefill_accept_rate`. Literal results only
  (ADR 0052 rule 7, the anti-vacuity rule).
  """

  use Platform.DataCase, async: true

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Experiments.Assignment
  alias Platform.Experiments.Experiment
  alias Platform.Experiments.Metric.Result
  alias Platform.Experiments.Metrics.PrefillAcceptRate
  alias Platform.Habits.Signal
  alias Platform.Repo

  setup do
    unique = System.unique_integer([:positive])

    {:ok, room} =
      Chat.create_space(%{name: "room-x #{unique}", slug: "room-x-#{unique}", kind: "channel"})

    experiment =
      Repo.insert!(%Experiment{
        slug: "learned-defaults-#{unique}",
        name: "learned defaults #{unique}",
        surface_key: "habits.learned_defaults",
        surface_target: "chat.message_attention",
        status: "running",
        primary_metric: "habits.prefill_accept_rate"
      })

    %{room: room, experiment: experiment, unique: unique}
  end

  defp user(ctx, name) do
    slug = name |> String.downcase() |> String.replace(" ", "-")

    Repo.insert!(%User{
      email: "#{slug}-#{ctx.unique}@example.com",
      name: name,
      oidc_sub: "oidc-#{slug}-#{ctx.unique}"
    })
  end

  defp assign(ctx, user, variant, opts \\ []) do
    Repo.insert!(%Assignment{
      experiment_id: ctx.experiment.id,
      subject_type: "user",
      subject_id: user.id,
      variant_slug: variant,
      assigned_at: Keyword.get(opts, :at, ~U[2026-01-01 00:00:00.000000Z]),
      excluded_reason: Keyword.get(opts, :excluded)
    })
  end

  defp signals(ctx, user, outcome, count, opts \\ []) do
    for _ <- 1..count do
      %Signal{}
      |> Signal.changeset(%{
        actor_user_id: user.id,
        space_id: ctx.room.id,
        action: Keyword.get(opts, :action, "chat.message_attention"),
        target_type: "user",
        target_id: Ecto.UUID.generate(),
        outcome: outcome,
        rung: Keyword.get(opts, :rung, "prefill")
      })
      |> Repo.insert!()
    end
  end

  test "an arm with no assigned users is :insufficient_data", ctx do
    assert PrefillAcceptRate.compute(ctx.experiment.id, "control") == :insufficient_data
  end

  test "assigned users with no judged pre-fill are pending, never 0.0", ctx do
    one = user(ctx, "Member One")
    two = user(ctx, "Member Two")
    assign(ctx, one, "control")
    assign(ctx, two, "control")
    # Ignored pre-fills and chosen picks are not judgements.
    signals(ctx, one, "ignored", 3)
    signals(ctx, two, "chosen", 2, rung: "none")

    assert PrefillAcceptRate.compute(ctx.experiment.id, "control") ==
             {:insufficient_data, %{pending: 2}}
  end

  test "accepted / (accepted + overridden), ignored in neither side", ctx do
    one = user(ctx, "Member One")
    two = user(ctx, "Member Two")
    three = user(ctx, "Member Three")
    assign(ctx, one, "control")
    assign(ctx, two, "control")
    assign(ctx, three, "control")

    signals(ctx, one, "accepted", 3)
    signals(ctx, one, "overridden", 1)
    signals(ctx, one, "ignored", 4)
    signals(ctx, two, "accepted", 1)
    # Not at rung prefill, or not this action: not counted.
    signals(ctx, two, "overridden", 2, rung: "act")
    signals(ctx, two, "accepted", 5, rung: "rank")
    signals(ctx, two, "overridden", 3, action: "chat.mention", rung: "none")

    assert {:ok, %Result{value: 0.8, n: 5, unit: :ratio, pending: 1}} =
             PrefillAcceptRate.compute(ctx.experiment.id, "control")
  end

  test "only the arm's own, non-excluded users count", ctx do
    one = user(ctx, "Member One")
    two = user(ctx, "Member Two")
    three = user(ctx, "Member Three")
    assign(ctx, one, "control")
    assign(ctx, two, "treatment")
    assign(ctx, three, "control", excluded: "opted_out")

    signals(ctx, one, "overridden", 1)
    signals(ctx, one, "accepted", 1)
    signals(ctx, two, "accepted", 6)
    signals(ctx, three, "accepted", 6)

    assert {:ok, %Result{value: 0.5, n: 2, pending: 0}} =
             PrefillAcceptRate.compute(ctx.experiment.id, "control")

    assert {:ok, %Result{value: 1.0, n: 6, pending: 0}} =
             PrefillAcceptRate.compute(ctx.experiment.id, "treatment")
  end

  test "signals before the user's assignment are not counted", ctx do
    one = user(ctx, "Member One")
    signals(ctx, one, "overridden", 2)
    assign(ctx, one, "control", at: DateTime.add(DateTime.utc_now(), 3600, :second))

    assert PrefillAcceptRate.compute(ctx.experiment.id, "control") ==
             {:insufficient_data, %{pending: 1}}
  end
end
