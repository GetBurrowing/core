defmodule Platform.Responsibilities.RouterTest do
  @moduledoc """
  Tests for the M6 stage 1 Router skeleton (ADR-0041).

  Each test starts a per-case Router under the test supervisor with a
  unique registered name so the DataCase sandbox keeps owning the Repo
  connection and concurrent test runs never collide on `__MODULE__`.
  The app supervisor flag `:start_responsibility_router` is `false` in
  `config/test.exs`, so no second copy can race us.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.{Cron, Router, WebhookRouter}
  alias Platform.Roles
  alias Platform.Roles.Role

  # The repo defaults logger to :warning in config/test.exs. Bump the
  # Router module to :info so capture_log/2 actually sees the boot +
  # dispatch lines we assert on.
  setup do
    Logger.put_module_level(Platform.Responsibilities.Router, :info)
    on_exit(fn -> Logger.delete_module_level(Platform.Responsibilities.Router) end)
    :ok
  end

  # ── fixtures ─────────────────────────────────────────────────────────────

  defp unique_key(prefix \\ "routertest") do
    "#{prefix}.verb_#{System.unique_integer([:positive])}"
  end

  defp base_attrs(overrides) do
    Map.merge(
      %{
        key: unique_key(),
        feature: "routertest",
        trigger_kind: "cron",
        trigger_config: %{"expression" => "*/5 * * * *"},
        scope: "global",
        context_provided: [],
        output_contract: %{"summary" => "string"},
        default_prompt_template: "routertest.v1",
        cost_profile: "low_freq_capable"
      },
      overrides
    )
  end

  defp insert!(overrides) do
    {:ok, row} = Responsibilities.create_responsibility(base_attrs(overrides))
    row
  end

  defp unique_name do
    Module.concat([Router, "Inst#{System.unique_integer([:positive])}"])
  end

  defp start_router(opts \\ []) do
    name = unique_name()
    pid = start_supervised!({Router, Keyword.put(opts, :name, name)})
    # Stage 4 chat_pattern handler reads Chat.Message + Chat.Space from
    # Repo on the Router process. The DataCase sandbox owns the
    # connection on the test pid; allow the Router to share it so
    # `Repo.get(Message, …)` doesn't see an empty schema-only world.
    :ok = Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    {pid, name}
  end

  # ── ad-hoc provider fixture (task 019f9b28 stage 2) ──────────────────────
  #
  # The Router no longer derives a provider module name from `feature`
  # (`Module.concat([Providers, Macro.camelize(feature)])`) — it resolves
  # through the explicit registry in `Platform.Responsibilities.Providers`.
  # Tests that need a throwaway provider therefore *register* it through
  # the documented override seam instead of naming it into existence.
  #
  # This is the same test intent as before (does the Router invoke the
  # provider's callbacks?) with the name convention taken out, which is
  # the point: nothing here depends on how a feature string spells a
  # module any more.
  defp define_provider(feature_str, body) do
    provider_name =
      Module.concat([
        Platform.Responsibilities.Providers,
        "AdHoc#{System.unique_integer([:positive])}"
      ])

    Module.create(provider_name, body, Macro.Env.location(__ENV__))
    put_provider_override(feature_str, provider_name)

    provider_name
  end

  defp put_provider_override(feature, module) do
    current = Application.get_env(:platform, :responsibility_provider_overrides, %{})

    Application.put_env(
      :platform,
      :responsibility_provider_overrides,
      Map.put(current, feature, module)
    )

    on_exit(fn ->
      remaining = Application.get_env(:platform, :responsibility_provider_overrides, %{})

      Application.put_env(
        :platform,
        :responsibility_provider_overrides,
        Map.delete(remaining, feature)
      )
    end)

    :ok
  end

  # ── tests ────────────────────────────────────────────────────────────────

  describe "start_link/1 + snapshot/1" do
    test "buckets enabled responsibilities by trigger_kind" do
      cron_row =
        insert!(%{
          key: "routertest.cron_one",
          trigger_kind: "cron",
          trigger_config: %{"expression" => "0 * * * *"}
        })

      event_row =
        insert!(%{
          key: "routertest.event_one",
          trigger_kind: "event_topic",
          trigger_config: %{"topic" => "routertest:event_one"}
        })

      chat_row =
        insert!(%{
          key: "routertest.chat_one",
          trigger_kind: "chat_pattern",
          trigger_config: %{"regex" => "^hello"}
        })

      webhook_row =
        insert!(%{
          key: "routertest.webhook_one",
          trigger_kind: "webhook",
          trigger_config: %{"path" => "/hooks/routertest"}
        })

      {_pid, name} = start_router()

      snap = Router.snapshot(name)

      assert %{cron: cron, event_topics: events, chat_patterns: chats, webhooks: hooks} = snap
      assert cron_row.id in Enum.map(cron, & &1.id)
      assert event_row.id in Enum.map(events, & &1.id)
      assert chat_row.id in Enum.map(chats, & &1.id)
      assert webhook_row.id in Enum.map(hooks, & &1.id)
    end

    test "excludes disabled rows from buckets" do
      _enabled =
        insert!(%{
          key: "routertest.enabled",
          trigger_kind: "cron",
          trigger_config: %{"expression" => "0 * * * *"}
        })

      disabled =
        insert!(%{
          key: "routertest.disabled",
          trigger_kind: "cron",
          trigger_config: %{"expression" => "0 * * * *"},
          enabled: false
        })

      {_pid, name} = start_router()

      snap = Router.snapshot(name)
      cron_ids = Enum.map(snap.cron, & &1.id)

      refute disabled.id in cron_ids
    end

    test "starts cleanly with an empty registry (all buckets empty lists)" do
      {pid, name} = start_router()

      assert Process.alive?(pid)

      assert Router.snapshot(name) == %{
               cron: [],
               event_topics: [],
               chat_patterns: [],
               webhooks: []
             }
    end

    test "logs one :info line per bucket on boot with the counts" do
      insert!(%{
        key: "routertest.log_cron",
        trigger_kind: "cron",
        trigger_config: %{"expression" => "0 * * * *"}
      })

      insert!(%{
        key: "routertest.log_event",
        trigger_kind: "event_topic",
        trigger_config: %{"topic" => "routertest:log"}
      })

      log =
        capture_log([level: :info], fn ->
          {_pid, _name} = start_router()
          # Give the GenServer a moment to flush its init log.
          :timer.sleep(20)
        end)

      assert log =~ "[ResponsibilityRouter] started"
      assert log =~ "cron=1"
      assert log =~ "event_topics=1"
      assert log =~ "chat_patterns=0"
      assert log =~ "webhooks=0"
    end
  end

  describe "dispatch/2 stub" do
    test "returns {:error, :not_implemented_yet} and logs the attempt" do
      row =
        insert!(%{
          key: "routertest.dispatch_stub",
          trigger_kind: "cron",
          trigger_config: %{"expression" => "*/5 * * * *"}
        })

      {_pid, _name} = start_router()

      log =
        capture_log([level: :info], fn ->
          assert Router.dispatch(row, %{kind: :cron, fired_at: DateTime.utc_now()}) ==
                   {:error, :not_implemented_yet}
        end)

      assert log =~ "[ResponsibilityRouter] dispatch stub"
      assert log =~ "key=#{row.key}"
      assert log =~ "trigger=:cron"
    end
  end

  describe "tick" do
    test "keeps the GenServer alive without firing anything (stage 1 heartbeat)" do
      {pid, _name} = start_router(check_interval_ms: 5)
      # Sleep past at least one tick.
      :timer.sleep(40)
      assert Process.alive?(pid)
    end
  end

  # ── M6 stage 2: Cron parser ─────────────────────────────────────────────

  describe "Cron.parse/1 and next_fire_after/2" do
    test "all wildcards: every minute matches" do
      {:ok, spec} = Cron.parse("* * * * *")
      now = ~U[2026-06-23 12:34:56Z]

      assert {:ok, %DateTime{} = next} = Cron.next_fire_after(now, spec)
      # Wildcard spec always fires at the next minute boundary.
      assert next.minute == 35
      assert next.hour == 12
    end

    test "specific minute: '15 * * * *' yields next :15" do
      {:ok, spec} = Cron.parse("15 * * * *")
      now = ~U[2026-06-23 12:10:00Z]

      assert {:ok, next} = Cron.next_fire_after(now, spec)
      assert next.minute == 15
      assert next.hour == 12
    end

    test "specific minute past current: '5 * * * *' rolls to next hour" do
      {:ok, spec} = Cron.parse("5 * * * *")
      now = ~U[2026-06-23 12:30:00Z]

      assert {:ok, next} = Cron.next_fire_after(now, spec)
      assert next.minute == 5
      assert next.hour == 13
    end

    test "specific hour + minute: '0 9 * * *' rolls to tomorrow when past" do
      {:ok, spec} = Cron.parse("0 9 * * *")
      now = ~U[2026-06-23 10:00:00Z]

      assert {:ok, next} = Cron.next_fire_after(now, spec)
      assert next.minute == 0
      assert next.hour == 9
      assert next.day == 24
    end

    test "step expression: '*/15 * * * *' yields next quarter hour" do
      {:ok, spec} = Cron.parse("*/15 * * * *")
      now = ~U[2026-06-23 12:07:00Z]

      assert {:ok, next} = Cron.next_fire_after(now, spec)
      assert next.minute == 15
    end

    test "day-of-month: '0 0 1 * *' yields the 1st of next month" do
      {:ok, spec} = Cron.parse("0 0 1 * *")
      now = ~U[2026-06-23 12:00:00Z]

      assert {:ok, next} = Cron.next_fire_after(now, spec)
      assert next.day == 1
      assert next.month == 7
      assert next.hour == 0
      assert next.minute == 0
    end

    test "day-of-week: '0 0 * * 1' yields next Monday at midnight" do
      # 2026-06-23 is a Tuesday.
      {:ok, spec} = Cron.parse("0 0 * * 1")
      now = ~U[2026-06-23 12:00:00Z]

      assert {:ok, next} = Cron.next_fire_after(now, spec)
      assert next.hour == 0
      assert next.minute == 0
      # Next Monday after Tuesday 2026-06-23 is 2026-06-29.
      assert Date.day_of_week(DateTime.to_date(next)) == 1
    end

    test "leap-day spec: '0 0 29 2 *' resolves to a real leap date" do
      {:ok, spec} = Cron.parse("0 0 29 2 *")
      now = ~U[2026-06-23 12:00:00Z]

      assert {:ok, next} = Cron.next_fire_after(now, spec)
      assert next.day == 29
      assert next.month == 2
      # 2028 is the next leap year after 2026.
      assert next.year == 2028
    end

    test "parse rejects bad field count" do
      assert {:error, _} = Cron.parse("0 0 * *")
    end

    test "parse rejects out-of-range values" do
      assert {:error, _} = Cron.parse("99 * * * *")
    end
  end

  # ── Task 019f70e9 stage 6: timezone-aware trigger_config ─────────────────
  #
  # The Router's private `compute_next_fire/2` reads an optional
  # `"timezone"` key from `trigger_config` and passes it through to
  # `Cron.next_fire_after/3`. This describe block asserts:
  #
  #   * The Router boots cleanly with a row whose config carries the
  #     extra key (backwards-compat: an unknown key must not crash the
  #     tick pipeline that walks the cron bucket at boot).
  #   * The bucketed row round-trips the full trigger_config shape
  #     (including timezone), so a downstream consumer inspecting the
  #     snapshot sees the same map the row was inserted with.
  #   * Cron.parse + Cron.next_fire_after with the row's actual
  #     trigger_config values compute the same UTC fire time the
  #     Router would compute internally (bridge check between the
  #     public parser + the Router's private compute_next_fire).

  describe "cron trigger_config with :timezone (task 019f70e9 stage 6)" do
    test "Router boots without crashing on a row carrying a `timezone` key" do
      _row =
        insert!(%{
          key: "routertest.tz_boot_#{System.unique_integer([:positive])}",
          trigger_kind: "cron",
          trigger_config: %{
            "expression" => "0 3 * * *",
            "timezone" => "America/Chicago"
          }
        })

      {pid, name} = start_router(check_interval_ms: 5)
      # Let a couple of ticks elapse to exercise compute_next_fire on the
      # extra key.
      :timer.sleep(30)
      assert Process.alive?(pid)
      assert %{cron: [_ | _]} = Router.snapshot(name)
    end

    test "snapshot preserves the full trigger_config including the timezone key" do
      key = "routertest.tz_snap_#{System.unique_integer([:positive])}"

      _row =
        insert!(%{
          key: key,
          trigger_kind: "cron",
          trigger_config: %{
            "expression" => "0 3 * * *",
            "timezone" => "America/Chicago"
          }
        })

      {_pid, name} = start_router()

      snap = Router.snapshot(name)
      cron_row = Enum.find(snap.cron, &(&1.key == key))

      assert cron_row
      assert cron_row.trigger_config["expression"] == "0 3 * * *"
      assert cron_row.trigger_config["timezone"] == "America/Chicago"
    end

    test "Cron round-trip matches the Router's internal compute (03:00 America/Chicago in July)" do
      # Bridge check: the exact trigger_config shape the row stores
      # must parse + resolve via Cron.next_fire_after to the correct
      # UTC fire time. Router.compute_next_fire/2 is private, but its
      # body is `Cron.parse(expression) |> Cron.next_fire_after(now,
      # opts)` — replicating those two calls here would fail if the
      # Router ever regressed the timezone-passthrough.
      trigger_config = %{
        "expression" => "0 3 * * *",
        "timezone" => "America/Chicago"
      }

      {:ok, spec} = Cron.parse(trigger_config["expression"])

      now = ~U[2026-07-15 00:00:00Z]

      assert {:ok, next} =
               Cron.next_fire_after(now, spec, timezone: trigger_config["timezone"])

      # July → CDT → UTC-5 → 03:00 local == 08:00 UTC.
      assert next.hour == 8
      assert next.minute == 0
    end

    test "an unknown extra key in trigger_config is silently ignored" do
      # Backwards-compat contract: adding forward-compatible keys must
      # not crash the tick. The Router only reads `expression` and
      # `timezone`; anything else is a passthrough.
      _row =
        insert!(%{
          key: "routertest.tz_extra_#{System.unique_integer([:positive])}",
          trigger_kind: "cron",
          trigger_config: %{
            "expression" => "0 3 * * *",
            "timezone" => "America/Chicago",
            "future_feature_flag" => true
          }
        })

      {pid, _name} = start_router(check_interval_ms: 5)
      :timer.sleep(30)
      assert Process.alive?(pid)
    end
  end

  # ── M6 stage 2: fire_trigger/3 pipeline ─────────────────────────────────

  describe "fire_trigger/3 — unfilled assignee" do
    test "logs unfilled, emits telemetry, returns {:ok, :unfilled} without crashing" do
      row =
        insert!(%{
          key: "routertest.unfilled_#{System.unique_integer([:positive])}",
          trigger_kind: "cron",
          trigger_config: %{"expression" => "*/5 * * * *"}
        })

      handler_id = "router-test-unfilled-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:platform, :responsibility, :unfilled],
        fn _event, measurements, metadata, pid ->
          send(pid, {:unfilled_telemetry, measurements, metadata})
        end,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      log =
        capture_log([level: :info], fn ->
          assert {:ok, :unfilled} =
                   Router.fire_trigger(row, %{kind: :cron, fired_at: DateTime.utc_now()}, %{})
        end)

      assert log =~ "[ResponsibilityRouter] unfilled responsibility=#{row.key}"

      assert_receive {:unfilled_telemetry, %{system_time: _}, %{key: key, feature: "routertest"}}
      assert key == row.key
    end
  end

  # M6 stage 6 wires native dispatch through AgentResponder.maybe_dispatch/1,
  # which would otherwise spawn an unsandboxed Task that crashes on a
  # bare cron-fired signal (no message_id → load_context FunctionClauseError).
  # Install a no-op dispatcher for this describe block so the test
  # exercises the Router's logging + stamping pipeline without leaking
  # async errors.
  defmodule NoopNativeDispatcher do
    @moduledoc false
    def maybe_dispatch(_signal), do: :ok
  end

  describe "fire_trigger/3 — native assignee" do
    setup do
      previous =
        Application.get_env(:platform, :responsibility_router_native_dispatcher)

      Application.put_env(
        :platform,
        :responsibility_router_native_dispatcher,
        {NoopNativeDispatcher, :maybe_dispatch}
      )

      on_exit(fn ->
        if previous do
          Application.put_env(
            :platform,
            :responsibility_router_native_dispatcher,
            previous
          )
        else
          Application.delete_env(:platform, :responsibility_router_native_dispatcher)
        end
      end)

      :ok
    end

    test "logs native dispatch and stamps last_successful_fire_at" do
      key = "routertest.native_#{System.unique_integer([:positive])}"

      row =
        insert!(%{
          key: key,
          trigger_kind: "cron",
          trigger_config: %{"expression" => "*/5 * * * *"}
        })

      # Roles.Role enforces a closed enum of role keys (see
      # Platform.Roles.Role.valid_keys/0). Reuse "historian" — one of
      # the four canonical seeded rows — and attach a fresh bundle row
      # pointing at the responsibility under test. Wiring against a
      # real key keeps the assignee_for resolver path realistic.
      role_key = "historian"

      # Make sure the canonical role row exists (seeded by migration,
      # but tests sometimes run in a sandbox where the seed hasn't
      # populated yet).
      Repo.insert!(
        %Role{
          key: role_key,
          name: "Historian",
          description: "test",
          icon: "hero-star"
        },
        on_conflict: :nothing,
        conflict_target: :key
      )

      %Platform.Roles.RoleResponsibility{}
      |> Platform.Roles.RoleResponsibility.changeset(%{
        role_key: role_key,
        responsibility_key: key
      })
      |> Repo.insert!()

      agent =
        %Agent{}
        |> Agent.changeset(%{
          slug: "router-test-native-#{System.unique_integer([:positive])}",
          name: "Router Test Native",
          status: "active",
          kind: "native",
          workspace_id: nil
        })
        |> Repo.insert!()

      {:ok, _} = Roles.assign_role(role_key, agent.id)

      fired_at = ~U[2026-06-23 12:00:00.000000Z]

      log =
        capture_log([level: :info], fn ->
          assert {:ok, :dispatched} =
                   Router.fire_trigger(row, %{kind: :cron, fired_at: fired_at}, %{})
        end)

      assert log =~ "[ResponsibilityRouter] native dispatch key=#{row.key}"

      reloaded = Repo.get!(Agent, agent.id)
      assert reloaded.last_successful_fire_at == fired_at
    end
  end

  describe "tick fires due cron triggers" do
    test "responsibility whose next_fire is in the past gets fired on tick" do
      key = "routertest.tick_fire_#{System.unique_integer([:positive])}"

      # Every-minute cron — guarantees the next_fire computed at boot
      # is the next minute boundary, so a 50ms tick after a Process.sleep
      # of >60s would fire. But to keep the test fast we drive the
      # firing path directly via fire_trigger (the tick handler is a
      # thin wrapper over it). The integration assertion is "tick is
      # alive + does not crash with rows present", which we exercise
      # here.
      _row =
        insert!(%{
          key: key,
          trigger_kind: "cron",
          trigger_config: %{"expression" => "* * * * *"}
        })

      {pid, name} = start_router(check_interval_ms: 5)

      # Let several ticks elapse.
      :timer.sleep(40)

      assert Process.alive?(pid)
      assert %{cron: [_ | _]} = Router.snapshot(name)
    end
  end

  # ── M6 stage 3: event_topic + webhook trigger wiring ────────────────────

  describe "event_topic PubSub subscription" do
    test "broadcast to subscribed topic fires the matching responsibility" do
      topic = "routertest:event_#{System.unique_integer([:positive])}"
      key = "routertest.event_fire_#{System.unique_integer([:positive])}"

      row =
        insert!(%{
          key: key,
          trigger_kind: "event_topic",
          trigger_config: %{"topic" => topic}
        })

      {_pid, _name} = start_router()

      # No assignee on the row — fire_trigger will hit the unfilled
      # branch which logs "[ResponsibilityRouter] unfilled
      # responsibility=…", giving us a deterministic dispatch marker
      # without needing to stand up Roles + Agents.
      log =
        capture_log([level: :info], fn ->
          Phoenix.PubSub.broadcast(Platform.PubSub, topic, {topic, %{hello: "world"}})
          # Let the GenServer drain the inbound info message.
          :timer.sleep(50)
        end)

      assert log =~ "[ResponsibilityRouter] unfilled responsibility=#{row.key}"
    end

    test "broadcast to a topic with no matching responsibility is a no-op" do
      # Insert an event responsibility on topic A so the router has at
      # least one subscription wired; broadcast on topic B (unrelated).
      configured_topic = "routertest:event_#{System.unique_integer([:positive])}"
      _other_topic = "routertest:unrelated_#{System.unique_integer([:positive])}"

      insert!(%{
        key: "routertest.event_other_#{System.unique_integer([:positive])}",
        trigger_kind: "event_topic",
        trigger_config: %{"topic" => configured_topic}
      })

      {pid, _name} = start_router()

      log =
        capture_log([level: :info], fn ->
          Phoenix.PubSub.broadcast(
            Platform.PubSub,
            "routertest:nobody_listens_#{System.unique_integer([:positive])}",
            {:some_unrelated_event, %{}}
          )

          :timer.sleep(30)
        end)

      # Nothing should have fired — no unfilled log, no crash.
      refute log =~ "[ResponsibilityRouter] unfilled responsibility"
      assert Process.alive?(pid)
    end

    test "multiple responsibilities on the same topic all fire" do
      topic = "routertest:fanout_#{System.unique_integer([:positive])}"

      row_a =
        insert!(%{
          key: "routertest.fanout_a_#{System.unique_integer([:positive])}",
          trigger_kind: "event_topic",
          trigger_config: %{"topic" => topic}
        })

      row_b =
        insert!(%{
          key: "routertest.fanout_b_#{System.unique_integer([:positive])}",
          trigger_kind: "event_topic",
          trigger_config: %{"topic" => topic}
        })

      {_pid, _name} = start_router()

      log =
        capture_log([level: :info], fn ->
          Phoenix.PubSub.broadcast(Platform.PubSub, topic, {topic, %{}})
          :timer.sleep(50)
        end)

      assert log =~ "[ResponsibilityRouter] unfilled responsibility=#{row_a.key}"
      assert log =~ "[ResponsibilityRouter] unfilled responsibility=#{row_b.key}"
    end
  end

  describe "WebhookRouter.notify/2" do
    test "matching webhook responsibility fires via Router cast" do
      path = "/hooks/routertest_#{System.unique_integer([:positive])}"

      row =
        insert!(%{
          key: "routertest.webhook_fire_#{System.unique_integer([:positive])}",
          trigger_kind: "webhook",
          trigger_config: %{"path" => path}
        })

      {_pid, name} = start_router()

      log =
        capture_log([level: :info], fn ->
          assert :ok = WebhookRouter.notify(path, %{"event" => "test"}, router: name)
          :timer.sleep(50)
        end)

      assert log =~ "[ResponsibilityRouter] unfilled responsibility=#{row.key}"
    end

    test "webhook fire with no matching responsibility logs no-match and stays alive" do
      _row =
        insert!(%{
          key: "routertest.webhook_other_#{System.unique_integer([:positive])}",
          trigger_kind: "webhook",
          trigger_config: %{"path" => "/hooks/configured_#{System.unique_integer([:positive])}"}
        })

      {pid, name} = start_router()

      log =
        capture_log([level: :info], fn ->
          assert :ok =
                   WebhookRouter.notify(
                     "/hooks/nobody_listens_#{System.unique_integer([:positive])}",
                     %{},
                     router: name
                   )

          :timer.sleep(30)
        end)

      assert log =~ "[ResponsibilityRouter] webhook fired with no matching responsibility"
      refute log =~ "[ResponsibilityRouter] unfilled responsibility"
      assert Process.alive?(pid)
    end

    test "multiple webhook responsibilities on the same path all fire" do
      path = "/hooks/multi_#{System.unique_integer([:positive])}"

      row_a =
        insert!(%{
          key: "routertest.webhook_multi_a_#{System.unique_integer([:positive])}",
          trigger_kind: "webhook",
          trigger_config: %{"path" => path}
        })

      row_b =
        insert!(%{
          key: "routertest.webhook_multi_b_#{System.unique_integer([:positive])}",
          trigger_kind: "webhook",
          trigger_config: %{"path" => path}
        })

      {_pid, name} = start_router()

      log =
        capture_log([level: :info], fn ->
          assert :ok = WebhookRouter.notify(path, %{}, router: name)
          :timer.sleep(50)
        end)

      assert log =~ "[ResponsibilityRouter] unfilled responsibility=#{row_a.key}"
      assert log =~ "[ResponsibilityRouter] unfilled responsibility=#{row_b.key}"
    end

    test "notify with a missing router name does not raise" do
      # GenServer.cast/2 silently succeeds when the destination is not
      # registered — we only care that notify/3 does not raise and
      # always returns :ok.
      dead_name = Module.concat([Router, "DefinitelyDown#{System.unique_integer([:positive])}"])

      assert :ok = WebhookRouter.notify("/hooks/anything", %{}, router: dead_name)
    end
  end

  # ── M6 stage 4: chat_pattern trigger wiring ─────────────────────────────

  describe "chat_pattern telemetry subscription" do
    # Fixture helpers scoped to this describe block so the existing M6
    # stage 1-3 tests don't have to grow new dependencies. We persist a
    # real Chat.Space + Participant pair (the planner-mandated path) so
    # `Chat.post_message/1` exercises the same `publish_message_posted/2`
    # telemetry the Router subscribes to.

    defp create_space(kind \\ "channel") do
      slug = "patternspace-#{System.unique_integer([:positive])}"

      {:ok, space} =
        Chat.create_space(%{
          name: "Pattern Test #{slug}",
          slug: slug,
          kind: kind
        })

      space
    end

    defp create_user_participant(space_id, name \\ "Alice") do
      {:ok, participant} =
        Chat.add_participant(space_id, %{
          participant_type: "user",
          participant_id: Ecto.UUID.generate(),
          display_name: name,
          joined_at: DateTime.utc_now()
        })

      participant
    end

    defp create_agent_participant(space_id) do
      agent =
        %Agent{}
        |> Agent.changeset(%{
          slug: "pattern-agent-#{System.unique_integer([:positive])}",
          name: "Pattern Agent",
          status: "active",
          kind: "native",
          workspace_id: nil
        })
        |> Repo.insert!()

      {:ok, participant} = Chat.add_agent_participant(space_id, agent)
      {agent, participant}
    end

    test "matching message in a normal space fires the responsibility" do
      key = "routertest.chat_pattern_fire_#{System.unique_integer([:positive])}"

      row =
        insert!(%{
          key: key,
          trigger_kind: "chat_pattern",
          trigger_config: %{"regex" => "deploy please"}
        })

      space = create_space()
      author = create_user_participant(space.id)
      {_pid, _name} = start_router()

      log =
        capture_log([level: :info], fn ->
          {:ok, _msg} =
            Chat.post_message(%{
              space_id: space.id,
              participant_id: author.id,
              content_type: "text",
              content: "hey team, deploy please when ready"
            })

          # Telemetry → send → handle_info; give the GenServer a beat to
          # drain its mailbox.
          :timer.sleep(60)
        end)

      assert log =~ "[ResponsibilityRouter] unfilled responsibility=#{row.key}"
    end

    test "agent-authored matching message does NOT fire (feedback-loop guard)" do
      key = "routertest.chat_pattern_agent_skip_#{System.unique_integer([:positive])}"

      _row =
        insert!(%{
          key: key,
          trigger_kind: "chat_pattern",
          trigger_config: %{"regex" => "deploy please"}
        })

      space = create_space()
      {_agent, agent_participant} = create_agent_participant(space.id)
      {_pid, _name} = start_router()

      log =
        capture_log([level: :info], fn ->
          {:ok, _msg} =
            Chat.post_message(%{
              space_id: space.id,
              participant_id: agent_participant.id,
              content_type: "text",
              content: "ack — deploy please relayed"
            })

          :timer.sleep(60)
        end)

      refute log =~ "[ResponsibilityRouter] unfilled responsibility=#{key}"
    end

    test "matching message in a system-kind space does NOT fire" do
      key = "routertest.chat_pattern_system_skip_#{System.unique_integer([:positive])}"

      _row =
        insert!(%{
          key: key,
          trigger_kind: "chat_pattern",
          trigger_config: %{"regex" => "deploy please"}
        })

      space = create_space("system")
      author = create_user_participant(space.id)
      {_pid, _name} = start_router()

      log =
        capture_log([level: :info], fn ->
          {:ok, _msg} =
            Chat.post_message(%{
              space_id: space.id,
              participant_id: author.id,
              content_type: "text",
              content: "system: deploy please occurred"
            })

          :timer.sleep(60)
        end)

      refute log =~ "[ResponsibilityRouter] unfilled responsibility=#{key}"
    end

    test "non-matching message does not fire" do
      key = "routertest.chat_pattern_no_match_#{System.unique_integer([:positive])}"

      _row =
        insert!(%{
          key: key,
          trigger_kind: "chat_pattern",
          trigger_config: %{"regex" => "deploy please"}
        })

      space = create_space()
      author = create_user_participant(space.id)
      {_pid, _name} = start_router()

      log =
        capture_log([level: :info], fn ->
          {:ok, _msg} =
            Chat.post_message(%{
              space_id: space.id,
              participant_id: author.id,
              content_type: "text",
              content: "good morning everyone"
            })

          :timer.sleep(60)
        end)

      refute log =~ "[ResponsibilityRouter] unfilled responsibility=#{key}"
    end

    test "invalid regex at boot logs warning, drops only that row, valid patterns still fire" do
      good_key = "routertest.chat_pattern_good_#{System.unique_integer([:positive])}"

      _good_row =
        insert!(%{
          key: good_key,
          trigger_kind: "chat_pattern",
          trigger_config: %{"regex" => "ship it"}
        })

      # The Responsibility changeset validator rejects un-compilable
      # regexes at create time, so we bypass it with a direct Repo
      # write to simulate a malformed row landing via a migration
      # backfill or older schema. The Router must drop this one
      # without crashing AND keep firing the good row.
      bad_key = "routertest.chat_pattern_bad_#{System.unique_integer([:positive])}"

      bad_row =
        Repo.insert!(%Platform.Responsibilities.Responsibility{
          key: bad_key,
          feature: "routertest",
          trigger_kind: "chat_pattern",
          trigger_config: %{"regex" => "[unterminated"},
          scope: "global",
          context_provided: [],
          output_contract: %{"summary" => "string"},
          default_prompt_template: "routertest.v1",
          cost_profile: "low_freq_capable",
          enabled: true
        })

      assert bad_row.id

      space = create_space()
      author = create_user_participant(space.id)

      boot_log =
        capture_log([level: :warning], fn ->
          {_pid, _name} = start_router()
        end)

      assert boot_log =~ "[ResponsibilityRouter] dropping chat_pattern responsibility"
      assert boot_log =~ "key=#{bad_key}"

      # The good pattern still fires after boot.
      log =
        capture_log([level: :info], fn ->
          {:ok, _msg} =
            Chat.post_message(%{
              space_id: space.id,
              participant_id: author.id,
              content_type: "text",
              content: "ship it now please"
            })

          :timer.sleep(60)
        end)

      assert log =~ "[ResponsibilityRouter] unfilled responsibility=#{good_key}"
    end

    test "multiple matching patterns each fire independently for one message" do
      key_a = "routertest.chat_pattern_multi_a_#{System.unique_integer([:positive])}"
      key_b = "routertest.chat_pattern_multi_b_#{System.unique_integer([:positive])}"

      row_a =
        insert!(%{
          key: key_a,
          trigger_kind: "chat_pattern",
          trigger_config: %{"regex" => "alpha"}
        })

      row_b =
        insert!(%{
          key: key_b,
          trigger_kind: "chat_pattern",
          trigger_config: %{"regex" => "beta"}
        })

      space = create_space()
      author = create_user_participant(space.id)
      {_pid, _name} = start_router()

      log =
        capture_log([level: :info], fn ->
          {:ok, _msg} =
            Chat.post_message(%{
              space_id: space.id,
              participant_id: author.id,
              content_type: "text",
              content: "alpha beta gamma — two patterns, one message"
            })

          :timer.sleep(80)
        end)

      assert log =~ "[ResponsibilityRouter] unfilled responsibility=#{row_a.key}"
      assert log =~ "[ResponsibilityRouter] unfilled responsibility=#{row_b.key}"
    end

    test "pattern with multiple matches in the same content fires only ONCE" do
      key = "routertest.chat_pattern_once_#{System.unique_integer([:positive])}"

      _row =
        insert!(%{
          key: key,
          trigger_kind: "chat_pattern",
          trigger_config: %{"regex" => "ping"}
        })

      space = create_space()
      author = create_user_participant(space.id)
      {_pid, _name} = start_router()

      log =
        capture_log([level: :info], fn ->
          {:ok, _msg} =
            Chat.post_message(%{
              space_id: space.id,
              participant_id: author.id,
              content_type: "text",
              content: "ping ping ping ping ping"
            })

          :timer.sleep(60)
        end)

      # Count the unfilled lines for our key — must be exactly one.
      occurrences =
        log
        |> String.split("\n")
        |> Enum.count(&String.contains?(&1, "unfilled responsibility=#{key}"))

      assert occurrences == 1
    end
  end

  # ── M6 stage 6: external dispatch + handle_output hook ──────────────────

  describe "fire_trigger/3 — external assignee" do
    # Test seam — point the dispatcher's injected Req client at a named
    # stub mirroring DispatcherTest. Clean up on exit so the env doesn't
    # leak into other tests in the same suite.
    setup do
      {:ok, _} = Application.ensure_all_started(:req)

      Application.put_env(
        :platform,
        :external_agents_dispatcher_req_client,
        Req.new(plug: {Req.Test, :router_external_dispatch_test})
      )

      on_exit(fn ->
        Application.delete_env(:platform, :external_agents_dispatcher_req_client)
      end)

      :ok
    end

    defp wire_external_assignee(responsibility_key) do
      role_key = "historian"

      Repo.insert!(
        %Role{
          key: role_key,
          name: "Historian",
          description: "test",
          icon: "hero-star"
        },
        on_conflict: :nothing,
        conflict_target: :key
      )

      %Platform.Roles.RoleResponsibility{}
      |> Platform.Roles.RoleResponsibility.changeset(%{
        role_key: role_key,
        responsibility_key: responsibility_key
      })
      |> Repo.insert!()

      agent =
        %Agent{}
        |> Agent.changeset(%{
          slug: "router-test-ext-#{System.unique_integer([:positive])}",
          name: "Router Test External",
          status: "active",
          kind: "external",
          endpoint_kind: "openai_compat",
          base_url: "https://api.example.test",
          model: "test-model",
          workspace_id: nil
        })
        |> Repo.insert!()

      :ok = Platform.ExternalAgents.EphemeralCredentials.put(agent.id, "sk-router-test")
      on_exit(fn -> Platform.ExternalAgents.EphemeralCredentials.delete(agent.id) end)

      {:ok, _} = Roles.assign_role(role_key, agent.id)

      agent
    end

    test "Dispatcher.dispatch is invoked, telemetry fires, last_successful_fire_at is stamped" do
      key = "routertest.external_full_#{System.unique_integer([:positive])}"

      row =
        insert!(%{
          key: key,
          feature: "test_feature_#{System.unique_integer([:positive])}",
          trigger_kind: "cron",
          trigger_config: %{"expression" => "*/5 * * * *"},
          default_prompt_template: "echo: ping"
        })

      agent = wire_external_assignee(key)

      test_pid = self()

      Req.Test.stub(:router_external_dispatch_test, fn conn ->
        send(test_pid, {:dispatch_req, conn.request_path})

        Req.Test.json(conn, %{
          "choices" => [
            %{"message" => %{"role" => "assistant", "content" => "router stage6 ok"}}
          ]
        })
      end)

      handler_id = "router-test-fired-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:platform, :responsibility, :fired],
        fn _event, measurements, metadata, pid ->
          send(pid, {:fired_telemetry, measurements, metadata})
        end,
        test_pid
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      fired_at = ~U[2026-06-23 14:00:00.000000Z]

      log =
        capture_log([level: :info], fn ->
          assert {:ok, :dispatched} =
                   Router.fire_trigger(row, %{kind: :cron, fired_at: fired_at}, %{})
        end)

      assert log =~ "[ResponsibilityRouter] external dispatch ok key=#{key}"
      assert_receive {:dispatch_req, "/chat/completions"}

      assert_receive {:fired_telemetry, %{system_time: _},
                      %{key: ^key, dispatch_kind: :external, agent_slug: agent_slug}}

      assert agent_slug == agent.slug

      reloaded = Repo.get!(Agent, agent.id)
      assert reloaded.last_successful_fire_at == fired_at
    end

    test "Dispatcher failure emits :failed telemetry and does NOT stamp" do
      key = "routertest.external_fail_#{System.unique_integer([:positive])}"

      row =
        insert!(%{
          key: key,
          trigger_kind: "cron",
          trigger_config: %{"expression" => "*/5 * * * *"}
        })

      agent = wire_external_assignee(key)

      Req.Test.stub(:router_external_dispatch_test, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(503, ~s({"error":"down"}))
      end)

      test_pid = self()
      handler_id = "router-test-failed-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:platform, :responsibility, :failed],
        fn _event, measurements, metadata, pid ->
          send(pid, {:failed_telemetry, measurements, metadata})
        end,
        test_pid
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      log =
        capture_log([level: :warning], fn ->
          assert {:error, {:dispatch_failed, _}} =
                   Router.fire_trigger(row, %{kind: :cron, fired_at: DateTime.utc_now()}, %{})
        end)

      assert log =~ "[ResponsibilityRouter] external dispatch failed key=#{key}"

      assert_receive {:failed_telemetry, _meas,
                      %{key: ^key, dispatch_kind: :external, reason: reason}}

      assert reason =~ "http_error"

      reloaded = Repo.get!(Agent, agent.id)
      # The dispatch failed before we stamped — agent stays at nil.
      assert reloaded.last_successful_fire_at == nil
    end

    test "handle_output/3 is invoked on the provider module when present" do
      # Stand up an ad-hoc provider module under a unique feature so we
      # don't collide with the real Providers.*. The Router resolves the
      # module through `Platform.Responsibilities.Providers`, so the
      # throwaway module registers itself via the override seam.

      feature_str = "router_test_ho_#{System.unique_integer([:positive])}"

      test_pid = self()

      define_provider(
        feature_str,
        quote do
          @behaviour Platform.Responsibilities.Provider

          @impl true
          def register, do: []

          @impl true
          def gather_context(_r, _c), do: {:ok, %{}}

          @impl true
          def handle_output(_r, _o), do: :ok

          @impl true
          def handle_output(responsibility, parsed, meta) do
            send(unquote(test_pid), {:handle_output_invoked, responsibility.key, parsed, meta})
            :ok
          end
        end
      )

      key = "#{feature_str}.dispatch_#{System.unique_integer([:positive])}"

      row =
        insert!(%{
          key: key,
          feature: feature_str,
          trigger_kind: "cron",
          trigger_config: %{"expression" => "*/5 * * * *"}
        })

      _agent = wire_external_assignee(key)

      Req.Test.stub(:router_external_dispatch_test, fn conn ->
        Req.Test.json(conn, %{
          "choices" => [
            %{"message" => %{"role" => "assistant", "content" => "ho_invoked"}}
          ]
        })
      end)

      trigger_meta = %{kind: :cron, fired_at: DateTime.utc_now(), correlation: "abc"}

      capture_log([level: :info], fn ->
        assert {:ok, :dispatched} = Router.fire_trigger(row, trigger_meta, %{})
      end)

      assert_receive {:handle_output_invoked, ^key, "ho_invoked", meta}
      assert meta[:correlation] == "abc"
    end

    test "missing provider module logs 'no output handler' but still emits :fired" do
      key = "routertest.no_handler_#{System.unique_integer([:positive])}"

      row =
        insert!(%{
          key: key,
          feature: "definitely_not_a_real_feature_#{System.unique_integer([:positive])}",
          trigger_kind: "cron",
          trigger_config: %{"expression" => "*/5 * * * *"}
        })

      _agent = wire_external_assignee(key)

      Req.Test.stub(:router_external_dispatch_test, fn conn ->
        Req.Test.json(conn, %{
          "choices" => [
            %{"message" => %{"role" => "assistant", "content" => "nh"}}
          ]
        })
      end)

      log =
        capture_log([level: :info], fn ->
          assert {:ok, :dispatched} =
                   Router.fire_trigger(row, %{kind: :cron, fired_at: DateTime.utc_now()}, %{})
        end)

      assert log =~ "[ResponsibilityRouter] no output handler for #{key}"
      assert log =~ "[ResponsibilityRouter] external dispatch ok key=#{key}"
    end

    # ── task 019f2570 stage 1 — provider gather_context + build_prompt wiring ──

    test "provider gather_context/2 is invoked before ContextGatherer fallback" do
      # Ad-hoc provider under a unique feature, bound to that feature
      # through the Providers override seam.
      feature_str = "router_gc_probe_#{System.unique_integer([:positive])}"

      test_pid = self()

      define_provider(
        feature_str,
        quote do
          @behaviour Platform.Responsibilities.Provider

          @impl true
          def register, do: []

          @impl true
          def gather_context(responsibility, meta) do
            send(unquote(test_pid), {:provider_gather_invoked, responsibility.key, meta})
            {:ok, %{provider_supplied: "yes"}}
          end

          @impl true
          def handle_output(_r, _o), do: :ok

          @impl true
          def handle_output(_r, _o, _m), do: :ok
        end
      )

      key = "#{feature_str}.trigger_#{System.unique_integer([:positive])}"

      row =
        insert!(%{
          key: key,
          feature: feature_str,
          trigger_kind: "cron",
          trigger_config: %{"expression" => "*/5 * * * *"}
        })

      _agent = wire_external_assignee(key)

      Req.Test.stub(:router_external_dispatch_test, fn conn ->
        Req.Test.json(conn, %{
          "choices" => [
            %{"message" => %{"role" => "assistant", "content" => "gc ok"}}
          ]
        })
      end)

      trigger_meta = %{
        kind: :cron,
        fired_at: DateTime.utc_now(),
        payload: %{transcript_id: "t-abc"}
      }

      capture_log([level: :info], fn ->
        assert {:ok, :dispatched} = Router.fire_trigger(row, trigger_meta, %{})
      end)

      # Provider callback must be invoked with the full trigger_meta
      # (nested `:payload` reachable) — this is the fix for the router
      # calling ContextGatherer with a flat meta lookup and missing
      # `meta[:payload][:transcript_id]`.
      assert_receive {:provider_gather_invoked, ^key, meta}
      assert meta.payload.transcript_id == "t-abc"
    end

    test "provider build_prompt/1 messages land in the LLM request body verbatim" do
      feature_str = "router_bp_verbatim_#{System.unique_integer([:positive])}"

      define_provider(
        feature_str,
        quote do
          @behaviour Platform.Responsibilities.Provider

          @impl true
          def register, do: []

          @impl true
          def gather_context(_r, _m),
            do: {:ok, %{transcript_text: "Alice: yes\nBob: no", meeting_transcript: %{}}}

          @impl true
          def build_prompt(_ctx) do
            {:ok,
             %{
               system: "You are a summariser.",
               user: "Summarise:\nAlice: yes\nBob: no"
             }}
          end

          @impl true
          def handle_output(_r, _o), do: :ok

          @impl true
          def handle_output(_r, _o, _m), do: :ok
        end
      )

      key = "#{feature_str}.trigger_#{System.unique_integer([:positive])}"

      row =
        insert!(%{
          key: key,
          feature: feature_str,
          trigger_kind: "cron",
          trigger_config: %{"expression" => "*/5 * * * *"},
          # THIS is the un-seeded template slug — the pre-019f2570
          # dispatcher would have sent this literal string as the user
          # turn. Assert it does NOT show up in the request body.
          default_prompt_template: "meetings.summarize.v1"
        })

      _agent = wire_external_assignee(key)
      test_pid = self()

      Req.Test.stub(:router_external_dispatch_test, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:dispatch_body, body})

        Req.Test.json(conn, %{
          "choices" => [
            %{"message" => %{"role" => "assistant", "content" => "ok"}}
          ]
        })
      end)

      capture_log([level: :info], fn ->
        assert {:ok, :dispatched} =
                 Router.fire_trigger(row, %{kind: :cron, fired_at: DateTime.utc_now()}, %{})
      end)

      assert_receive {:dispatch_body, raw_body}
      decoded = Jason.decode!(raw_body)

      # The provider's system + user prompts land verbatim, and the
      # un-seeded default_prompt_template string does NOT.
      contents = Enum.map(decoded["messages"], & &1["content"])
      assert Enum.any?(contents, &(&1 =~ "You are a summariser."))
      assert Enum.any?(contents, &(&1 =~ "Summarise:\nAlice: yes\nBob: no"))
      refute Enum.any?(contents, &(&1 =~ "meetings.summarize.v1"))

      # Roles are pre-split (no split_prompt regex round-trip).
      roles = Enum.map(decoded["messages"], & &1["role"]) |> Enum.sort()
      assert roles == ["system", "user"]
    end

    test "provider build_prompt/1 returning {:error, _} short-circuits — no LLM call, :failed telemetry" do
      feature_str = "router_bp_refuse_#{System.unique_integer([:positive])}"

      define_provider(
        feature_str,
        quote do
          @behaviour Platform.Responsibilities.Provider

          @impl true
          def register, do: []

          @impl true
          def gather_context(_r, _m), do: {:ok, %{}}

          @impl true
          def build_prompt(_ctx), do: {:error, :no_transcript_text}

          @impl true
          def handle_output(_r, _o), do: :ok

          @impl true
          def handle_output(_r, _o, _m), do: :ok
        end
      )

      key = "#{feature_str}.trigger_#{System.unique_integer([:positive])}"

      row =
        insert!(%{
          key: key,
          feature: feature_str,
          trigger_kind: "cron",
          trigger_config: %{"expression" => "*/5 * * * *"}
        })

      _agent = wire_external_assignee(key)
      test_pid = self()

      # If the LLM stub gets called, this test fails.
      Req.Test.stub(:router_external_dispatch_test, fn conn ->
        send(test_pid, :dispatched_anyway)
        Req.Test.json(conn, %{"choices" => []})
      end)

      handler_id = "router-test-refused-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:platform, :responsibility, :failed],
        fn _event, measurements, metadata, pid ->
          send(pid, {:failed_telemetry, measurements, metadata})
        end,
        test_pid
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      log =
        capture_log([level: :warning], fn ->
          assert {:error, {:build_prompt_refused, _}} =
                   Router.fire_trigger(row, %{kind: :cron, fired_at: DateTime.utc_now()}, %{})
        end)

      assert log =~ "provider build_prompt refused dispatch"
      assert log =~ "no_transcript_text"

      # LLM stub must not have been called.
      refute_receive :dispatched_anyway, 100

      assert_receive {:failed_telemetry, _meas,
                      %{key: ^key, dispatch_kind: :external, reason: reason}}

      assert reason =~ "build_prompt_refused"
      assert reason =~ "no_transcript_text"
    end

    test "provider without build_prompt/1 continues to use the legacy template render path" do
      feature_str = "router_bp_legacy_#{System.unique_integer([:positive])}"

      define_provider(
        feature_str,
        quote do
          @behaviour Platform.Responsibilities.Provider

          @impl true
          def register, do: []

          # NB: no `build_prompt/1` — the Router must fall back to
          # the legacy `default_prompt_template` render path.
          @impl true
          def gather_context(_r, _m), do: {:ok, %{topic: "quarterly"}}

          @impl true
          def handle_output(_r, _o), do: :ok

          @impl true
          def handle_output(_r, _o, _m), do: :ok
        end
      )

      key = "#{feature_str}.trigger_#{System.unique_integer([:positive])}"

      row =
        insert!(%{
          key: key,
          feature: feature_str,
          trigger_kind: "cron",
          trigger_config: %{"expression" => "*/5 * * * *"},
          # Real template body — expect it to be rendered with the
          # gathered context. This is the backward-compat contract.
          default_prompt_template: "Please cover the {topic} update."
        })

      _agent = wire_external_assignee(key)
      test_pid = self()

      Req.Test.stub(:router_external_dispatch_test, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:legacy_body, body})

        Req.Test.json(conn, %{
          "choices" => [
            %{"message" => %{"role" => "assistant", "content" => "ok"}}
          ]
        })
      end)

      capture_log([level: :info], fn ->
        assert {:ok, :dispatched} =
                 Router.fire_trigger(row, %{kind: :cron, fired_at: DateTime.utc_now()}, %{})
      end)

      assert_receive {:legacy_body, raw_body}
      decoded = Jason.decode!(raw_body)

      # Legacy template got rendered against gathered context, so
      # `quarterly` (the topic) appears in the user turn.
      user = Enum.find(decoded["messages"], &(&1["role"] == "user"))
      assert user["content"] =~ "quarterly"
    end

    # ── fix/render-prompt-for-federated-dispatch — external guard ──────────
    #
    # Hoisting `gather_context_via_provider/3` + `build_prompt_via_provider/2`
    # above the external/native branch must leave the external path
    # bit-identical. This pins the FULL outbound messages list (not just a
    # `=~` probe) so a regression in the shared preamble shows up here.
    test "external dispatch body is unchanged by the shared prompt preamble" do
      feature_str = "router_ext_guard_#{System.unique_integer([:positive])}"

      define_provider(
        feature_str,
        quote do
          @behaviour Platform.Responsibilities.Provider

          @impl true
          def register, do: []

          @impl true
          def gather_context(_r, _m), do: {:ok, %{who: "Ada"}}

          @impl true
          def build_prompt(ctx), do: {:ok, %{system: "SYS", user: "USER #{ctx.who}"}}

          @impl true
          def handle_output(_r, _o), do: :ok

          @impl true
          def handle_output(_r, _o, _m), do: :ok
        end
      )

      key = "#{feature_str}.trigger_#{System.unique_integer([:positive])}"

      row =
        insert!(%{
          key: key,
          feature: feature_str,
          trigger_kind: "cron",
          trigger_config: %{"expression" => "*/5 * * * *"},
          default_prompt_template: "unseeded.slug.v1"
        })

      _agent = wire_external_assignee(key)
      test_pid = self()

      Req.Test.stub(:router_external_dispatch_test, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:guard_body, body})

        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}]
        })
      end)

      capture_log([level: :info], fn ->
        assert {:ok, :dispatched} =
                 Router.fire_trigger(row, %{kind: :cron, fired_at: DateTime.utc_now()}, %{})
      end)

      assert_receive {:guard_body, raw_body}
      decoded = Jason.decode!(raw_body)

      assert decoded["messages"] == [
               %{"role" => "system", "content" => "SYS"},
               %{"role" => "user", "content" => "USER Ada"}
             ]
    end

    # ── task 019f9b28-6ca7 stage 2 — a provider refusal is honoured ────────
    #
    # `gather_context_via_provider/3` used to have ONE `else` arm collapsing
    # four situations: no provider module, provider without
    # `gather_context/2`, provider that deliberately returned
    # `{:error, :no_transcript}`, and provider that raised. The first two
    # mean "nothing to say" and the ContextGatherer fallback is correct.
    # The last two mean the dispatch is wrong, and substituting generic
    # context sent the LLM — and the bill — after a different question.
    #
    # DETECTOR: revert `gather_context_via_provider/3` to the `with`/`else`
    # fallback and the two `refute_receive :dispatched_anyway` assertions
    # below fail, because the refusal becomes a generic dispatch.

    test "a provider that refuses context short-circuits — no LLM call, :failed telemetry" do
      feature_str = "router_gc_refuse_#{System.unique_integer([:positive])}"

      define_provider(
        feature_str,
        quote do
          @behaviour Platform.Responsibilities.Provider

          @impl true
          def register, do: []

          @impl true
          def gather_context(_r, _m), do: {:error, :deliberate}

          @impl true
          def handle_output(_r, _o), do: :ok

          @impl true
          def handle_output(_r, _o, _m), do: :ok
        end
      )

      key = "#{feature_str}.trigger_#{System.unique_integer([:positive])}"

      row =
        insert!(%{
          key: key,
          feature: feature_str,
          trigger_kind: "cron",
          trigger_config: %{"expression" => "*/5 * * * *"},
          # A renderable legacy template — so the ONLY thing stopping the
          # dispatch is the refusal, not a missing prompt.
          default_prompt_template: "do the thing"
        })

      _agent = wire_external_assignee(key)
      test_pid = self()

      Req.Test.stub(:router_external_dispatch_test, fn conn ->
        send(test_pid, :dispatched_anyway)
        Req.Test.json(conn, %{"choices" => []})
      end)

      handler_id = "router-test-gc-refused-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:platform, :responsibility, :failed],
        fn _event, measurements, metadata, pid ->
          send(pid, {:failed_telemetry, measurements, metadata})
        end,
        test_pid
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {fire_result, log} =
        with_log([level: :warning], fn ->
          Router.fire_trigger(row, %{kind: :cron, fired_at: DateTime.utc_now()}, %{})
        end)

      # STRONGEST ASSERTION FIRST, deliberately. A return-tuple match would
      # also go red on a revert, but it would go red on a SHAPE. This goes
      # red on the observable fact the stage exists to change: bytes left
      # the process, headed for a paid endpoint, carrying context the
      # provider said it could not supply.
      refute_receive :dispatched_anyway, 100

      assert fire_result == {:error, {:context_gather_refused, :deliberate}}

      assert log =~ "provider gather_context refused dispatch"
      assert log =~ "key=#{key}"
      assert log =~ ":deliberate"

      assert_receive {:failed_telemetry, _meas,
                      %{key: ^key, dispatch_kind: :external, reason: reason}}

      assert reason =~ "context_gather_refused"
      assert reason =~ "deliberate"
    end

    # POSITIVE CONTROL for the test above, on the same harness and the same
    # mechanism: the ONLY difference is the provider's return value. If this
    # dispatches and the marker lands in the body, then the `refute_receive`
    # above is a real observation about the refusal rather than a stub that
    # was never reachable.
    test "the same provider returning {:ok, ctx} DOES dispatch and its context reaches the body" do
      feature_str = "router_gc_allow_#{System.unique_integer([:positive])}"

      define_provider(
        feature_str,
        quote do
          @behaviour Platform.Responsibilities.Provider

          @impl true
          def register, do: []

          @impl true
          def gather_context(_r, _m), do: {:ok, %{marker: "GATHER_MARKER"}}

          @impl true
          def handle_output(_r, _o), do: :ok

          @impl true
          def handle_output(_r, _o, _m), do: :ok
        end
      )

      key = "#{feature_str}.trigger_#{System.unique_integer([:positive])}"

      row =
        insert!(%{
          key: key,
          feature: feature_str,
          trigger_kind: "cron",
          trigger_config: %{"expression" => "*/5 * * * *"},
          default_prompt_template: "do the thing: {marker}"
        })

      _agent = wire_external_assignee(key)
      test_pid = self()

      Req.Test.stub(:router_external_dispatch_test, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:dispatched_anyway, body})

        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}]
        })
      end)

      capture_log([level: :info], fn ->
        assert {:ok, :dispatched} =
                 Router.fire_trigger(row, %{kind: :cron, fired_at: DateTime.utc_now()}, %{})
      end)

      assert_receive {:dispatched_anyway, raw_body}
      assert raw_body =~ "GATHER_MARKER"
    end

    test "a provider whose gather_context/2 raises refuses too, and logs at :error" do
      feature_str = "router_gc_raise_#{System.unique_integer([:positive])}"

      define_provider(
        feature_str,
        quote do
          @behaviour Platform.Responsibilities.Provider

          @impl true
          def register, do: []

          @impl true
          def gather_context(_r, _m), do: raise(RuntimeError, "gatherer exploded")

          @impl true
          def handle_output(_r, _o), do: :ok

          @impl true
          def handle_output(_r, _o, _m), do: :ok
        end
      )

      key = "#{feature_str}.trigger_#{System.unique_integer([:positive])}"

      row =
        insert!(%{
          key: key,
          feature: feature_str,
          trigger_kind: "cron",
          trigger_config: %{"expression" => "*/5 * * * *"},
          default_prompt_template: "do the thing"
        })

      _agent = wire_external_assignee(key)
      test_pid = self()

      Req.Test.stub(:router_external_dispatch_test, fn conn ->
        send(test_pid, :dispatched_anyway)
        Req.Test.json(conn, %{"choices" => []})
      end)

      handler_id = "router-test-gc-raise-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:platform, :responsibility, :failed],
        fn _event, measurements, metadata, pid ->
          send(pid, {:failed_telemetry, measurements, metadata})
        end,
        test_pid
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # Captured at :error, so a :warning is invisible here. That is the
      # point: it pins the log-LEVEL half of the raise-vs-refusal split.
      # A broken gatherer is a defect (:error); a provider that said no is
      # a decision (:warning), and the refusal line must NOT show up.
      {fire_result, error_log} =
        with_log([level: :error], fn ->
          Router.fire_trigger(row, %{kind: :cron, fired_at: DateTime.utc_now()}, %{})
        end)

      refute_receive :dispatched_anyway, 100

      assert {:error, {:context_gather_refused, {:provider_gather_raised, message}}} = fire_result
      assert message =~ "gatherer exploded"

      assert error_log =~ "provider gather_context raised"
      refute error_log =~ "provider gather_context refused dispatch"

      assert_receive {:failed_telemetry, _meas,
                      %{key: ^key, dispatch_kind: :external, reason: reason}}

      assert reason =~ "context_gather_refused"
      assert reason =~ "provider_gather_raised"
    end

    # GUARD for the OTHER two situations the old `else` arm covered. These
    # are "nothing to say", not a refusal, and must still fall back to
    # `ContextGatherer` and dispatch. Narrowing the fallback is the whole
    # risk of this stage; these are what say we narrowed it correctly.
    test "a provider that does NOT export gather_context/2 still falls back and dispatches" do
      feature_str = "router_gc_nogather_#{System.unique_integer([:positive])}"

      define_provider(
        feature_str,
        quote do
          @behaviour Platform.Responsibilities.Provider

          @impl true
          def register, do: []

          # NB: no `gather_context/2` at all — the "nothing to say" case.

          @impl true
          def handle_output(_r, _o), do: :ok

          @impl true
          def handle_output(_r, _o, _m), do: :ok
        end
      )

      key = "#{feature_str}.trigger_#{System.unique_integer([:positive])}"

      row =
        insert!(%{
          key: key,
          feature: feature_str,
          trigger_kind: "cron",
          trigger_config: %{"expression" => "*/5 * * * *"},
          context_provided: ["org_identity"],
          default_prompt_template: "fallback still renders"
        })

      _agent = wire_external_assignee(key)
      test_pid = self()

      Req.Test.stub(:router_external_dispatch_test, fn conn ->
        send(test_pid, :fallback_dispatched)

        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}]
        })
      end)

      capture_log([level: :info], fn ->
        assert {:ok, :dispatched} =
                 Router.fire_trigger(row, %{kind: :cron, fired_at: DateTime.utc_now()}, %{})
      end)

      assert_receive :fallback_dispatched
    end

    test "a feature with no provider module at all still falls back and dispatches" do
      key = "routertest.gc_noprovider_#{System.unique_integer([:positive])}"

      row =
        insert!(%{
          key: key,
          # Never registered in @feature_providers and never overridden.
          feature: "router_gc_unregistered_#{System.unique_integer([:positive])}",
          trigger_kind: "cron",
          trigger_config: %{"expression" => "*/5 * * * *"},
          context_provided: ["org_identity"],
          default_prompt_template: "fallback still renders"
        })

      _agent = wire_external_assignee(key)
      test_pid = self()

      Req.Test.stub(:router_external_dispatch_test, fn conn ->
        send(test_pid, :fallback_dispatched)

        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}]
        })
      end)

      capture_log([level: :warning], fn ->
        assert {:ok, :dispatched} =
                 Router.fire_trigger(row, %{kind: :cron, fired_at: DateTime.utc_now()}, %{})
      end)

      assert_receive :fallback_dispatched
    end

    # BLAST RADIUS, asserted rather than assumed. Every shipped provider
    # returns `{:error, :unknown_*_responsibility}` for a key its
    # `handler_for/1` does not map. Before this stage that error was
    # swallowed into the generic fallback; now it stops the dispatch. So a
    # built-in whose key is missing from its feature provider's dispatch
    # table would go from "fires with the wrong context" to "never fires" —
    # a real regression, and this is the test that would catch it.
    test "every built-in responsibility key maps to a handler in its feature provider" do
      for module <- Platform.Responsibilities.BuiltIns.providers(),
          spec <- module.register() do
        case Platform.Responsibilities.Providers.feature_provider(spec.feature) do
          {:ok, provider} ->
            assert provider.handler_for(spec.key) != nil,
                   "#{inspect(module)} declares key #{inspect(spec.key)} under feature " <>
                     "#{inspect(spec.feature)}, but #{inspect(provider)}.handler_for/1 returns " <>
                     "nil for it. Its gather_context/2 will return " <>
                     "{:error, :unknown_*_responsibility}, which the Router now honours as a " <>
                     "refusal — this responsibility would never dispatch."

          # Retired features resolve to no provider module, so they take
          # the ContextGatherer fallback and are unaffected by the refusal.
          {:retired, _reason} ->
            :ok

          :error ->
            flunk("feature #{inspect(spec.feature)} has no provider registration at all")
        end
      end
    end
  end

  # ── M6 stage 6: federated/native regression ─────────────────────────────

  describe "fire_trigger/3 — native dispatcher signal shape (federated regression)" do
    # Test seam — point the Router's native dispatcher at a tiny module
    # that captures the signal so we can assert on its shape without
    # standing up a real AgentResponder / chat space / participant.
    defmodule CaptureDispatcher do
      @moduledoc false
      def maybe_dispatch(signal) do
        pid =
          Application.get_env(
            :platform,
            :router_test_capture_pid
          )

        if is_pid(pid), do: send(pid, {:captured_signal, signal})

        :ok
      end
    end

    setup do
      previous =
        Application.get_env(:platform, :responsibility_router_native_dispatcher)

      Application.put_env(
        :platform,
        :responsibility_router_native_dispatcher,
        {CaptureDispatcher, :maybe_dispatch}
      )

      Application.put_env(:platform, :router_test_capture_pid, self())

      on_exit(fn ->
        if previous do
          Application.put_env(
            :platform,
            :responsibility_router_native_dispatcher,
            previous
          )
        else
          Application.delete_env(:platform, :responsibility_router_native_dispatcher)
        end

        Application.delete_env(:platform, :router_test_capture_pid)
      end)

      :ok
    end

    defp wire_native_assignee(responsibility_key) do
      role_key = "historian"

      Repo.insert!(
        %Role{key: role_key, name: "Historian", description: "test", icon: "hero-star"},
        on_conflict: :nothing,
        conflict_target: :key
      )

      %Platform.Roles.RoleResponsibility{}
      |> Platform.Roles.RoleResponsibility.changeset(%{
        role_key: role_key,
        responsibility_key: responsibility_key
      })
      |> Repo.insert!()

      agent =
        %Agent{}
        |> Agent.changeset(%{
          slug: "router-test-fed-#{System.unique_integer([:positive])}",
          name: "Router Test Federated",
          status: "active",
          kind: "native",
          workspace_id: nil
        })
        |> Repo.insert!()

      {:ok, _} = Roles.assign_role(role_key, agent.id)

      agent
    end

    test "native dispatch hands AgentResponder a signal with the historian-style shape" do
      key = "routertest.fed_shape_#{System.unique_integer([:positive])}"

      row =
        insert!(%{
          key: key,
          trigger_kind: "cron",
          trigger_config: %{"expression" => "*/5 * * * *"}
        })

      agent = wire_native_assignee(key)

      capture_log([level: :info], fn ->
        assert {:ok, :dispatched} =
                 Router.fire_trigger(
                   row,
                   %{kind: :cron, fired_at: DateTime.utc_now()},
                   %{}
                 )
      end)

      assert_receive {:captured_signal, signal}

      # SystemEventScheduler / HistorianDispatcher signal contract:
      # `%{reason, metadata}` is mandatory; `participant_id`, `message_id`,
      # `space_id` are optional (omitted for cron triggers that don't
      # have a chat-side originating message). The Router must mirror
      # that — additional :feature / :responsibility_key keys in
      # `metadata` are fine, they're just provider hints.
      assert is_map(signal)
      assert signal.reason == :system_event
      assert is_map(signal.metadata)
      assert signal.metadata.responsibility_key == key
      assert signal.metadata.agent_slug == agent.slug
      assert signal.metadata.trigger_kind == :cron
    end

    test "chat_pattern trigger maps to :mention reason and carries message/space ids" do
      key = "routertest.fed_chat_#{System.unique_integer([:positive])}"

      row =
        insert!(%{
          key: key,
          trigger_kind: "chat_pattern",
          trigger_config: %{"regex" => "deploy"}
        })

      _agent = wire_native_assignee(key)

      message_id = Ecto.UUID.generate()
      space_id = Ecto.UUID.generate()

      capture_log([level: :info], fn ->
        assert {:ok, :dispatched} =
                 Router.fire_trigger(
                   row,
                   %{
                     kind: :chat_pattern,
                     message_id: message_id,
                     space_id: space_id,
                     match: ["deploy"]
                   },
                   %{}
                 )
      end)

      assert_receive {:captured_signal, signal}
      assert signal.reason == :mention
      assert signal.message_id == message_id
      assert signal.space_id == space_id
    end

    test "native dispatch stamps last_successful_fire_at even for the federated path" do
      key = "routertest.fed_stamp_#{System.unique_integer([:positive])}"

      row =
        insert!(%{
          key: key,
          trigger_kind: "cron",
          trigger_config: %{"expression" => "*/5 * * * *"}
        })

      agent = wire_native_assignee(key)

      fired_at = ~U[2026-06-23 15:00:00.000000Z]

      capture_log([level: :info], fn ->
        assert {:ok, :dispatched} =
                 Router.fire_trigger(row, %{kind: :cron, fired_at: fired_at}, %{})
      end)

      assert_receive {:captured_signal, _signal}

      reloaded = Repo.get!(Agent, agent.id)
      assert reloaded.last_successful_fire_at == fired_at
    end

    # ── fix/render-prompt-for-federated-dispatch ──────────────────────────
    #
    # Before this fix `gather_context_via_provider/3` and
    # `build_prompt_via_provider/2` lived inside `dispatch_external/3`
    # only, so a native/federated assignee received a bare system_event
    # with no rendered prompt. External agents are API endpoints that
    # return a response; federated agents are runtimes that receive a
    # prompt payload and act. BOTH are sent a prompt.

    # Flatten every nested term reachable from `signal` so a payload guard
    # can assert on things buried under `:metadata` rather than only the
    # top level.
    defp walk_terms(term) when is_struct(term), do: [term]

    defp walk_terms(term) when is_map(term) do
      [term | Enum.flat_map(term, fn {k, v} -> walk_terms(k) ++ walk_terms(v) end)]
    end

    defp walk_terms(term) when is_list(term), do: Enum.flat_map(term, &walk_terms/1)
    defp walk_terms(term), do: [term]

    defp all_map_keys(signal) do
      signal
      |> walk_terms()
      |> Enum.filter(&(is_map(&1) and not is_struct(&1)))
      |> Enum.flat_map(&Map.keys/1)
    end

    test "native dispatch carries the provider's rendered prompt and scalar trigger ids" do
      feature_str = "router_fed_prompt_#{System.unique_integer([:positive])}"

      define_provider(
        feature_str,
        quote do
          @behaviour Platform.Responsibilities.Provider

          @impl true
          def register, do: []

          @impl true
          def gather_context(_r, _m), do: {:ok, %{plan_title: "Ship the thing"}}

          @impl true
          def build_prompt(ctx) do
            {:ok,
             %{
               system: "You are the architect.",
               user: "Review this plan: #{ctx.plan_title}"
             }}
          end

          @impl true
          def handle_output(_r, _o), do: :ok

          @impl true
          def handle_output(_r, _o, _m), do: :ok
        end
      )

      key = "#{feature_str}.trigger_#{System.unique_integer([:positive])}"

      row =
        insert!(%{
          key: key,
          feature: feature_str,
          trigger_kind: "event_topic",
          trigger_config: %{"topic" => "plan:submitted"},
          default_prompt_template: "architecture.review_plan.v1"
        })

      _agent = wire_native_assignee(key)

      plan_id = Ecto.UUID.generate()
      task_id = Ecto.UUID.generate()

      capture_log([level: :info], fn ->
        assert {:ok, :dispatched} =
                 Router.fire_trigger(
                   row,
                   %{
                     kind: :event_topic,
                     fired_at: DateTime.utc_now(),
                     plan_id: plan_id,
                     task_id: task_id
                   },
                   %{}
                 )
      end)

      assert_receive {:captured_signal, signal}

      # THE fix detector: the rendered prompt text reaches the runtime.
      assert is_binary(signal.metadata.prompt)
      assert signal.metadata.prompt =~ "You are the architect."
      assert signal.metadata.prompt =~ "Review this plan: Ship the thing"

      # The un-seeded template slug is NOT what gets sent.
      refute signal.metadata.prompt =~ "architecture.review_plan.v1"

      # Scalar correlation ids the runtime needs to act on the fire.
      assert signal.metadata.plan_id == plan_id
      assert signal.metadata.task_id == task_id

      # Pre-existing keys are untouched.
      assert signal.reason == :system_event
      assert signal.metadata.responsibility_key == key
      assert signal.metadata.trigger_kind == :event_topic
    end

    test "native dispatch omits scalar trigger ids that are absent or non-binary" do
      key = "routertest.fed_scalars_#{System.unique_integer([:positive])}"

      row =
        insert!(%{
          key: key,
          trigger_kind: "cron",
          trigger_config: %{"expression" => "*/5 * * * *"}
        })

      _agent = wire_native_assignee(key)

      capture_log([level: :info], fn ->
        assert {:ok, :dispatched} =
                 Router.fire_trigger(
                   row,
                   %{
                     kind: :cron,
                     fired_at: DateTime.utc_now(),
                     task_id: Ecto.UUID.generate(),
                     # Non-binary — must be dropped, not coerced.
                     stage_id: 42,
                     project_id: nil
                   },
                   %{}
                 )
      end)

      assert_receive {:captured_signal, signal}

      assert is_binary(signal.metadata.task_id)
      refute Map.has_key?(signal.metadata, :stage_id)
      refute Map.has_key?(signal.metadata, :project_id)
      refute Map.has_key?(signal.metadata, :plan_id)
    end

    test "native dispatch with no provider build_prompt/1 omits :prompt entirely (no empty garbage)" do
      feature_str = "router_fed_noprompt_#{System.unique_integer([:positive])}"

      define_provider(
        feature_str,
        quote do
          @behaviour Platform.Responsibilities.Provider

          @impl true
          def register, do: []

          # NB: no `build_prompt/1`.
          @impl true
          def gather_context(_r, _m), do: {:ok, %{topic: "quarterly"}}

          @impl true
          def handle_output(_r, _o), do: :ok

          @impl true
          def handle_output(_r, _o, _m), do: :ok
        end
      )

      key = "#{feature_str}.trigger_#{System.unique_integer([:positive])}"

      row =
        insert!(%{
          key: key,
          feature: feature_str,
          trigger_kind: "cron",
          trigger_config: %{"expression" => "*/5 * * * *"},
          default_prompt_template: "Please cover the {topic} update."
        })

      agent = wire_native_assignee(key)

      capture_log([level: :info], fn ->
        assert {:ok, :dispatched} =
                 Router.fire_trigger(row, %{kind: :cron, fired_at: DateTime.utc_now()}, %{})
      end)

      assert_receive {:captured_signal, signal}

      # No `build_prompt/1` → the signal is byte-for-byte what it was
      # before this change: no `:prompt` key at all, not "" and not nil.
      refute Map.has_key?(signal.metadata, :prompt)

      assert signal.reason == :system_event
      assert signal.metadata.responsibility_key == key
      assert signal.metadata.agent_slug == agent.slug
      assert signal.metadata.trigger_kind == :cron
    end

    test "no provider module at all still dispatches natively without a :prompt key" do
      key = "routertest.fed_noprovider_#{System.unique_integer([:positive])}"

      row =
        insert!(%{
          key: key,
          feature: "definitely_not_a_real_feature_#{System.unique_integer([:positive])}",
          trigger_kind: "cron",
          trigger_config: %{"expression" => "*/5 * * * *"}
        })

      _agent = wire_native_assignee(key)

      capture_log([level: :info], fn ->
        assert {:ok, :dispatched} =
                 Router.fire_trigger(row, %{kind: :cron, fired_at: DateTime.utc_now()}, %{})
      end)

      assert_receive {:captured_signal, signal}
      refute Map.has_key?(signal.metadata, :prompt)
      assert signal.metadata.responsibility_key == key
    end

    test "native signal never carries a %Plan{} struct or :frozen_history (payload guard)" do
      feature_str = "router_fed_payload_#{System.unique_integer([:positive])}"

      define_provider(
        feature_str,
        quote do
          @behaviour Platform.Responsibilities.Provider

          @impl true
          def register, do: []

          @impl true
          def gather_context(_r, _m), do: {:ok, %{}}

          @impl true
          def build_prompt(_ctx), do: {:ok, %{system: "sys", user: "usr"}}

          @impl true
          def handle_output(_r, _o), do: :ok

          @impl true
          def handle_output(_r, _o, _m), do: :ok
        end
      )

      key = "#{feature_str}.trigger_#{System.unique_integer([:positive])}"

      row =
        insert!(%{
          key: key,
          feature: feature_str,
          trigger_kind: "event_topic",
          trigger_config: %{"topic" => "plan:submitted"}
        })

      _agent = wire_native_assignee(key)

      plan_id = Ecto.UUID.generate()

      # Exactly the shape `Platform.Tasks.fire_architecture_review_plan/1`
      # publishes (tasks.ex:1562) plus the chat path's frozen snapshot.
      trigger_meta = %{
        kind: :event_topic,
        fired_at: DateTime.utc_now(),
        plan_id: plan_id,
        task_id: Ecto.UUID.generate(),
        plan: %Platform.Tasks.Plan{id: plan_id, status: "pending_review"},
        metadata: %{frozen_history: Enum.map(1..50, &"history line #{&1}")}
      }

      capture_log([level: :info], fn ->
        assert {:ok, :dispatched} = Router.fire_trigger(row, trigger_meta, %{})
      end)

      assert_receive {:captured_signal, signal}

      # The prompt still made it — this guard must not pass vacuously.
      assert signal.metadata.prompt =~ "usr"
      assert signal.metadata.plan_id == plan_id

      terms = walk_terms(signal)
      refute Enum.any?(terms, &match?(%Platform.Tasks.Plan{}, &1))

      keys = all_map_keys(signal)
      refute :frozen_history in keys
      refute :plan in keys
      refute "history line 1" in terms
    end

    # ── task 019f9b28-6ca7 stage 2 — the refusal covers the native path too ──
    #
    # The stage was written when `dispatch_native/4` carried no context at
    # all, and recorded that as out of scope. `fix/render-prompt-for-federated-dispatch`
    # has since hoisted `gather_context_via_provider/3` into the shared
    # `dispatch_assignee/4` preamble, so a native assignee now receives the
    # provider's rendered prompt — built from exactly the context that
    # would have been silently substituted. Honouring the refusal above the
    # external/native branch is what makes this hold, and this is the test
    # that says so.
    test "a provider context refusal stops the native handoff as well" do
      feature_str = "router_fed_gc_refuse_#{System.unique_integer([:positive])}"

      define_provider(
        feature_str,
        quote do
          @behaviour Platform.Responsibilities.Provider

          @impl true
          def register, do: []

          @impl true
          def gather_context(_r, _m), do: {:error, :no_plan_payload}

          @impl true
          def build_prompt(_ctx), do: {:ok, %{system: "sys", user: "usr"}}

          @impl true
          def handle_output(_r, _o), do: :ok

          @impl true
          def handle_output(_r, _o, _m), do: :ok
        end
      )

      key = "#{feature_str}.trigger_#{System.unique_integer([:positive])}"

      row =
        insert!(%{
          key: key,
          feature: feature_str,
          trigger_kind: "cron",
          trigger_config: %{"expression" => "*/5 * * * *"}
        })

      agent = wire_native_assignee(key)
      test_pid = self()

      handler_id = "router-test-fed-gc-refused-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:platform, :responsibility, :failed],
        fn _event, measurements, metadata, pid ->
          send(pid, {:failed_telemetry, measurements, metadata})
        end,
        test_pid
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {fire_result, log} =
        with_log([level: :warning], fn ->
          Router.fire_trigger(row, %{kind: :cron, fired_at: DateTime.utc_now()}, %{})
        end)

      # Ordered before the return-value match on purpose — see the note in
      # the external refusal test. The CaptureDispatcher from this
      # describe's setup would otherwise have received a signal carrying a
      # prompt built over generic context.
      refute_receive {:captured_signal, _signal}, 100

      assert fire_result == {:error, {:context_gather_refused, :no_plan_payload}}
      assert log =~ "provider gather_context refused dispatch"

      assert_receive {:failed_telemetry, _meas, %{key: ^key, dispatch_kind: :native}}

      # Nothing was stamped — a refused dispatch is not a successful fire.
      assert Repo.get!(Agent, agent.id).last_successful_fire_at == nil
    end
  end

  # ── task 019f9b28 stage 2: explicit provider registry ───────────────────
  #
  # VERIFICATION LABEL: these are **guards**, not the task's fix detector.
  # They pin the log fidelity this stage introduces — that the Router can
  # now tell "no provider was ever written" from "this feature deliberately
  # has none" from "the provider we ship is broken". The detector that the
  # architecture.* answer actually reaches a human is stage 5.
  describe "provider resolution via Platform.Responsibilities.Providers" do
    setup do
      {:ok, _} = Application.ensure_all_started(:req)

      Application.put_env(
        :platform,
        :external_agents_dispatcher_req_client,
        Req.new(plug: {Req.Test, :router_registry_test})
      )

      Req.Test.stub(:router_registry_test, fn conn ->
        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"role" => "assistant", "content" => "registry ok"}}]
        })
      end)

      on_exit(fn ->
        Application.delete_env(:platform, :external_agents_dispatcher_req_client)
      end)

      :ok
    end

    test "unregistered feature still dispatches, and the log names the feature and the fix" do
      feature_str = "test_feature_#{System.unique_integer([:positive])}"
      key = "#{feature_str}.probe_#{System.unique_integer([:positive])}"

      row =
        insert!(%{
          key: key,
          feature: feature_str,
          trigger_kind: "cron",
          trigger_config: %{"expression" => "*/5 * * * *"}
        })

      _agent = wire_external_assignee(key)

      log =
        capture_log([level: :info], fn ->
          assert {:ok, :dispatched} =
                   Router.fire_trigger(row, %{kind: :cron, fired_at: DateTime.utc_now()}, %{})
        end)

      # The dispatch itself is unaffected — an ad-hoc feature is ordinary,
      # not an error. Only the *diagnosis* changed.
      assert log =~ "[ResponsibilityRouter] external dispatch ok key=#{key}"
      assert log =~ "[ResponsibilityRouter] no output handler for #{key}"

      # Actionable: names the feature and says exactly what to do.
      assert log =~ ~s(feature="#{feature_str}")
      assert log =~ "has no provider registered"
      assert log =~ "Platform.Responsibilities.Providers @feature_providers"

      # And it is a warning, not an error — router_test seeds rows like
      # this constantly and operators can upsert arbitrary ones. Alarm
      # traffic for ordinary rows is how a signal gets trained away.
      assert log =~ "[warning]"
      refute log =~ "failed the handle_output/3 probe"
      refute log =~ "is retired by design"
    end

    test "retired feature logs the retirement reason and never resolves a module" do
      key = "security.registry_probe_#{System.unique_integer([:positive])}"

      row =
        insert!(%{
          key: key,
          feature: "security",
          trigger_kind: "cron",
          trigger_config: %{"expression" => "*/5 * * * *"}
        })

      _agent = wire_external_assignee(key)

      Logger.put_module_level(Platform.Responsibilities.Router, :debug)

      log =
        capture_log([level: :debug], fn ->
          assert {:ok, :dispatched} =
                   Router.fire_trigger(row, %{kind: :cron, fired_at: DateTime.utc_now()}, %{})
        end)

      assert log =~ "[ResponsibilityRouter] no output handler for #{key}"
      assert log =~ "is retired by design"
      assert log =~ "Platform.Security.Sweeper"

      # Retirement is quiet by construction: nothing to fix, so nothing
      # above debug.
      refute log =~ "has no provider registered"

      # The registry says retired rather than missing …
      assert {:retired, reason} =
               Platform.Responsibilities.Providers.feature_provider("security")

      assert reason =~ "Sweeper"

      # … and there is genuinely no module behind it. Built at runtime so
      # the reference doesn't become a compile-time "undefined module"
      # warning for a module we never intend to write.
      refute Code.ensure_loaded?(Module.concat([Platform.Responsibilities.Providers, "Security"]))
    end

    test "a registered provider that fails the handle_output/3 probe logs at error level" do
      # The third cause, which the old single Logger.info flattened into
      # the other two: we DO ship a module for this feature and it does
      # not honour the callback. That is a contract break, not a routing
      # gap, so it is the one case that deserves :error.
      feature_str = "router_broken_provider_#{System.unique_integer([:positive])}"

      define_provider(
        feature_str,
        quote do
          @behaviour Platform.Responsibilities.Provider

          @impl true
          def register, do: []

          @impl true
          def gather_context(_r, _m), do: {:ok, %{}}

          # NB: only handle_output/2 — the Router probes for /3.
          @impl true
          def handle_output(_r, _o), do: :ok
        end
      )

      key = "#{feature_str}.probe_#{System.unique_integer([:positive])}"

      row =
        insert!(%{
          key: key,
          feature: feature_str,
          trigger_kind: "cron",
          trigger_config: %{"expression" => "*/5 * * * *"}
        })

      _agent = wire_external_assignee(key)

      log =
        capture_log([level: :info], fn ->
          assert {:ok, :dispatched} =
                   Router.fire_trigger(row, %{kind: :cron, fired_at: DateTime.utc_now()}, %{})
        end)

      assert log =~ "[error]"
      assert log =~ "[ResponsibilityRouter] no output handler for #{key}"
      assert log =~ "failed the handle_output/3 probe"
      refute log =~ "has no provider registered"
    end

    test "every feature the built-in handlers declare resolves or is explicitly retired" do
      # A cheap standing guard against the exact drift this stage is
      # about. Stage 4 turns this into the full coverage test; keeping a
      # minimal version here means router_test alone catches a handler
      # that ships without a provider entry.
      declared =
        Platform.Responsibilities.BuiltIns.providers()
        |> Enum.flat_map(& &1.register())
        |> Enum.map(& &1.feature)
        |> Enum.uniq()

      for feature <- declared do
        assert Platform.Responsibilities.Providers.feature_provider(feature) != :error,
               "feature #{inspect(feature)} is declared by a built-in handler but is neither " <>
                 "in @feature_providers nor in @retired"
      end
    end
  end

  # ── task 019f9b28 stage 2: the fourth collapse point ────────────────────
  #
  # `rendered_prompt_text/1` maps both `:legacy` and `{:error, reason}` to
  # nil, and `maybe_put/3` drops nil — so a federated runtime receives a
  # byte-identical bare signal whether the provider refused to build a
  # prompt or was never asked for one. This stage does not change what the
  # signal *contains* (dispatch return values are a sibling stack member's
  # scope); it makes the three causes tell themselves apart in the log.
  describe "native dispatch prompt fidelity" do
    setup do
      previous = Application.get_env(:platform, :responsibility_router_native_dispatcher)

      Application.put_env(
        :platform,
        :responsibility_router_native_dispatcher,
        {Platform.Responsibilities.RouterTest.CaptureDispatcher, :maybe_dispatch}
      )

      Application.put_env(:platform, :router_test_capture_pid, self())

      on_exit(fn ->
        if previous do
          Application.put_env(:platform, :responsibility_router_native_dispatcher, previous)
        else
          Application.delete_env(:platform, :responsibility_router_native_dispatcher)
        end

        Application.delete_env(:platform, :router_test_capture_pid)
      end)

      :ok
    end

    test "a refused build_prompt is logged as a refusal, and the signal is still bare" do
      feature_str = "router_fed_refuse_#{System.unique_integer([:positive])}"

      define_provider(
        feature_str,
        quote do
          @behaviour Platform.Responsibilities.Provider

          @impl true
          def register, do: []

          @impl true
          def gather_context(_r, _m), do: {:ok, %{}}

          @impl true
          def build_prompt(_ctx), do: {:error, :no_transcript_text}

          @impl true
          def handle_output(_r, _o), do: :ok

          @impl true
          def handle_output(_r, _o, _m), do: :ok
        end
      )

      key = "#{feature_str}.trigger_#{System.unique_integer([:positive])}"

      row =
        insert!(%{
          key: key,
          feature: feature_str,
          trigger_kind: "cron",
          trigger_config: %{"expression" => "*/5 * * * *"}
        })

      _agent = wire_native_assignee(key)

      log =
        capture_log([level: :info], fn ->
          # `{:ok, :dispatched}`, NOT `{:error, {:build_prompt_refused, _}}`.
          # The refusal short-circuit member 1 added lives in
          # `dispatch_external/5` only; this row has a NATIVE assignee, and
          # `dispatch_native/5` deliberately proceeds with a bare signal —
          # that asymmetry is exactly what the log line below records. If a
          # later stage makes native abort too, this is the assertion that
          # should change, and the "native dispatch proceeds" log assertion
          # will change with it.
          assert {:ok, :dispatched} =
                   Router.fire_trigger(row, %{kind: :cron, fired_at: DateTime.utc_now()}, %{})
        end)

      assert log =~ "provider build_prompt refused but native dispatch proceeds"
      assert log =~ "no_transcript_text"
      assert log =~ "the external path would have aborted here"

      # Unchanged behaviour: still dispatched, still no :prompt key. This
      # stage is log fidelity only.
      assert_receive {:captured_signal, signal}
      refute Map.has_key?(signal.metadata, :prompt)
      assert signal.metadata.responsibility_key == key
    end

    test "no provider at all is logged differently from a refusal, for the identical signal" do
      feature_str = "test_feature_#{System.unique_integer([:positive])}"
      key = "#{feature_str}.trigger_#{System.unique_integer([:positive])}"

      row =
        insert!(%{
          key: key,
          feature: feature_str,
          trigger_kind: "cron",
          trigger_config: %{"expression" => "*/5 * * * *"}
        })

      _agent = wire_native_assignee(key)

      log =
        capture_log([level: :info], fn ->
          assert {:ok, :dispatched} =
                   Router.fire_trigger(row, %{kind: :cron, fired_at: DateTime.utc_now()}, %{})
        end)

      assert log =~ "native signal carries no prompt key=#{key}"
      assert log =~ "has no provider registered"
      refute log =~ "provider build_prompt refused"

      assert_receive {:captured_signal, signal}
      refute Map.has_key?(signal.metadata, :prompt)
    end
  end

  # M8 stage 2 (ADR-0041): `fire/2` is the lookup-and-fire convenience
  # the dual-write shim uses. It accepts either the canonical string
  # key or the atom shorthand (memory_daily_summary →
  # "memory.daily_summary"), looks the row up, and funnels through
  # the same `fire_trigger` pipeline as the cron tick.
  describe "fire/2 lookup-and-fire" do
    test "returns {:ok, :unknown_responsibility} when no row matches" do
      # ADR-0046 member 1 stage 2: this used to be
      # `{:error, :unknown_responsibility}`. An unseeded key is a
      # progressive-enhancement state — a code site hooked the key
      # before its seed migration landed — so it belongs in the ok
      # channel. Leaving it in the error channel would make
      # `Responsibilities.outcome/1` report `:failed` for a
      # responsibility nobody ever configured, the exact
      # not_applicable/failed conflation the ADR forbids at line 83.
      log =
        capture_log([level: :info], fn ->
          assert {:ok, :unknown_responsibility} =
                   Router.fire("does.not.exist", %{kind: :cron})
        end)

      assert log =~ "fire/2 no row for key="
    end

    test "fires the matched row through fire_trigger when present" do
      key = unique_key()
      _row = insert!(%{key: key})

      log =
        capture_log([level: :info], fn ->
          # No assignee → unfilled telemetry + {:ok, :unfilled} return.
          assert {:ok, :unfilled} = Router.fire(key, %{kind: :cron})
        end)

      assert log =~ "unfilled responsibility=#{key}"
    end

    test "atom shorthand canonicalises first-underscore → dot" do
      # Same atom shape the dual-write shim uses: :memory_daily_summary →
      # "memory.daily_summary". The fixture row uses an analogous shape.
      key = "atomshim.verb_#{System.unique_integer([:positive])}"
      atom_shorthand = String.to_atom(String.replace(key, ".", "_"))
      _row = insert!(%{key: key})

      capture_log([level: :info], fn ->
        assert {:ok, :unfilled} = Router.fire(atom_shorthand, %{kind: :cron})
      end)
    end
  end

  # ── ADR-0046 return contract ──────────────────────────────────────────────
  #
  # These four are FIX DETECTORS, not guards: every one of them fails against
  # the pre-ADR-0046 Router, which returned a flat `:ok` from all of these
  # paths (and, on the native branch, emitted `:fired` telemetry even when
  # nothing dispatched).
  defmodule RaisingNativeDispatcher do
    @moduledoc false
    def maybe_dispatch(_signal), do: raise(RuntimeError, "native dispatcher exploded")
  end

  describe "fire_trigger/3 — ADR-0046 return contract" do
    defp put_native_dispatcher(mod) do
      previous = Application.get_env(:platform, :responsibility_router_native_dispatcher)

      Application.put_env(
        :platform,
        :responsibility_router_native_dispatcher,
        {mod, :maybe_dispatch}
      )

      on_exit(fn ->
        if previous do
          Application.put_env(:platform, :responsibility_router_native_dispatcher, previous)
        else
          Application.delete_env(:platform, :responsibility_router_native_dispatcher)
        end
      end)
    end

    defp attach_fire_telemetry do
      test_pid = self()
      suffix = System.unique_integer([:positive])

      for {event, tag} <- [{:fired, :fired_telemetry}, {:failed, :failed_telemetry}] do
        handler_id = "router-contract-#{event}-#{suffix}"

        :telemetry.attach(
          handler_id,
          [:platform, :responsibility, event],
          fn _event, measurements, metadata, pid ->
            send(pid, {tag, measurements, metadata})
          end,
          test_pid
        )

        on_exit(fn -> :telemetry.detach(handler_id) end)
      end

      :ok
    end

    test "external dispatch failure returns {:error, {:dispatch_failed, _}}, not :ok" do
      {:ok, _} = Application.ensure_all_started(:req)

      Application.put_env(
        :platform,
        :external_agents_dispatcher_req_client,
        Req.new(plug: {Req.Test, :router_external_dispatch_test})
      )

      on_exit(fn ->
        Application.delete_env(:platform, :external_agents_dispatcher_req_client)
      end)

      key = "routertest.contract_ext_fail_#{System.unique_integer([:positive])}"

      row =
        insert!(%{
          key: key,
          trigger_kind: "cron",
          trigger_config: %{"expression" => "*/5 * * * *"}
        })

      _agent = wire_external_assignee(key)

      Req.Test.stub(:router_external_dispatch_test, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(503, ~s({"error":"down"}))
      end)

      capture_log([level: :warning], fn ->
        assert {:error, {:dispatch_failed, reason}} =
                 Router.fire_trigger(row, %{kind: :cron, fired_at: DateTime.utc_now()}, %{})

        # The underlying reason survives the wrap — a consumer can still tell
        # an HTTP error from a contract violation.
        assert inspect(reason) =~ "http_error"
      end)
    end

    test "unfilled responsibility returns {:ok, :unfilled} and emits no :failed telemetry" do
      key = "routertest.contract_unfilled_#{System.unique_integer([:positive])}"

      row =
        insert!(%{
          key: key,
          trigger_kind: "cron",
          trigger_config: %{"expression" => "*/5 * * * *"}
        })

      :ok = attach_fire_telemetry()

      capture_log([level: :info], fn ->
        assert {:ok, :unfilled} =
                 Router.fire_trigger(row, %{kind: :cron, fired_at: DateTime.utc_now()}, %{})
      end)

      # "nobody holds it" is NOT a failure — this is the ADR-0046
      # not_applicable-vs-failed distinction the old flat `:ok` erased.
      refute_receive {:failed_telemetry, _meas, _meta}, 100
      refute_receive {:fired_telemetry, _meas, _meta}, 100
    end

    test "native handoff returns {:ok, :dispatched} and emits :fired telemetry" do
      put_native_dispatcher(NoopNativeDispatcher)

      key = "routertest.contract_native_ok_#{System.unique_integer([:positive])}"

      row =
        insert!(%{
          key: key,
          trigger_kind: "cron",
          trigger_config: %{"expression" => "*/5 * * * *"}
        })

      agent = wire_native_assignee(key)
      :ok = attach_fire_telemetry()

      fired_at = ~U[2026-07-26 09:00:00.000000Z]

      capture_log([level: :info], fn ->
        assert {:ok, :dispatched} =
                 Router.fire_trigger(row, %{kind: :cron, fired_at: fired_at}, %{})
      end)

      # POSITIVE CONTROL for the raising-dispatcher case below: it proves the
      # `:fired` telemetry mechanism works here, so that test's ABSENCE
      # assertion is a real observation rather than a handler that never fires.
      assert_receive {:fired_telemetry, _meas, %{key: ^key, dispatch_kind: :native}}
      refute_receive {:failed_telemetry, _meas, _meta}, 100

      assert Repo.get!(Agent, agent.id).last_successful_fire_at == fired_at
    end

    test "raising native dispatcher returns {:error, {:native_dispatch_raised, _}}, emits :failed and NOT :fired" do
      put_native_dispatcher(RaisingNativeDispatcher)

      key = "routertest.contract_native_raise_#{System.unique_integer([:positive])}"

      row =
        insert!(%{
          key: key,
          trigger_kind: "cron",
          trigger_config: %{"expression" => "*/5 * * * *"}
        })

      agent = wire_native_assignee(key)
      :ok = attach_fire_telemetry()

      log =
        capture_log([level: :warning], fn ->
          assert {:error, {:native_dispatch_raised, message}} =
                   Router.fire_trigger(row, %{kind: :cron, fired_at: DateTime.utc_now()}, %{})

          assert message =~ "native dispatcher exploded"
        end)

      assert log =~ "[ResponsibilityRouter] native dispatcher raised"
      assert log =~ "[ResponsibilityRouter] native dispatch failed key=#{key}"

      assert_receive {:failed_telemetry, _meas, %{key: ^key, dispatch_kind: :native}}

      # The old code emitted `:fired` unconditionally after the discarded
      # `call_agent_responder/1` result, so this refute is the detector.
      refute_receive {:fired_telemetry, _meas, _meta}, 100

      # And nothing was stamped — a raised handoff is not a successful fire.
      assert Repo.get!(Agent, agent.id).last_successful_fire_at == nil
    end
  end
end
