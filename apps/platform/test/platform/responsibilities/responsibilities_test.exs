defmodule Platform.ResponsibilitiesTest do
  @moduledoc """
  Context-level tests for `Platform.Responsibilities` — CRUD plus the
  `upsert_by_key/1` idempotency / operator-state-preservation
  contract (ADR-0041 M1 stage 2) and the `fire/2` dispatch delegate
  (ADR-0044 stage 2).
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  doctest Platform.Responsibilities, only: [outcome: 1]

  alias Platform.Agents.Agent
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.Responsibility
  alias Platform.Roles
  alias Platform.Roles.Role

  defp unique_key(prefix \\ "feat") do
    "#{prefix}.verb_#{System.unique_integer([:positive])}"
  end

  defp base_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        key: unique_key(),
        feature: "feat",
        trigger_kind: "cron",
        trigger_config: %{"expression" => "*/5 * * * *"},
        scope: "global",
        context_provided: [],
        output_contract: %{"summary" => "string"},
        default_prompt_template: "feat.summarize.v1",
        cost_profile: "low_freq_capable"
      },
      overrides
    )
  end

  describe "list_responsibilities/0" do
    test "returns rows ordered ascending by key" do
      {:ok, _} = Responsibilities.create_responsibility(base_attrs(%{key: "alpha.one"}))
      {:ok, _} = Responsibilities.create_responsibility(base_attrs(%{key: "charlie.three"}))
      {:ok, _} = Responsibilities.create_responsibility(base_attrs(%{key: "bravo.two"}))

      keys = Responsibilities.list_responsibilities() |> Enum.map(& &1.key)

      # Filter to just the three we inserted (other tests may have leaked).
      ours = Enum.filter(keys, &(&1 in ["alpha.one", "bravo.two", "charlie.three"]))
      assert ours == ["alpha.one", "bravo.two", "charlie.three"]
    end

    test "returns empty list when no rows exist" do
      assert Responsibilities.list_responsibilities() == []
    end
  end

  describe "list_by_feature/1" do
    test "returns only rows for the named feature, ordered by key" do
      {:ok, _} =
        Responsibilities.create_responsibility(
          base_attrs(%{feature: "meetings", key: "meetings.b"})
        )

      {:ok, _} =
        Responsibilities.create_responsibility(
          base_attrs(%{feature: "meetings", key: "meetings.a"})
        )

      {:ok, _} =
        Responsibilities.create_responsibility(base_attrs(%{feature: "chat", key: "chat.z"}))

      meetings = Responsibilities.list_by_feature("meetings")
      assert Enum.map(meetings, & &1.feature) |> Enum.uniq() == ["meetings"]
      assert Enum.map(meetings, & &1.key) == ["meetings.a", "meetings.b"]
    end

    test "empty list on miss" do
      assert Responsibilities.list_by_feature("does_not_exist") == []
    end
  end

  describe "get/1" do
    test "returns the row by id" do
      {:ok, %Responsibility{id: id} = inserted} =
        Responsibilities.create_responsibility(base_attrs())

      assert %Responsibility{id: ^id, key: key} = Responsibilities.get(id)
      assert key == inserted.key
    end

    test "returns nil when id is unknown" do
      assert Responsibilities.get("00000000-0000-0000-0000-000000000000") == nil
    end
  end

  describe "get_by_key/1" do
    test "returns the matching row" do
      key = unique_key("meetings")
      {:ok, _} = Responsibilities.create_responsibility(base_attrs(%{key: key}))

      assert %Responsibility{key: ^key} = Responsibilities.get_by_key(key)
    end

    test "returns nil when no row carries that key" do
      assert Responsibilities.get_by_key("nope.miss") == nil
    end
  end

  describe "get_by_trigger/1" do
    test "filters by trigger_kind AND by enabled=true" do
      enabled_key = unique_key("ev")
      disabled_key = unique_key("ev")

      {:ok, _} =
        Responsibilities.create_responsibility(
          base_attrs(%{
            key: enabled_key,
            trigger_kind: "event_topic",
            trigger_config: %{"topic" => "demo:enabled"}
          })
        )

      {:ok, disabled} =
        Responsibilities.create_responsibility(
          base_attrs(%{
            key: disabled_key,
            trigger_kind: "event_topic",
            trigger_config: %{"topic" => "demo:disabled"}
          })
        )

      {:ok, _} = Responsibilities.update_responsibility(disabled, %{enabled: false})

      rows = Responsibilities.get_by_trigger(:event_topic)
      keys = Enum.map(rows, & &1.key)

      assert enabled_key in keys, "expected the enabled row to come back"
      refute disabled_key in keys, "disabled rows must be filtered out"
    end

    test "filters out other trigger_kinds" do
      cron_key = unique_key("cron")
      webhook_key = unique_key("wh")

      {:ok, _} =
        Responsibilities.create_responsibility(
          base_attrs(%{
            key: cron_key,
            trigger_kind: "cron",
            trigger_config: %{"expression" => "0 0 * * *"}
          })
        )

      {:ok, _} =
        Responsibilities.create_responsibility(
          base_attrs(%{
            key: webhook_key,
            trigger_kind: "webhook",
            trigger_config: %{"path" => "/hooks/x"}
          })
        )

      cron_rows = Responsibilities.get_by_trigger(:cron) |> Enum.map(& &1.key)
      webhook_rows = Responsibilities.get_by_trigger(:webhook) |> Enum.map(& &1.key)
      chat_rows = Responsibilities.get_by_trigger(:chat_pattern) |> Enum.map(& &1.key)

      assert cron_key in cron_rows
      refute webhook_key in cron_rows
      assert webhook_key in webhook_rows
      assert chat_rows == []
    end

    test "returns rows ordered ascending by key" do
      a = unique_key("alpha")
      b = unique_key("bravo")

      {:ok, _} =
        Responsibilities.create_responsibility(
          base_attrs(%{
            key: b,
            trigger_kind: "event_topic",
            trigger_config: %{"topic" => "x:b"}
          })
        )

      {:ok, _} =
        Responsibilities.create_responsibility(
          base_attrs(%{
            key: a,
            trigger_kind: "event_topic",
            trigger_config: %{"topic" => "x:a"}
          })
        )

      keys = Responsibilities.get_by_trigger(:event_topic) |> Enum.map(& &1.key)
      ours = Enum.filter(keys, &(&1 in [a, b]))
      assert ours == Enum.sort([a, b])
    end
  end

  describe "create_responsibility/1" do
    test "happy path returns {:ok, %Responsibility{}}" do
      attrs = base_attrs()
      assert {:ok, %Responsibility{} = row} = Responsibilities.create_responsibility(attrs)
      assert row.key == attrs.key
      # Default for `enabled` is true at the schema level.
      assert row.enabled == true
      # Default for `metadata` is the empty map.
      assert row.metadata == %{}
    end

    test "invalid attrs return {:error, %Ecto.Changeset{}}" do
      assert {:error, %Ecto.Changeset{} = cs} =
               Responsibilities.create_responsibility(base_attrs(%{key: "Bad.KEY"}))

      assert Keyword.has_key?(cs.errors, :key)
    end
  end

  describe "update_responsibility/2" do
    test "applies changes via changeset" do
      {:ok, row} = Responsibilities.create_responsibility(base_attrs())

      assert {:ok, updated} =
               Responsibilities.update_responsibility(row, %{
                 default_prompt_template: "feat.summarize.v2"
               })

      assert updated.id == row.id
      assert updated.default_prompt_template == "feat.summarize.v2"
    end

    test "rejects invalid changes" do
      {:ok, row} = Responsibilities.create_responsibility(base_attrs())

      assert {:error, %Ecto.Changeset{} = cs} =
               Responsibilities.update_responsibility(row, %{trigger_kind: "bogus"})

      assert Keyword.has_key?(cs.errors, :trigger_kind)
    end
  end

  describe "delete_responsibility/1" do
    test "removes the row" do
      {:ok, row} = Responsibilities.create_responsibility(base_attrs())
      assert {:ok, _} = Responsibilities.delete_responsibility(row)
      assert Responsibilities.get(row.id) == nil
    end
  end

  describe "upsert_by_key/1" do
    test "first call inserts; second call updates declared content fields in place" do
      key = unique_key("up")

      attrs_v1 =
        base_attrs(%{
          key: key,
          cost_profile: "low_freq_capable",
          default_prompt_template: "feat.summarize.v1",
          metadata: %{"version" => 1}
        })

      assert {:ok, v1} = Responsibilities.upsert_by_key(attrs_v1)
      assert v1.key == key
      assert v1.cost_profile == "low_freq_capable"
      original_id = v1.id

      attrs_v2 =
        base_attrs(%{
          key: key,
          cost_profile: "high_freq_low_cost",
          default_prompt_template: "feat.summarize.v2",
          metadata: %{"version" => 2}
        })

      assert {:ok, v2} = Responsibilities.upsert_by_key(attrs_v2)

      # Same row — original id preserved.
      assert v2.id == original_id

      # Declared content fields updated to the latest declaration.
      assert v2.cost_profile == "high_freq_low_cost"
      assert v2.default_prompt_template == "feat.summarize.v2"
      assert v2.metadata == %{"version" => 2}

      # And the DB really only has one row for this key.
      assert length(
               Responsibilities.list_responsibilities()
               |> Enum.filter(&(&1.key == key))
             ) == 1
    end

    test "preserves operator-set enabled=false across upserts" do
      key = unique_key("up")

      # Provider's first registration — defaults to enabled=true.
      assert {:ok, v1} = Responsibilities.upsert_by_key(base_attrs(%{key: key}))
      assert v1.enabled == true

      # Operator kills the responsibility via the admin path.
      {:ok, _disabled} = Responsibilities.update_responsibility(v1, %{enabled: false})
      assert Responsibilities.get_by_key(key).enabled == false

      # Provider re-registers at next boot — declared attrs would normally
      # come back with enabled=true (the schema default), but upsert must
      # NOT clobber the operator's kill-switch.
      attrs_v2 = base_attrs(%{key: key, cost_profile: "high_freq_low_cost"})
      assert {:ok, v2} = Responsibilities.upsert_by_key(attrs_v2)

      assert v2.id == v1.id
      assert v2.enabled == false, "operator-set enabled=false must survive boot-time upsert"

      # Declared content still updated though.
      assert v2.cost_profile == "high_freq_low_cost"
    end

    test "invalid attrs return {:error, changeset} without raising" do
      assert {:error, %Ecto.Changeset{} = cs} =
               Responsibilities.upsert_by_key(base_attrs(%{key: "Bad.KEY"}))

      assert Keyword.has_key?(cs.errors, :key)
    end
  end

  # ── fire/2 dispatch delegate (ADR-0044 stage 2, ADR-0046 stage 2) ──────
  #
  # `Platform.Responsibilities.fire/2` is a thin delegate to
  # `Platform.Responsibilities.Router.fire/2`. It used to normalise the
  # two "nothing further to do" cases (unknown key + no assignee) — and,
  # as a side effect, every genuine dispatch failure — down to a flat
  # `:ok`. ADR-0046 member 1 stage 2 deleted that normalisation: the
  # Router result now passes through verbatim and `outcome/1` provides
  # the shared mapping onto `complete | not_applicable | failed`.
  #
  # The assertions below that changed from `:ok` to a tagged tuple are
  # GUARDS — they pass either way once updated and only prove the
  # progressive-enhancement paths did not regress. The FIX DETECTOR is
  # the 503 test in the sibling describe block: on the pre-stage-2 code
  # it returns `:ok`.
  describe "fire/2 dispatch delegate" do
    setup do
      Logger.put_module_level(Platform.Responsibilities.Router, :info)
      on_exit(fn -> Logger.delete_module_level(Platform.Responsibilities.Router) end)
      :ok
    end

    test "unknown responsibility key returns {:ok, :unknown_responsibility} (no row seeded)" do
      # GUARD. An unseeded key is a progressive-enhancement state, so it
      # stays in the ok channel — a call site can hook a key before its
      # seed migration lands without stalling the caller. It is now
      # tagged rather than flattened, so ADR-0046 can report
      # `not_applicable` instead of guessing.
      log =
        capture_log([level: :info], fn ->
          assert {:ok, :unknown_responsibility} =
                   Responsibilities.fire("architecture.does_not_exist_yet.v0", %{})
        end)

      assert log =~ "fire/2 no row for key="

      assert Responsibilities.outcome({:ok, :unknown_responsibility}) == :not_applicable
    end

    test "known key with no assignee returns {:ok, :unfilled} and emits :unfilled telemetry" do
      key = "architecture.review_plan_fire_unfilled_#{System.unique_integer([:positive])}"

      {:ok, _row} =
        Responsibilities.create_responsibility(%{
          key: key,
          feature: "architecture",
          trigger_kind: "event_topic",
          trigger_config: %{"topic" => "plan:submitted"},
          scope: "per_project",
          context_provided: [],
          output_contract: %{"comments" => "list[map]"},
          default_prompt_template: "architecture.review_plan.v1",
          cost_profile: "low_freq_capable"
        })

      handler_id = "resp-fire-unfilled-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:platform, :responsibility, :unfilled],
        fn _event, measurements, metadata, pid ->
          send(pid, {:unfilled_telemetry, measurements, metadata})
        end,
        test_pid
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      capture_log([level: :info], fn ->
        # GUARD — unfilled is not a failure and must not leak into the
        # error channel.
        assert {:ok, :unfilled} = Responsibilities.fire(key, %{plan_id: Ecto.UUID.generate()})
      end)

      assert_receive {:unfilled_telemetry, %{system_time: _},
                      %{key: ^key, feature: "architecture"}}
    end

    test "known key with a native assignee dispatches and emits :fired telemetry" do
      key = "architecture.review_plan_fire_native_#{System.unique_integer([:positive])}"

      {:ok, _row} =
        Responsibilities.create_responsibility(%{
          key: key,
          feature: "architecture",
          trigger_kind: "event_topic",
          trigger_config: %{"topic" => "plan:submitted"},
          scope: "per_project",
          context_provided: [],
          output_contract: %{"comments" => "list[map]"},
          default_prompt_template: "architecture.review_plan.v1",
          cost_profile: "low_freq_capable"
        })

      # Reuse `historian` — a canonical seeded role — plus a fresh
      # bundle row pointing at the responsibility under test. The role
      # bundle → assignee resolver path exercises the exact production
      # code path that `submit_plan_for_review/1`'s hook depends on.
      role_key = "historian"

      Repo.insert!(
        %Role{key: role_key, name: "Historian", description: "test", icon: "hero-star"},
        on_conflict: :nothing,
        conflict_target: :key
      )

      %Platform.Roles.RoleResponsibility{}
      |> Platform.Roles.RoleResponsibility.changeset(%{
        role_key: role_key,
        responsibility_key: key
      })
      |> Repo.insert!()

      {:ok, agent} =
        %Agent{}
        |> Agent.changeset(%{
          slug: "resp-fire-native-#{System.unique_integer([:positive])}",
          name: "Fire Native",
          status: "active",
          kind: "native",
          workspace_id: nil
        })
        |> Repo.insert()

      {:ok, _} = Roles.assign_role(role_key, agent.id)

      # Neutralise the actual native dispatch — production would fan
      # out through `Platform.Chat.AgentResponder.maybe_dispatch/1`
      # which needs a message_id + space_id we don't have on the
      # plan-submit hook. The Router already exposes an override for
      # exactly this case.
      previous = Application.get_env(:platform, :responsibility_router_native_dispatcher)

      Application.put_env(
        :platform,
        :responsibility_router_native_dispatcher,
        {__MODULE__.NoopDispatcher, :maybe_dispatch}
      )

      on_exit(fn ->
        if previous do
          Application.put_env(:platform, :responsibility_router_native_dispatcher, previous)
        else
          Application.delete_env(:platform, :responsibility_router_native_dispatcher)
        end
      end)

      handler_id = "resp-fire-native-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:platform, :responsibility, :fired],
        fn _event, measurements, metadata, pid ->
          send(pid, {:fired_telemetry, measurements, metadata})
        end,
        test_pid
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      capture_log([level: :info], fn ->
        # GUARD. Note the honesty limit: on the native path
        # `{:ok, :dispatched}` means the handoff was accepted, not that
        # the agent responded.
        assert {:ok, :dispatched} =
                 Responsibilities.fire(key, %{plan_id: Ecto.UUID.generate()})
      end)

      assert_receive {:fired_telemetry, %{system_time: _}, %{key: ^key, dispatch_kind: :native}}
    end

    test "atom shorthand canonicalises to dotted key" do
      # `:architecture_review_plan` → `"architecture.review_plan"` via
      # Router.canonical_key/1 (replaces first underscore with dot).
      # Delegate accepts either form.
      key = "architecture.review_plan_#{System.unique_integer([:positive])}"
      atom_shorthand = String.to_atom(String.replace(key, ".", "_"))

      {:ok, _row} =
        Responsibilities.create_responsibility(%{
          key: key,
          feature: "architecture",
          trigger_kind: "event_topic",
          trigger_config: %{"topic" => "plan:submitted"},
          scope: "per_project",
          context_provided: [],
          output_contract: %{"comments" => "list[map]"},
          default_prompt_template: "architecture.review_plan.v1",
          cost_profile: "low_freq_capable"
        })

      capture_log([level: :info], fn ->
        # GUARD — the row exists but has no assignee, so :unfilled.
        assert {:ok, :unfilled} = Responsibilities.fire(atom_shorthand, %{})
      end)
    end
  end

  # ── outcome/1: the ADR-0046 mapper (member 1 stage 2) ──────────────────
  #
  # This is the contract surface stack members 2-9 import. One test per
  # clause so a future edit that collapses `:unfilled` into `:failed`
  # (the exact bug this task closes) cannot land quietly. The absence of
  # a catch-all is itself part of the contract and is asserted.
  describe "outcome/1" do
    test "{:ok, :dispatched} maps to :complete" do
      assert Responsibilities.outcome({:ok, :dispatched}) == :complete
    end

    test "{:ok, :unfilled} maps to :not_applicable" do
      assert Responsibilities.outcome({:ok, :unfilled}) == :not_applicable
    end

    test "{:ok, :unknown_responsibility} maps to :not_applicable" do
      assert Responsibilities.outcome({:ok, :unknown_responsibility}) == :not_applicable
    end

    test "{:error, reason} maps to :failed for any reason" do
      assert Responsibilities.outcome({:error, {:dispatch_failed, :econnrefused}}) == :failed
      assert Responsibilities.outcome({:error, {:native_dispatch_raised, "boom"}}) == :failed
      assert Responsibilities.outcome({:error, :some_future_atom}) == :failed
    end

    test "not_applicable and failed are never conflated" do
      # ADR-0046 docs/decisions/0046-...:79-83. Stated as an explicit
      # assertion because it is the invariant the whole task exists to
      # protect, not an implementation detail of the clauses above.
      refute Responsibilities.outcome({:ok, :unfilled}) ==
               Responsibilities.outcome({:error, :anything})

      refute Responsibilities.outcome({:ok, :unknown_responsibility}) ==
               Responsibilities.outcome({:error, :anything})

      refute Responsibilities.outcome({:ok, :dispatched}) ==
               Responsibilities.outcome({:ok, :unfilled})
    end

    test "an unrecognised shape raises rather than mis-mapping" do
      # Deliberate: no catch-all clause. A future fire/2 value this
      # mapper has not considered must be loud at the call site, not
      # silently reported as :failed. Documented in the @doc as the
      # reason transaction call sites must not invoke outcome/1
      # unguarded.
      #
      # Called through `apply/3` on purpose: a direct call with a
      # deliberately-bad argument trips the Elixir set-theoretic type
      # checker at compile time ("incompatible types given to
      # outcome/1"), which is the checker doing its job — but it would
      # emit a warning on every build for a test that wants the runtime
      # behaviour.
      assert_raise FunctionClauseError, fn -> apply(Responsibilities, :outcome, [:ok]) end

      assert_raise FunctionClauseError, fn ->
        apply(Responsibilities, :outcome, [{:ok, :something_new}])
      end
    end

    test "is exported with the arity members 2-9 assert on" do
      # Stack member 4's plan makes this exact check a test assertion,
      # so the name and arity are load-bearing beyond this task.
      Code.ensure_loaded!(Responsibilities)
      assert function_exported?(Responsibilities, :outcome, 1)
    end
  end

  # ── FIX DETECTOR: a failed dispatch reaches the caller ────────────────
  #
  # THIS BLOCK FAILS AGAINST THE PRE-STAGE-2 CODE. Before the
  # normalisation was deleted, `Responsibilities.fire/2` matched
  # `{:ok, _}` first and returned a flat `:ok`, so an assigned external
  # agent whose endpoint 503s was indistinguishable from a successful
  # dispatch at every call site. The `{:error, {:dispatch_failed, _}}`
  # assertion below is the whole point of the task.
  describe "fire/2 surfaces external dispatch failure end-to-end" do
    setup do
      Logger.put_module_level(Platform.Responsibilities.Router, :info)
      on_exit(fn -> Logger.delete_module_level(Platform.Responsibilities.Router) end)

      {:ok, _} = Application.ensure_all_started(:req)

      Application.put_env(
        :platform,
        :external_agents_dispatcher_req_client,
        Req.new(plug: {Req.Test, :responsibilities_fire_dispatch_test})
      )

      on_exit(fn ->
        Application.delete_env(:platform, :external_agents_dispatcher_req_client)
      end)

      :ok
    end

    # Mirrors wire_external_assignee/1 at
    # test/platform/responsibilities/router_test.exs:1088-1128.
    defp wire_external_assignee!(responsibility_key) do
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
          slug: "resp-fire-ext-#{System.unique_integer([:positive])}",
          name: "Responsibilities Fire External",
          status: "active",
          kind: "external",
          endpoint_kind: "openai_compat",
          base_url: "https://api.example.test",
          model: "test-model",
          workspace_id: nil
        })
        |> Repo.insert!()

      :ok = Platform.ExternalAgents.EphemeralCredentials.put(agent.id, "sk-resp-fire-test")
      on_exit(fn -> Platform.ExternalAgents.EphemeralCredentials.delete(agent.id) end)

      {:ok, _} = Roles.assign_role(role_key, agent.id)

      agent
    end

    defp seed_external_responsibility!(key) do
      {:ok, row} =
        Responsibilities.create_responsibility(%{
          key: key,
          feature: "architecture",
          trigger_kind: "event_topic",
          trigger_config: %{"topic" => "plan:submitted"},
          scope: "per_project",
          context_provided: [],
          output_contract: %{"comments" => "list[map]"},
          default_prompt_template: "architecture.review_plan.v1",
          cost_profile: "low_freq_capable"
        })

      row
    end

    test "a 503 from an assigned external agent returns {:error, {:dispatch_failed, _}}" do
      key = "architecture.review_plan_fire_503_#{System.unique_integer([:positive])}"
      _row = seed_external_responsibility!(key)
      _agent = wire_external_assignee!(key)

      Req.Test.stub(:responsibilities_fire_dispatch_test, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(503, ~s({"error":"down"}))
      end)

      test_pid = self()
      handler_id = "resp-fire-failed-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:platform, :responsibility, :failed],
        fn _event, measurements, metadata, pid ->
          send(pid, {:failed_telemetry, measurements, metadata})
        end,
        test_pid
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      capture_log([level: :info], fn ->
        fire_result = Responsibilities.fire(key, %{plan_id: Ecto.UUID.generate()})

        assert {:error, {:dispatch_failed, _reason}} = fire_result
        assert Responsibilities.outcome(fire_result) == :failed
      end)

      assert_receive {:failed_telemetry, %{system_time: _},
                      %{key: ^key, dispatch_kind: :external}}
    end

    test "POSITIVE CONTROL — a 200 from the same wiring returns {:ok, :dispatched}" do
      # Without this, the 503 test could pass because the agent was
      # never reachable at all rather than because the failure now
      # propagates. Same wiring, only the stubbed status differs.
      key = "architecture.review_plan_fire_200_#{System.unique_integer([:positive])}"
      _row = seed_external_responsibility!(key)
      _agent = wire_external_assignee!(key)

      Req.Test.stub(:responsibilities_fire_dispatch_test, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "choices" => [%{"message" => %{"role" => "assistant", "content" => "ack"}}]
          })
        )
      end)

      capture_log([level: :info], fn ->
        fire_result = Responsibilities.fire(key, %{plan_id: Ecto.UUID.generate()})

        assert {:ok, :dispatched} = fire_result
        assert Responsibilities.outcome(fire_result) == :complete
      end)
    end
  end

  defmodule NoopDispatcher do
    @moduledoc false
    def maybe_dispatch(_signal), do: :ok
  end
end
