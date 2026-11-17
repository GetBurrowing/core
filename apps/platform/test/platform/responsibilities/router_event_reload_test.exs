defmodule Platform.Responsibilities.RouterEventReloadTest do
  @moduledoc """
  Regression tests for the two event_topic behaviours task 01a1eaf6 stage 4
  added to the Router (commit 58276b05):

    (a) every event_topic match is re-read (`current_event_row/2`) before it
        fires, falling back to the held copy when the read fails;
    (b) every reload rebuilds the `event_topics` bucket, subscribing newly
        declared topics and unsubscribing topics no row declares any more.

  These use generic throwaway responsibilities, not showrunner ones, so they
  pin Router behaviour for every event_topic caller (architecture, tasks,
  meetings, ...).

  A fire is observed through a throwaway provider whose `gather_context/2`
  reports the row it was handed and answers `{:handled, _}`, so nothing is
  dispatched. Rows are wired to a native agent via the `historian` bundle so
  assignee resolution reaches the provider. PubSub delivery is observed with
  `:erlang.trace/3` on the Router pid plus `:erlang.trace_delivered/1` as the
  barrier, and subscriptions with `Registry.keys/2` on `Platform.PubSub`. No
  `Process.sleep`, no wall clock.

  Each test was detonated against router.ex before commit; see the task
  01a1eaf6 execution space for the mutation table.
  """
  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.Router
  alias Platform.Roles
  alias Platform.Roles.Role

  @pubsub Platform.PubSub
  @changed_topic "responsibilities:changed"

  # ── fixtures ─────────────────────────────────────────────────────────────

  setup do
    feature = "router_evt_reload_#{System.unique_integer([:positive])}"
    test_pid = self()

    provider =
      Module.concat([
        Platform.Responsibilities.Providers,
        "EvtReload#{System.unique_integer([:positive])}"
      ])

    Module.create(
      provider,
      quote do
        @behaviour Platform.Responsibilities.Provider

        @impl true
        def register, do: []

        @impl true
        def gather_context(responsibility, meta) do
          send(
            unquote(test_pid),
            {:fired, responsibility.key, responsibility.trigger_config, meta}
          )

          {:handled, %{}}
        end

        @impl true
        def handle_output(_r, _o), do: :ok

        @impl true
        def handle_output(_r, _o, _m), do: :ok
      end,
      Macro.Env.location(__ENV__)
    )

    put_provider_override(feature, provider)
    agent = native_agent!()

    %{feature: feature, agent: agent}
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
  end

  defp native_agent! do
    Repo.insert!(
      %Role{key: "historian", name: "Historian", description: "test", icon: "hero-star"},
      on_conflict: :nothing,
      conflict_target: :key
    )

    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "router-evt-reload-#{System.unique_integer([:positive])}",
        name: "Router Event Reload",
        status: "active",
        kind: "native",
        workspace_id: nil
      })
      |> Repo.insert!()

    {:ok, _} = Roles.assign_role("historian", agent.id)
    agent
  end

  defp unique_topic, do: "routerevtreload:#{System.unique_integer([:positive])}"

  # `event_match` must name an EXISTING atom (the Router converts the
  # message head with Atom.to_string/1); these literals guarantee that.
  # Distinct event names per row keep one broadcast from firing every row
  # (event-as-head routing matches on event name, not topic).
  defp event_atom(:a), do: :router_evt_reload_a
  defp event_atom(:b), do: :router_evt_reload_b
  defp event_atom(:c), do: :router_evt_reload_c
  defp event_atom(:d), do: :router_evt_reload_d

  defp insert!(%{feature: feature}, topic, event, extra_config \\ %{}) do
    key = "#{feature}.verb_#{System.unique_integer([:positive])}"

    {:ok, row} =
      Responsibilities.create_responsibility(%{
        key: key,
        feature: feature,
        trigger_kind: "event_topic",
        trigger_config:
          Map.merge(
            %{"topic" => topic, "event_match" => Atom.to_string(event_atom(event))},
            extra_config
          ),
        scope: "global",
        context_provided: [],
        output_contract: %{"summary" => "string"},
        default_prompt_template: "unseeded.router_evt_reload",
        cost_profile: "low_freq_capable"
      })

    %Platform.Roles.RoleResponsibility{}
    |> Platform.Roles.RoleResponsibility.changeset(%{
      role_key: "historian",
      responsibility_key: key
    })
    |> Repo.insert!()

    row
  end

  # Writes straight through the context, which (unlike Showrunner.provision/1)
  # broadcasts nothing: the Router learns of the change only by re-reading.
  defp update!(row, attrs) do
    {:ok, updated} = Responsibilities.update_responsibility(Repo.reload!(row), attrs)
    updated
  end

  defp start_router(opts \\ []) do
    name = Module.concat([Router, "EvtReload#{System.unique_integer([:positive])}"])

    pid =
      start_supervised!(
        {Router, Keyword.merge([name: name, check_interval_ms: :timer.hours(24)], opts)}
      )

    :ok = Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    pid
  end

  defp deliver(topic, event, payload) do
    :ok = Phoenix.PubSub.broadcast(@pubsub, topic, {event_atom(event), payload})
  end

  # Every message the Router had been sent is handled once this returns.
  defp barrier(pid), do: :sys.get_state(pid)

  defp subscribed_keys(pid), do: Registry.keys(@pubsub, pid)

  # Delivery observation: after `trace_receives/1`, every message entering
  # the Router's mailbox is mirrored to the test as {:trace, pid, :receive, m}.
  defp trace_receives(pid) do
    1 = :erlang.trace(pid, true, [:receive])
    on_exit(fn -> if Process.alive?(pid), do: :erlang.trace(pid, false, [:receive]) end)
  end

  # Guarantees every trace message generated so far is in our mailbox.
  defp flush_traces(pid) do
    ref = :erlang.trace_delivered(pid)
    assert_receive {:trace_delivered, ^pid, ^ref}
  end

  # ── (a) re-read before firing ────────────────────────────────────────────

  describe "fire-time re-read" do
    test "a row disabled after boot does not fire; its enabled sibling on the same topic does",
         ctx do
      topic = unique_topic()
      disabled = insert!(ctx, topic, :a)
      control = insert!(ctx, topic, :b)
      pid = start_router()

      assert Enum.any?(:sys.get_state(pid).by_trigger.event_topics, &(&1.id == disabled.id))

      update!(disabled, %{enabled: false})

      deliver(topic, :a, %{n: 1})
      deliver(topic, :b, %{n: 2})
      barrier(pid)

      control_key = control.key
      disabled_key = disabled.key
      assert_received {:fired, ^control_key, _, %{kind: :event_topic, payload: %{n: 2}}}
      refute_received {:fired, ^disabled_key, _, _}
    end

    test "a trigger_config change after boot reaches the fire without a restart or reload",
         ctx do
      topic = unique_topic()
      row = insert!(ctx, topic, :a, %{"marker" => "boot"})
      pid = start_router()

      update!(row, %{trigger_config: Map.put(row.trigger_config, "marker", "changed")})

      # The held copy is still the boot copy; only the re-read can see "changed".
      [held] = Enum.filter(:sys.get_state(pid).by_trigger.event_topics, &(&1.id == row.id))
      assert held.trigger_config["marker"] == "boot"

      deliver(topic, :a, %{n: 1})
      barrier(pid)

      key = row.key
      assert_received {:fired, ^key, %{"marker" => "changed"}, %{topic: ^topic}}
    end

    test "a topic change applied by reload is subscribed and fires on the new topic", ctx do
      old_topic = unique_topic()
      new_topic = unique_topic()
      row = insert!(ctx, old_topic, :a)
      pid = start_router()

      refute new_topic in subscribed_keys(pid)

      update!(row, %{trigger_config: Map.put(row.trigger_config, "topic", new_topic)})
      :ok = Router.reload_cron(pid)

      assert new_topic in subscribed_keys(pid)
      refute old_topic in subscribed_keys(pid)

      deliver(new_topic, :a, %{n: 1})
      barrier(pid)

      key = row.key
      assert_received {:fired, ^key, %{"topic" => ^new_topic}, %{topic: ^new_topic}}
    end

    for kind <- [:cron, :all] do
      test "a {:responsibilities_changed, #{inspect(kind)}} broadcast reloads the event_topics bucket",
           ctx do
        old_topic = unique_topic()
        new_topic = unique_topic()
        row = insert!(ctx, old_topic, :a)
        pid = start_router()

        update!(row, %{trigger_config: Map.put(row.trigger_config, "topic", new_topic)})

        :ok =
          Phoenix.PubSub.broadcast(
            @pubsub,
            @changed_topic,
            {:responsibilities_changed, unquote(kind)}
          )

        barrier(pid)

        assert new_topic in subscribed_keys(pid)
        refute old_topic in subscribed_keys(pid)

        deliver(new_topic, :a, %{n: 1})
        barrier(pid)

        key = row.key
        assert_received {:fired, ^key, %{"topic" => ^new_topic}, %{topic: ^new_topic}}
      end
    end

    test "when the re-read raises, the held (cached) row still fires", ctx do
      topic = unique_topic()
      row = insert!(ctx, topic, :a, %{"marker" => "boot"})
      test_pid = self()

      reader = fn key ->
        send(test_pid, {:reader_called, key})
        raise "simulated event row read failure"
      end

      pid = start_router(event_row_reader: reader)

      # A DB change the failed read cannot see: the fire must use the held copy.
      update!(row, %{trigger_config: Map.put(row.trigger_config, "marker", "changed")})

      deliver(topic, :a, %{n: 1})
      barrier(pid)

      key = row.key
      # The seam was actually exercised, not bypassed.
      assert_received {:reader_called, ^key}
      assert_received {:fired, ^key, %{"marker" => "boot"}, %{kind: :event_topic}}
      assert Process.alive?(pid)
    end
  end

  # ── (b) reload rebuilds the bucket and its subscriptions ────────────────

  describe "reload unsubscribes only topics no row declares" do
    test "drops the undeclared topic and keeps every other subscription", ctx do
      gone_topic = unique_topic()
      shared_topic = unique_topic()
      other_topic = unique_topic()

      gone = insert!(ctx, gone_topic, :a)
      # Two rows share `shared_topic`; disabling one must not drop it.
      shared_dropped = insert!(ctx, shared_topic, :b)
      shared_kept = insert!(ctx, shared_topic, :c)
      other = insert!(ctx, other_topic, :d)

      # A row that declares the Router's own reload topic: that topic is
      # subscribed for a non-event reason too, so disabling this row must not
      # unsubscribe it (the `@changed_topic` guard in apply_event_topic_reload/2).
      changed_row = insert!(ctx, @changed_topic, :a)

      pid = start_router()
      before = subscribed_keys(pid)

      for t <- [gone_topic, shared_topic, other_topic, @changed_topic],
          do: assert(t in before, "expected #{t} subscribed at boot")

      update!(gone, %{enabled: false})
      update!(shared_dropped, %{enabled: false})
      update!(changed_row, %{enabled: false})
      :ok = Router.reload_cron(pid)

      after_keys = subscribed_keys(pid)
      refute gone_topic in after_keys

      # Every other subscription the Router held survives: other rows'
      # topics, the shared topic, the reload topic, and any seeded rows'
      # topics the boot walk picked up.
      for t <- Enum.uniq(before) -- [gone_topic],
          do: assert(t in after_keys, "reload dropped #{t}")

      state = :sys.get_state(pid)
      refute gone_topic in state.subscribed_topics
      assert shared_topic in state.subscribed_topics
      assert other_topic in state.subscribed_topics

      trace_receives(pid)

      # The removed topic no longer reaches the Router's mailbox at all.
      gone_ref = make_ref()
      deliver(gone_topic, :a, %{ref: gone_ref})
      barrier(pid)
      flush_traces(pid)
      refute_received {:trace, ^pid, :receive, {_, %{ref: ^gone_ref}}}

      # The kept topics still deliver and fire.
      deliver(shared_topic, :c, %{n: 1})
      deliver(other_topic, :d, %{n: 2})
      barrier(pid)

      shared_kept_key = shared_kept.key
      other_key = other.key
      assert_received {:fired, ^shared_kept_key, _, %{payload: %{n: 1}}}
      assert_received {:fired, ^other_key, _, %{payload: %{n: 2}}}

      # The reload topic still delivers: a second reload reaches the Router.
      :ok = Phoenix.PubSub.broadcast(@pubsub, @changed_topic, {:responsibilities_changed, :all})
      barrier(pid)
      flush_traces(pid)
      assert_received {:trace, ^pid, :receive, {:responsibilities_changed, :all}}
    end
  end
end
