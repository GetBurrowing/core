defmodule Platform.Responsibilities.ReachabilityTest do
  @moduledoc """
  Fixtures here are built so the five classes are genuinely DIFFERENT, not
  five names for the same degenerate state. Specifically:

    * `:runtime_missing` and `:runtime_offline` are separated by an
      `agent_runtimes` row that actually exists — if every fixture runtime
      were absent, or every one offline, a mutation swapping those two
      branches could not show up.
    * exactly one runtime is tracked in presence and exactly one is not, so
      the `:runtime_offline` / `:broadcastable` split is exercised in both
      directions inside one report.
    * the `:runtime_missing` fixture is an external agent with a nil
      `runtime_id`, which is the sub-case that actually occurs. The
      dangling-FK sub-case cannot be built: `agents.runtime_id` is
      `references(:agent_runtimes, on_delete: :nilify_all)`, so deleting the
      runtime nils the pointer and lands back on the first sub-case. There is
      a test below that demonstrates exactly that rather than asserting the
      unreachable branch.

  Absence assertions are paired with a positive control in the same test and
  the collection is pinned non-empty first: `Enum.all?/2` and `Enum.empty?/1`
  are both `true` on `[]`, so an assertion over an accidentally-empty report
  passes while measuring nothing.
  """

  use Platform.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Federation.RuntimePresence
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.Reachability
  alias Platform.Roles

  setup do
    presence = Process.whereis(RuntimePresence) || start_supervised!(RuntimePresence)
    Sandbox.allow(Repo, self(), presence)

    # No presence teardown on purpose. RuntimePresence is a process-global
    # Agent shared with the rest of the suite, and entries this file tracks
    # are keyed on `rt-reach-<unique_integer>` strings no other case can
    # construct — so a leaked entry is unreachable rather than contaminating.
    # Untracking here would ALSO untrack a live entry if a sibling file
    # happened to reuse the id, which is the worse failure.
    :ok
  end

  # ── fixtures ───────────────────────────────────────────────────────────────

  defp uniq, do: System.unique_integer([:positive])

  defp create_responsibility(key, attrs \\ %{}) do
    [feature, _verb] = String.split(key, ".")

    defaults = %{
      key: key,
      feature: feature,
      trigger_kind: "event_topic",
      trigger_config: %{"topic" => "#{feature}:changed"},
      scope: "global",
      cost_profile: "low_freq_capable"
    }

    {:ok, responsibility} =
      Responsibilities.create_responsibility(Map.merge(defaults, attrs))

    responsibility
  end

  defp create_agent(attrs) do
    defaults = %{
      slug: "agent-#{uniq()}",
      name: "Fixture Agent",
      status: "active",
      max_concurrent: 1,
      sandbox_mode: "off",
      model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
    }

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    agent
  end

  defp create_runtime(opts) do
    owner =
      Repo.insert!(%User{
        email: "reach-#{uniq()}@example.com",
        name: "Reachability Owner",
        oidc_sub: "oidc-reach-#{uniq()}"
      })

    runtime =
      Repo.insert!(%AgentRuntime{
        owner_user_id: owner.id,
        status: "active",
        runtime_id: "rt-reach-#{uniq()}",
        display_name: "reachability-runtime"
      })

    if Keyword.get(opts, :online, false), do: RuntimePresence.track(runtime.runtime_id)

    runtime
  end

  defp assign(key, agent), do: {:ok, _} = Roles.set_override(key, agent.id)

  # Builds one enabled row per class, all five distinct, plus a disabled row
  # that would otherwise classify as :broadcastable. Returns the report keyed
  # by responsibility key so assertions read as a table.
  defp five_class_fixture do
    unfilled = create_responsibility("reachunfilled.run#{uniq()}")

    builtin_agent = create_agent(%{runtime_type: "built_in"})
    builtin = create_responsibility("reachbuiltin.run#{uniq()}")
    assign(builtin.key, builtin_agent)

    # External agent naming no runtime — the reachable :runtime_missing shape.
    # A dangling FK cannot be inserted (agents_runtime_id_fkey), and deleting
    # the runtime nilifies rather than dangles; see the dedicated test below.
    missing_agent = create_agent(%{runtime_type: "external", runtime_id: nil})

    missing = create_responsibility("reachmissing.run#{uniq()}")
    assign(missing.key, missing_agent)

    offline_runtime = create_runtime(online: false)
    offline_agent = create_agent(%{runtime_type: "external", runtime_id: offline_runtime.id})
    offline = create_responsibility("reachoffline.run#{uniq()}")
    assign(offline.key, offline_agent)

    online_runtime = create_runtime(online: true)
    online_agent = create_agent(%{runtime_type: "external", runtime_id: online_runtime.id})
    live = create_responsibility("reachlive.run#{uniq()}")
    assign(live.key, online_agent)

    disabled_runtime = create_runtime(online: true)
    disabled_agent = create_agent(%{runtime_type: "external", runtime_id: disabled_runtime.id})
    disabled = create_responsibility("reachdisabled.run#{uniq()}", %{enabled: false})
    assign(disabled.key, disabled_agent)

    %{
      keys: %{
        unfilled: unfilled.key,
        builtin: builtin.key,
        missing: missing.key,
        offline: offline.key,
        live: live.key,
        disabled: disabled.key
      },
      runtimes: %{offline: offline_runtime, online: online_runtime},
      report: index(Reachability.report())
    }
  end

  defp index(rows), do: Map.new(rows, &{&1.key, &1})

  # ── classes ────────────────────────────────────────────────────────────────

  describe "report/0 class assignment" do
    test "five distinct fixtures produce five distinct classes" do
      %{keys: keys, report: report} = five_class_fixture()

      assert report[keys.unfilled].class == :unfilled
      assert report[keys.builtin].class == :builtin_handler
      assert report[keys.missing].class == :runtime_missing
      assert report[keys.offline].class == :runtime_offline
      assert report[keys.live].class == :broadcastable

      observed =
        keys
        |> Map.take([:unfilled, :builtin, :missing, :offline, :live])
        |> Map.values()
        |> Enum.map(&report[&1].class)

      # Positive control on the collection itself: pin the size BEFORE
      # asserting uniqueness, so a report that lost rows cannot pass by
      # producing a trivially-unique empty list.
      assert length(observed) == 5
      assert Enum.uniq(observed) |> length() == 5
      assert MapSet.subset?(MapSet.new(observed), MapSet.new(Reachability.classes()))
    end

    test ":unfilled and :runtime_offline never collapse onto the same value" do
      %{keys: keys, report: report} = five_class_fixture()

      unfilled = report[keys.unfilled]
      offline = report[keys.offline]

      refute unfilled.class == offline.class

      # They differ on the fields that DECIDE them, not only on the label:
      # :unfilled is settled before any runtime is consulted, :runtime_offline
      # requires a resolved external assignee and an existing runtime row.
      assert unfilled.assignee_id == nil
      assert unfilled.runtime_online? == nil
      assert offline.assignee_id != nil
      assert offline.runtime_type == "external"
      assert offline.runtime_online? == false
    end

    test ":runtime_missing reports nil runtime_online? while :runtime_offline reports false" do
      %{keys: keys, report: report} = five_class_fixture()

      # This is the pair a class-swap mutation shows up in. nil vs false is
      # the whole distinction: "there was nothing to ask about presence" vs
      # "presence was asked and said no".
      assert report[keys.missing].runtime_online? == nil
      assert report[keys.offline].runtime_online? == false
      assert report[keys.live].runtime_online? == true
    end

    test "a non-external assignee classifies :builtin_handler and reports its runtime_type" do
      builtin = create_agent(%{runtime_type: "built_in"})
      builtin_key = create_responsibility("reachbi.run#{uniq()}")
      assign(builtin_key.key, builtin)

      # A runtime_type nobody uses today. The dispatcher's second
      # dispatch_system_event/2 clause matches on "not external" rather than
      # on "built_in", so an unrecognised value must land here too and not
      # silently take a federated path.
      exotic = create_agent(%{runtime_type: "hosted"})
      exotic_key = create_responsibility("reachexotic.run#{uniq()}")
      assign(exotic_key.key, exotic)

      report = index(Reachability.report())

      assert report[builtin_key.key].class == :builtin_handler
      assert report[builtin_key.key].runtime_type == "built_in"
      assert report[builtin_key.key].assignee_id == builtin.id
      assert report[builtin_key.key].runtime_id == nil
      assert report[builtin_key.key].runtime_online? == nil

      assert report[exotic_key.key].class == :builtin_handler
      assert report[exotic_key.key].runtime_type == "hosted"
    end

    test "an external agent with a nil runtime_id classifies :runtime_missing" do
      # The sub-case that never reaches Federation.get_runtime/1 — the first
      # dispatch_system_event/2 clause is guarded `when is_binary(runtime_pk)`.
      agent = create_agent(%{runtime_type: "external", runtime_id: nil})
      responsibility = create_responsibility("reachnilrt.run#{uniq()}")
      assign(responsibility.key, agent)

      row = index(Reachability.report())[responsibility.key]

      assert row.class == :runtime_missing
      assert row.runtime_type == "external"
      assert row.runtime_id == nil
      assert row.runtime_online? == nil

      # Control proving the fixture is not just "an agent that resolves to
      # nothing": the assignee DID resolve, which is what separates this from
      # :unfilled.
      assert row.assignee_id == agent.id
      assert row.assignee_slug == agent.slug
    end

    test "deleting a runtime nilifies the pointer rather than dangling it" do
      # Pins the mechanism the :runtime_missing moduledoc note depends on.
      # `agents.runtime_id` is references(:agent_runtimes, on_delete:
      # :nilify_all), so the `get_runtime/1 -> nil` branch at
      # agent_responder.ex:390 is not reachable through ordinary data flow —
      # the row lands in the nil-id sub-case instead. If this test starts
      # failing, that constraint changed and the moduledoc note is stale.
      runtime = create_runtime(online: true)
      agent = create_agent(%{runtime_type: "external", runtime_id: runtime.id})
      responsibility = create_responsibility("reachnilify.run#{uniq()}")
      assign(responsibility.key, agent)

      before = index(Reachability.report())[responsibility.key]
      assert before.class == :broadcastable
      assert before.runtime_id == runtime.runtime_id

      Repo.delete!(runtime)

      assert Repo.reload!(agent).runtime_id == nil

      after_delete = index(Reachability.report())[responsibility.key]
      assert after_delete.class == :runtime_missing
      assert after_delete.runtime_type == "external"
      assert after_delete.runtime_id == nil
    end

    test "presence is read live, not cached — untracking flips :broadcastable to :runtime_offline" do
      runtime = create_runtime(online: true)
      agent = create_agent(%{runtime_type: "external", runtime_id: runtime.id})
      responsibility = create_responsibility("reachlivepres.run#{uniq()}")
      assign(responsibility.key, agent)

      before = index(Reachability.report())[responsibility.key]
      assert before.class == :broadcastable

      RuntimePresence.untrack(runtime.runtime_id)

      after_untrack = index(Reachability.report())[responsibility.key]
      assert after_untrack.class == :runtime_offline

      # Nothing else moved — the flip is presence, not a wholesale re-read
      # producing a different row.
      assert after_untrack.assignee_id == before.assignee_id
      assert after_untrack.runtime_id == before.runtime_id
      assert after_untrack.runtime_type == before.runtime_type
    end

    test "classes/0 is the closed set report/0 draws from" do
      assert Reachability.classes() == [
               :unfilled,
               :builtin_handler,
               :runtime_missing,
               :runtime_offline,
               :broadcastable
             ]

      %{report: report} = five_class_fixture()
      rows = Map.values(report)

      refute rows == []
      assert Enum.all?(rows, &(&1.class in Reachability.classes()))
    end
  end

  # ── enabled filter ─────────────────────────────────────────────────────────

  describe "report/0 row selection" do
    test "a disabled row is excluded even though it would classify :broadcastable" do
      %{keys: keys, report: report} = five_class_fixture()

      # Positive control FIRST: the report is non-empty and the sibling
      # fixture with identical shape IS present. Without this, `report[key]
      # == nil` passes on a report that returned nothing at all.
      refute map_size(report) == 0
      assert report[keys.live].class == :broadcastable

      assert report[keys.disabled] == nil

      # And prove the exclusion is the `enabled` column rather than anything
      # about the fixture: flip it on and the row appears, classified exactly
      # like its live twin.
      Responsibilities.get_by_key(keys.disabled)
      |> Responsibilities.update_responsibility(%{enabled: true})

      reenabled = index(Reachability.report())[keys.disabled]
      assert reenabled.class == :broadcastable
    end

    test "rows come back ordered ascending by key" do
      five_class_fixture()

      keys = Enum.map(Reachability.report(), & &1.key)

      assert length(keys) >= 5
      assert keys == Enum.sort(keys)
    end
  end

  # ── the "deliberately inert" axis ──────────────────────────────────────────

  describe "declared inertness (orthogonal to class)" do
    test "a row declaring a non-Router executor is inert AND still :broadcastable" do
      runtime = create_runtime(online: true)
      agent = create_agent(%{runtime_type: "external", runtime_id: runtime.id})

      sweeper =
        create_responsibility("reachsweeper.run#{uniq()}", %{
          trigger_config: %{"topic" => "platform.security.sweeper_only"},
          metadata: %{
            "owner" => "platform.security",
            "status" => "placeholder",
            "executor" => "platform.security.sweeper"
          }
        })

      assign(sweeper.key, agent)

      row = index(Reachability.report())[sweeper.key]

      # This is the whole point of the second axis: the security.* shape is
      # perfectly reachable AND was never going to fire. Collapsing the two
      # would count it as a casualty of the payload bug, which it is not.
      assert row.class == :broadcastable
      assert row.declared_inert? == true
      assert row.declared_inert_reason == :non_router_executor
      assert row.declared_executor == "platform.security.sweeper"
      assert row.declared_status == "placeholder"
      assert row.topic == "platform.security.sweeper_only"
    end

    test "placeholder status alone marks inertness; active status does not" do
      placeholder =
        create_responsibility("reachplaceholder.run#{uniq()}", %{
          metadata: %{"status" => "placeholder"}
        })

      active =
        create_responsibility("reachactive.run#{uniq()}", %{
          metadata: %{"status" => "active"}
        })

      report = index(Reachability.report())

      assert report[placeholder.key].declared_inert? == true
      assert report[placeholder.key].declared_inert_reason == :placeholder_status

      # Positive control in the same test — without it, a mutation that
      # hardcodes declared_inert? to true would still pass the assertion above.
      assert report[active.key].declared_inert? == false
      assert report[active.key].declared_inert_reason == nil
      assert report[active.key].declared_status == "active"
    end

    test "a row with no metadata declares nothing and is not inert" do
      bare = create_responsibility("reachbare.run#{uniq()}")

      row = index(Reachability.report())[bare.key]

      assert row.declared_status == nil
      assert row.declared_executor == nil
      assert row.declared_inert? == false
      assert row.declared_inert_reason == nil
    end

    test "inertness does not vary with class — an :unfilled row can be inert too" do
      inert_unfilled =
        create_responsibility("reachinertunfilled.run#{uniq()}", %{
          metadata: %{"executor" => "platform.security.sweeper"}
        })

      row = index(Reachability.report())[inert_unfilled.key]

      assert row.class == :unfilled
      assert row.declared_inert? == true
    end
  end

  # ── row shape ──────────────────────────────────────────────────────────────

  describe "row shape" do
    test "every row carries the full declared key set" do
      %{report: report} = five_class_fixture()
      rows = Map.values(report)

      refute rows == []

      expected =
        MapSet.new([
          :key,
          :trigger_kind,
          :feature,
          :topic,
          :assignee_slug,
          :assignee_id,
          :runtime_type,
          :runtime_id,
          :runtime_online?,
          :class,
          :declared_status,
          :declared_executor,
          :declared_inert?,
          :declared_inert_reason
        ])

      assert Enum.all?(rows, &(MapSet.new(Map.keys(&1)) == expected))
    end

    test "topic is lifted from trigger_config and nil for a cron row" do
      event =
        create_responsibility("reachtopic.run#{uniq()}", %{
          trigger_config: %{"topic" => "plan:submitted"}
        })

      cron =
        create_responsibility("reachcron.run#{uniq()}", %{
          trigger_kind: "cron",
          trigger_config: %{"expression" => "0 3 * * 1"}
        })

      report = index(Reachability.report())

      assert report[event.key].topic == "plan:submitted"
      assert report[event.key].trigger_kind == "event_topic"
      assert report[cron.key].topic == nil
      assert report[cron.key].trigger_kind == "cron"
    end

    test "runtime_id reports the runtime's wire id, not its primary key" do
      runtime = create_runtime(online: true)
      agent = create_agent(%{runtime_type: "external", runtime_id: runtime.id})
      responsibility = create_responsibility("reachwireid.run#{uniq()}")
      assign(responsibility.key, agent)

      row = index(Reachability.report())[responsibility.key]

      # The wire id is what `runtime:<id>` topics and presence are keyed on,
      # so it is the id an operator can actually correlate against a log line.
      assert row.runtime_id == runtime.runtime_id
      refute row.runtime_id == runtime.id
    end
  end

  # ── presence unreadable ────────────────────────────────────────────────────

  describe "report/0 when presence cannot be read" do
    test "raises rather than reporting every runtime offline" do
      %{keys: keys, report: report} = five_class_fixture()

      # Control: with presence up, the live fixture reads :broadcastable.
      assert report[keys.live].class == :broadcastable

      presence = Process.whereis(RuntimePresence)
      Process.unregister(RuntimePresence)

      try do
        assert_raise RuntimeError, ~r/RuntimePresence is not running/, fn ->
          Reachability.report()
        end
      after
        Process.register(presence, RuntimePresence)
      end
    end
  end

  # ── rendering ──────────────────────────────────────────────────────────────

  describe "render/1" do
    test "prints a table row, a machine-readable line, and the non-claim caveat" do
      %{keys: keys, report: report} = five_class_fixture()

      output = Reachability.render(Map.values(report) |> Enum.sort_by(& &1.key))

      assert output =~ "Responsibility dispatch reachability"
      assert output =~ keys.live
      assert output =~ "REACH key=#{keys.live} class=broadcastable"
      assert output =~ "class tally"

      # The non-claim is the reason this whole module exists; it must survive
      # a copy-paste of the rendered output.
      assert output =~ "broadcastable` means the SERVER would broadcast"
      assert output =~ "whether the receiving client parses the envelope"

      # Excluded rows stay excluded in the rendering, and nil fields render as
      # a dash rather than the string "nil".
      refute output =~ keys.disabled
      assert output =~ "REACH key=#{keys.unfilled} class=unfilled"
      assert output =~ "runtime_online?=-"
    end

    test "the tally counts every class, including the ones at zero" do
      unfilled = create_responsibility("reachtally.run#{uniq()}")

      output = Reachability.render()

      assert output =~ unfilled.key

      # A class with no rows still gets a line — an operator reading the tally
      # should be able to tell "zero broadcastable" from "the tally omitted it".
      for class <- Reachability.classes() do
        assert output =~ to_string(class)
      end

      assert output =~ "broadcastable     0"
    end

    test "render/0 falls back to report/0 when no rows are supplied" do
      responsibility = create_responsibility("reachfallback.run#{uniq()}")

      assert Reachability.render() =~ responsibility.key
    end
  end
end
