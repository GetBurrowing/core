defmodule Platform.Experiments.Surfaces.UnblockAskReaskIntervalTest do
  @moduledoc "Task 01a1b6de stage 4: the `agents.unblock_ask.reask_interval` surface."

  use Platform.DataCase, async: true

  alias Platform.Agents.UnblockAsk
  alias Platform.Experiments
  alias Platform.Experiments.Assignment
  alias Platform.Experiments.Metric.Result
  alias Platform.Experiments.Metrics
  alias Platform.Experiments.Metrics.UnblockAsksResolvedPerSent
  alias Platform.Experiments.Surfaces
  alias Platform.Experiments.Surfaces.UnblockAskReaskInterval, as: S

  test "is registered with its key, subject, path and one target" do
    assert Surfaces.get("agents.unblock_ask.reask_interval") == S
    assert S.subject_type() == "unblock_subject"
    assert S.path() == :dispatch
    assert S.targets() == ["agents.unblock_ask.reask_interval"]
    assert {:ok, _} = Jason.encode(S.payload_schema())
  end

  test "its metric is registered" do
    assert S.metric() in Metrics.known_metrics()
    assert Metrics.metric_module(S.metric()) == UnblockAsksResolvedPerSent
  end

  test "the control is the configured interval" do
    assert {:ok, %{"reask_after_hours" => 72}} = S.control_payload(S.target())
  end

  test "validate_payload takes the candidates and refuses the rest" do
    assert {:ok, %{"reask_after_hours" => 24}} = S.validate_payload(%{reask_after_hours: 24})
    assert {:ok, %{"reask_after_hours" => 72}} = S.validate_payload(%{"reask_after_hours" => 72})
    assert {:error, [_]} = S.validate_payload(%{"reask_after_hours" => 0})
    assert {:error, [_]} = S.validate_payload(%{"reask_after_hours" => 721})
    assert {:error, [_]} = S.validate_payload(%{"reask_after_hours" => "24"})
    assert {:error, [_]} = S.validate_payload(%{})
    assert {:error, [_, _]} = S.validate_payload(%{"reask_after_hours" => 0, "x" => 1})
    assert {:error, _} = S.validate_payload(:nope)
  end

  describe "asks resolved per sent" do
    setup do
      n = System.unique_integer([:positive])
      {:ok, experiment} = Experiments.create_experiment(%{slug: "ua-m-#{n}", name: "M"})
      {:ok, _} = Experiments.add_variant(experiment, %{slug: "short", content: "s", weight: 1})

      owner =
        Repo.insert!(%Platform.Accounts.User{
          email: "ua-m-#{n}@example.com",
          name: "Owner#{n}",
          oidc_sub: "ua-m-#{n}"
        })

      %{experiment: experiment, owner: owner}
    end

    defp ask!(owner, variant, status, sends) do
      Repo.insert!(%UnblockAsk{
        subject_type: "agent",
        subject_id: Ecto.UUID.generate(),
        class: "access",
        state_fingerprint: "fp",
        owner_user_id: owner.id,
        status: status,
        variant: variant,
        ask_count: sends,
        asked_at: DateTime.utc_now(),
        last_asked_at: DateTime.utc_now()
      })
    end

    defp assign!(experiment, ask, variant, excluded \\ nil) do
      Repo.insert!(%Assignment{
        experiment_id: experiment.id,
        subject_type: "unblock_subject",
        subject_id: ask.subject_id,
        variant_slug: variant,
        assigned_at: DateTime.utc_now(),
        excluded_reason: excluded
      })
    end

    test "no ask is insufficient data, not zero", %{experiment: e} do
      assert UnblockAsksResolvedPerSent.compute(e.id, "short") == :insufficient_data
    end

    test "resolved asks over every send, first asks and re-asks", %{experiment: e, owner: o} do
      assign!(e, ask!(o, "short", "resolved", 1), "short")
      assign!(e, ask!(o, "short", "open", 3), "short")
      # Another arm's ask, an excluded subject, and an unassigned ask do not count.
      assign!(e, ask!(o, "long", "resolved", 1), "long")
      assign!(e, ask!(o, "short", "resolved", 1), "short", "opted_out")
      ask!(o, "short", "resolved", 1)

      assert {:ok, %Result{value: 0.25, n: 4, unit: :ratio}} =
               UnblockAsksResolvedPerSent.compute(e.id, "short")
    end
  end
end
