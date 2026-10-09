defmodule Platform.Responsibilities.GoalCadenceAcceptanceTest do
  @moduledoc """
  End-to-end acceptance for the goal-heartbeat cadence (task 01a0e882
  stage 4): the admin write, the REAL `"responsibilities:changed"`
  broadcast, and a running Router's tick, with no shortcut between them.

  The row is the real `agents.goal_heartbeat`, registered through its
  provider. The write is `Responsibilities.set_goal_heartbeat_cadence/3`
  as an acme admin. The Router is never told to reload directly: it hears
  the broadcast the write emits, and `:sys.get_state/1` is the barrier.
  Time is simulated through the Router's `:now_fn` clock seam and
  `{:tick_at, t}` messages, minute by minute. No sleeps, no wall clock.

  A control row `acceptance.hourly_control` at `0 * * * *` runs in the
  same Router in every case, so every absence has a positive control from
  the same run. Counts are exact, never `>=`.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.TenancyFixtures, only: [acme_org_id: 0]

  alias Platform.Accounts.User
  alias Platform.Audit.Event
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.{Responsibility, Router}
  alias Platform.Responsibilities.Handlers.AgentsGoalHeartbeat
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  @heartbeat "agents.goal_heartbeat"
  @control "acceptance.hourly_control"
  @cron_fired [:platform, :responsibility, :cron_fired]
  @cadence_event "platform.responsibilities.cadence_changed"

  # ── fixtures ─────────────────────────────────────────────────────────────

  defp user!(role) do
    n = System.unique_integer([:positive])

    user =
      %User{}
      |> User.changeset(%{
        email: "acceptance-#{n}@example.com",
        name: "Acceptance #{n}",
        oidc_sub: "oidc-acceptance-#{n}"
      })
      |> Repo.insert!()

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: acme_org_id(), role: role})
    |> Repo.insert!()

    user
  end

  defp admin! do
    admin = user!("admin")
    assert Tenancy.root_admin?(admin)
    admin
  end

  defp member! do
    member = user!("member")
    refute Tenancy.root_admin?(member)
    member
  end

  defp start_router(start_at) do
    clock = start_supervised!({Agent, fn -> start_at end}, id: {:clock, make_ref()})
    name = Module.concat([Router, "Acceptance#{System.unique_integer([:positive])}"])

    pid =
      start_supervised!(
        {Router,
         name: name, check_interval_ms: :timer.hours(24), now_fn: fn -> Agent.get(clock, & &1) end}
      )

    :ok = Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    %{pid: pid, name: name, clock: clock}
  end

  defp set_clock(%{clock: clock}, %DateTime{} = t), do: Agent.update(clock, fn _ -> t end)

  # Minute boundaries in `(from, to]`, the clock advanced with each tick.
  defp drive(router, %DateTime{} = from, %DateTime{} = to) do
    from
    |> Stream.iterate(&DateTime.add(&1, 60, :second))
    |> Stream.drop(1)
    |> Stream.take_while(&(DateTime.compare(&1, to) != :gt))
    |> Enum.each(fn t ->
      set_clock(router, t)
      send(router.pid, {:tick_at, t})
    end)

    barrier(router)
  end

  defp barrier(%{pid: pid}), do: :sys.get_state(pid)

  # An admin write at simulated instant `at`, delivered to the Router only
  # through the write's own broadcast.
  defp write_at(router, %DateTime{} = at, actor, cadence, opts \\ []) do
    set_clock(router, at)
    result = Responsibilities.set_goal_heartbeat_cadence(actor, cadence, opts)
    barrier(router)
    result
  end

  defp fires(key), do: collect(key, [])

  defp collect(key, acc) do
    receive do
      {:cron_fired, ^key, at} -> collect(key, [at | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp hourly(from, count) do
    for i <- 1..count, do: DateTime.add(from, i * 3600, :second)
  end

  defp cadence_audits do
    Repo.aggregate(from(e in Event, where: e.event_type == @cadence_event), :count)
  end

  setup do
    {:ok, [heartbeat]} = Responsibilities.register(AgentsGoalHeartbeat)

    # Only the two rows under test are live cron rows in this sandbox.
    Repo.update_all(
      from(r in Responsibility, where: r.trigger_kind == "cron" and r.key != ^@heartbeat),
      set: [enabled: false]
    )

    {:ok, heartbeat} = Responsibilities.update_responsibility(heartbeat, %{enabled: true})
    assert heartbeat.trigger_config == %{"expression" => "0 * * * *"}

    {:ok, _control} =
      Responsibilities.create_responsibility(%{
        key: @control,
        feature: "acceptance",
        trigger_kind: "cron",
        trigger_config: %{"expression" => "0 * * * *"},
        scope: "global",
        context_provided: [],
        output_contract: %{},
        default_prompt_template: "",
        cost_profile: "low_freq_capable"
      })

    test_pid = self()
    handler_id = "cadence-acceptance-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        @cron_fired,
        fn _event, _measurements, %{key: key, fired_at: at}, _ ->
          if key in [@heartbeat, @control], do: send(test_pid, {:cron_fired, key, at})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  # ── 1. daily ─────────────────────────────────────────────────────────────

  test "1. daily@09: exactly 2 heartbeat fires in 48 h, both at 09:00 UTC; control fires 48" do
    admin = admin!()
    t0 = ~U[2030-01-07 00:00:00Z]
    router = start_router(DateTime.add(t0, 30, :second))

    assert {:ok, %Responsibility{}} =
             write_at(router, DateTime.add(t0, 30, :second), admin, :daily, hour_utc: 9)

    drive(router, t0, DateTime.add(t0, 48 * 3600, :second))

    assert fires(@heartbeat) == [~U[2030-01-07 09:00:00Z], ~U[2030-01-08 09:00:00Z]]
    assert fires(@control) == hourly(t0, 48)
    assert Process.whereis(router.name) == router.pid
  end

  # ── 2. hourly positive control ───────────────────────────────────────────

  test "2. with no admin change the heartbeat fires exactly 24 times in 24 h, one per :00" do
    t0 = ~U[2030-01-07 00:00:00Z]
    router = start_router(DateTime.add(t0, 30, :second))

    drive(router, t0, DateTime.add(t0, 24 * 3600, :second))

    assert fires(@heartbeat) == hourly(t0, 24)
    assert fires(@control) == hourly(t0, 24)
  end

  # ── 3. off ───────────────────────────────────────────────────────────────

  test "3. off: 0 heartbeat fires in 24 h while control fires 24; hourly again fires at the next :00" do
    admin = admin!()
    t0 = ~U[2030-01-07 00:00:00Z]
    router = start_router(DateTime.add(t0, 30, :second))

    assert {:ok, %Responsibility{enabled: false}} =
             write_at(router, DateTime.add(t0, 30, :second), admin, :off)

    refute Enum.any?(barrier(router).by_trigger.cron, &(&1.key == @heartbeat))

    t24 = DateTime.add(t0, 24 * 3600, :second)
    drive(router, t0, t24)

    assert fires(@heartbeat) == []
    assert fires(@control) == hourly(t0, 24)

    assert {:ok, %Responsibility{enabled: true}} =
             write_at(router, DateTime.add(t24, 30, :second), admin, :hourly)

    drive(router, t24, DateTime.add(t24, 3600, :second))

    assert fires(@heartbeat) == [DateTime.add(t24, 3600, :second)]
    assert fires(@control) == [DateTime.add(t24, 3600, :second)]
    assert Process.whereis(router.name) == router.pid
  end

  # ── 4. non-admin ─────────────────────────────────────────────────────────

  test "4. a non-admin is refused and the heartbeat stays hourly; the admin's call then changes it" do
    member = member!()
    admin = admin!()
    t0 = ~U[2030-01-07 00:00:00Z]
    router = start_router(DateTime.add(t0, 30, :second))

    assert write_at(router, DateTime.add(t0, 30, :second), member, :daily, hour_utc: 9) ==
             {:error, :forbidden}

    t24 = DateTime.add(t0, 24 * 3600, :second)
    drive(router, t0, t24)

    assert fires(@heartbeat) == hourly(t0, 24)
    assert cadence_audits() == 0

    assert {:ok, %Responsibility{}} =
             write_at(router, DateTime.add(t24, 30, :second), admin, :daily, hour_utc: 9)

    drive(router, t24, DateTime.add(t24, 24 * 3600, :second))

    assert fires(@heartbeat) == [~U[2030-01-08 09:00:00Z]]
    assert fires(@control) == hourly(t0, 48)
    assert cadence_audits() == 1
  end

  # ── 5. the switch boundary ───────────────────────────────────────────────

  test "5a. hourly fires 10:00:00, admin switches to daily@10 at 10:00:30: exactly 2 fires to 10:00 next day" do
    admin = admin!()
    router = start_router(~U[2030-01-07 09:30:00Z])

    drive(router, ~U[2030-01-07 09:30:00Z], ~U[2030-01-07 10:00:00Z])

    assert {:ok, %Responsibility{}} =
             write_at(router, ~U[2030-01-07 10:00:30Z], admin, :daily, hour_utc: 10)

    drive(router, ~U[2030-01-07 10:00:00Z], ~U[2030-01-08 10:00:00Z])

    assert fires(@heartbeat) == [~U[2030-01-07 10:00:00Z], ~U[2030-01-08 10:00:00Z]]
    assert length(fires(@control)) == 25
    assert Process.whereis(router.name) == router.pid
  end

  test "5b. daily@10 switched to hourly at 09:59:30 fires exactly once at 10:00" do
    admin = admin!()
    router = start_router(~U[2030-01-07 09:00:30Z])

    assert {:ok, %Responsibility{}} =
             write_at(router, ~U[2030-01-07 09:00:30Z], admin, :daily, hour_utc: 10)

    drive(router, ~U[2030-01-07 09:00:00Z], ~U[2030-01-07 09:59:00Z])
    assert fires(@heartbeat) == []

    assert {:ok, %Responsibility{}} =
             write_at(router, ~U[2030-01-07 09:59:30Z], admin, :hourly)

    drive(router, ~U[2030-01-07 09:59:00Z], ~U[2030-01-07 10:59:00Z])

    assert fires(@heartbeat) == [~U[2030-01-07 10:00:00Z]]
    assert fires(@control) == [~U[2030-01-07 10:00:00Z]]
    assert Process.whereis(router.name) == router.pid
  end

  # ── 6. redeploy mid-run ──────────────────────────────────────────────────

  test "6. daily survives a boot re-registration mid-run: 2 fires in 48 h" do
    admin = admin!()
    t0 = ~U[2030-01-07 00:00:00Z]
    router = start_router(DateTime.add(t0, 30, :second))

    assert {:ok, %Responsibility{}} =
             write_at(router, DateTime.add(t0, 30, :second), admin, :daily, hour_utc: 9)

    # The boot path, then the broadcast a redeployed node's writers would send.
    assert {:ok, [_]} = Responsibilities.register(AgentsGoalHeartbeat)

    :ok =
      Phoenix.PubSub.broadcast(
        Platform.PubSub,
        Router.changed_topic(),
        {:responsibilities_changed, :cron}
      )

    barrier(router)

    assert Responsibilities.get_by_key(@heartbeat).trigger_config["expression"] == "0 9 * * *"

    drive(router, t0, DateTime.add(t0, 48 * 3600, :second))

    assert fires(@heartbeat) == [~U[2030-01-07 09:00:00Z], ~U[2030-01-08 09:00:00Z]]
    assert fires(@control) == hourly(t0, 48)
  end
end
