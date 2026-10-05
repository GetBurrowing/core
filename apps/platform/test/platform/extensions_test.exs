defmodule Platform.ExtensionsTest do
  @moduledoc """
  The `Platform.Extension` contract and the `Platform.Extensions` registry
  (ADR 0055, task 01a0ee08 stages 2 and 3).

    * POSITIVE CONTROL: `Platform.FixtureExtension` (test/support) contributes
      one recognisable entry to every seam, and each seam must show it. A seam
      that stops reading the registry loses its entry and its case goes red
      (mutations recorded in the stage summary: the `rail_items` append in
      `IconRail.canonical_destinations/0` and the `canvas_kinds` call in
      `Kinds.all/0`, each removed alone, turn their case red).
    * With `:extensions = []`, none appears and nothing raises.
    * PARITY: this project's own build configures NO module (the
      without-modules build), and every registry reads as main's did with
      Play's flag unset, minus Play's always-registered entries.
      The snapshots were MEASURED on main (eb30c8593) by a probe run in the
      test env on moon, not copied from this branch. The with-Play parity
      cases moved with the module
      (apps/game_stream/test/platform/game_stream/extension_parity_test.exs).

  NOT async: every case writes `:platform, :extensions` (global app env),
  restored on exit.
  """

  use PlatformWeb.ChannelCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias Platform.Accounts.User
  alias Platform.Agents.AgentRuntime
  alias Platform.Chat.Canvas.Kinds
  alias Platform.Experiments.Metrics
  alias Platform.Experiments.Surfaces
  alias Platform.Extensions
  alias Platform.Federation
  alias Platform.Federation.ToolAuthorization
  alias Platform.Federation.ToolSurface
  alias Platform.FixtureExtension
  alias Platform.Repo
  alias PlatformWeb.Components.IconRail

  @core_kinds ~w(stack row card text markdown heading badge image code mermaid embed form action_row checklist checklist_item table)

  setup do
    on_exit(fn -> Application.delete_env(:platform, :fixture_extension_test_pid) end)
    :ok
  end

  defp unique, do: System.unique_integer([:positive])

  defp join_runtime do
    user =
      Repo.insert!(%User{
        email: "ext-#{unique()}@example.com",
        name: "Extensions User",
        oidc_sub: "ext-#{unique()}"
      })

    {:ok, runtime} =
      Federation.register_runtime(user.id, %{
        runtime_id: "ext-rt-#{unique()}",
        allowed_bundles: []
      })

    {:ok, runtime, token} = Federation.activate_runtime(runtime)

    {:ok, socket} =
      connect(PlatformWeb.RuntimeSocket, %{"runtime_id" => runtime.runtime_id, "token" => token})

    {:ok, _reply, socket} = subscribe_and_join(socket, "runtime:#{runtime.runtime_id}", %{})
    {runtime, socket}
  end

  # Pushes frames, then a round trip, so every frame above has been handled.
  defp push_and_settle(socket, frames) do
    for {event, payload} <- frames, do: push(socket, event, payload)
    ref = push(socket, "pong", %{})
    assert is_reference(ref)
    :sys.get_state(socket.channel_pid)
  end

  describe "a registered extension appears in every seam (positive control)" do
    setup do
      FixtureExtension.register()
      Application.put_env(:platform, :fixture_extension_test_pid, self())
      :ok
    end

    test "canvas kind: registered, and described by its own module" do
      assert "fixture_widget" in Kinds.names()
      assert Kinds.get("fixture_widget") == FixtureExtension.Kinds.FixtureWidget
      summary = Enum.find(Kinds.summaries(), &(&1.kind == "fixture_widget"))
      assert summary.description == "Fixture widget, described by its own module."
    end

    test "tool bundle: known, grantable, listed, and its tools dispatched by exact name" do
      assert "fixture" in ToolSurface.all_bundles()
      assert "fixture" in AgentRuntime.valid_bundles()
      assert [%{name: "fixture_echo", bundle: "fixture"}] = ToolSurface.list_tools(["fixture"])
      assert Enum.any?(ToolSurface.tool_definitions(), &(&1.name == "fixture_echo"))

      assert {:ok, %{tool: "fixture_echo", args: %{"x" => 1}}} =
               ToolSurface.execute("fixture_echo", %{"x" => 1}, %{})

      # Owned but not listed (a switched-off tool): still the owner's to answer.
      assert {:ok, %{tool: "fixture_hidden"}} = ToolSurface.execute("fixture_hidden", %{}, %{})

      assert ToolAuthorization.deny_message("fixture_hidden") ==
               "fixture_hidden is switched off on this install"

      # Exact name, never a prefix: a name the bundle does not own is unknown.
      assert {:error, %{error: "Unknown tool: fixture_echo_2"}} =
               ToolSurface.execute("fixture_echo_2", %{}, %{})
    end

    test "runtime event: an owned frame reaches its extension; an inert one is logged once" do
      {runtime, socket} = join_runtime()
      assert Extensions.runtime_event_owner("fixture_ping") == FixtureExtension

      log =
        capture_log(fn ->
          push_and_settle(socket, [
            {"fixture_ping", %{"n" => 1}},
            {"fixture_inert", %{}},
            {"fixture_inert", %{}}
          ])
        end)

      rid = runtime.runtime_id
      assert_received {:fixture_event, "fixture_ping", ^rid, %{"n" => 1}}
      assert length(String.split(log, "fixture is switched off")) == 2, log
      assert Process.alive?(socket.channel_pid)
    end

    test "live hook: attached by PlatformWeb.Extensions.attach_live_hooks/1" do
      socket = PlatformWeb.Extensions.attach_live_hooks(%Phoenix.LiveView.Socket{})
      assert socket.assigns[:fixture_hook_attached] == true
    end

    test "experiment surface and metric: registered" do
      assert Surfaces.get("fixture.surface") == FixtureExtension.Surface
      assert FixtureExtension.Surface in Surfaces.list()
      assert Metrics.metric_module("fixture_metric") == FixtureExtension.Metric
      assert "fixture_metric" in Metrics.known_metrics()
      assert Enum.any?(Metrics.catalog(), &(&1.slug == "fixture_metric"))
    end

    test "rail item: in the destinations, through the same filters as a core item" do
      keys = Enum.map(IconRail.destinations(), & &1.key)
      assert :fixture in keys
      assert List.last(keys) == :fixture
    end

    test "migrations path: after core's, in the release and in the mix aliases" do
      path = FixtureExtension.migrations()
      assert Extensions.migrations_paths() == [path]

      assert Platform.Release.migrations_paths(Repo) ==
               [Ecto.Migrator.migrations_path(Repo), path]

      assert Platform.MixSupport.extension_migration_args() ==
               ["--migrations-path", "priv/repo/migrations", "--migrations-path", path]
    end

    test "assets: read at build time, absent keys filled; core starts no extension process" do
      assert [{FixtureExtension, assets}] = Extensions.assets()
      assert assets.js_hooks == FixtureExtension.assets().js_hooks
      assert assets.css == nil
      assert assets.tailwind_sources == FixtureExtension.assets().tailwind_sources

      # Stage 3 retired the stage-2 `children/0` seam: a module's processes
      # are its own Application's, never core's.
      refute function_exported?(Extensions, :children, 0)
      refute {:children, 0} in Platform.Extension.behaviour_info(:callbacks)
    end

    test "assets: the generated @extensions entry and wrapper stylesheet name every input" do
      out = Path.join(System.tmp_dir!(), "ext-assets-#{unique()}")
      assets = Extensions.assets()
      js = Platform.Extensions.AssetEntry.js(assets, out)
      css = Platform.Extensions.AssetEntry.css(assets, "/src/platform/assets/css/app.css", out)

      hooks = Path.relative_to(FixtureExtension.assets().js_hooks, out, force: true)
      assert js =~ ~s(import ext0 from "#{hooks}")
      assert js =~ "export default {\n  ...ext0,\n}"

      assert css =~
               ~s(@import "#{Path.relative_to("/src/platform/assets/css/app.css", out, force: true)}";)

      for source <- FixtureExtension.assets().tailwind_sources do
        assert css =~ ~s(@source "#{Path.relative_to(source, out, force: true)}";)
      end
    end

    test "the deferred optional callbacks have no reader: implementing one changes nothing" do
      # ADR 0055 section 2: routes, telemetry handlers, responsibility providers
      # and prompt templates are declared, and deliberately read by nobody yet.
      optional = Platform.Extension.behaviour_info(:optional_callbacks)

      for callback <- [
            routes: 0,
            telemetry_handlers: 0,
            responsibility_providers: 0,
            prompt_templates: 0
          ] do
        assert callback in optional
      end

      refute function_exported?(Extensions, :routes, 0)
      refute function_exported?(Extensions, :telemetry_handlers, 0)
      refute function_exported?(Extensions, :responsibility_providers, 0)
      refute function_exported?(Extensions, :prompt_templates, 0)
    end
  end

  describe "with :extensions = []" do
    setup do
      FixtureExtension.register([])
      :ok
    end

    test "the empty generated entry is exactly core's none.js registry" do
      assert Platform.Extensions.AssetEntry.js([], "/tmp") =~ "export default {\n}"
      assert Extensions.assets() == []
    end

    test "no extension entry appears in any seam, and nothing raises" do
      assert Kinds.names() == @core_kinds
      assert ToolSurface.all_bundles() == ToolSurface.core_bundles()
      refute "play" in AgentRuntime.valid_bundles()
      refute Enum.any?(ToolSurface.tool_definitions(), &String.starts_with?(&1.name, "play_"))
      refute Enum.any?(Surfaces.list(), &String.starts_with?(&1.key(), "game_stream."))
      refute Enum.any?(Metrics.known_metrics(), &String.starts_with?(&1, "game_stream"))
      refute :fixture in Enum.map(IconRail.destinations(is_fabrikam_user: true), & &1.key)
      assert Extensions.migrations_paths() == []
      assert Platform.MixSupport.extension_migration_args() == []
      assert Extensions.live_hooks() == []
      assert Extensions.runtime_disconnected("nobody") == :ok
      socket = %Phoenix.LiveView.Socket{}
      assert PlatformWeb.Extensions.attach_live_hooks(socket) == socket
      assert Extensions.validate() == :ok
    end

    test "a play tool call gets the ordinary unknown-tool error, not a crash" do
      assert {:error, %{error: "Unknown tool: play_session_start", recoverable: false}} =
               ToolSurface.execute("play_session_start", %{}, %{})

      assert ToolAuthorization.deny_message("play_session_start") =~ "unknown tool"
    end

    test "an unowned runtime event is logged once, dropped, and the channel lives" do
      {_runtime, socket} = join_runtime()

      log =
        capture_log(fn ->
          push_and_settle(socket, [
            {"play_signal", %{"session_id" => "x"}},
            {"play_session_status", %{"session_id" => "x"}},
            {"nobody_owns_this", %{}}
          ])
        end)

      assert length(String.split(log, "no installed extension owns this event")) == 2, log
      assert log =~ "play_signal from runtime_id="
      assert Process.alive?(socket.channel_pid)
    end

    test "a malformed frame for a core event is dropped silently, not logged as unowned" do
      {_runtime, socket} = join_runtime()
      log = capture_log(fn -> push_and_settle(socket, [{"reply", %{"no" => "space"}}]) end)
      refute log =~ "no installed extension owns this event"
      assert Process.alive?(socket.channel_pid)
    end

    test "a persisted grant of an absent module's bundle survives a save; a fresh one is refused" do
      user =
        Repo.insert!(%User{
          email: "orph-#{unique()}@example.com",
          name: "O",
          oidc_sub: "o-#{unique()}"
        })

      {:ok, runtime} = Federation.register_runtime(user.id, %{runtime_id: "orph-#{unique()}"})
      # A row written while Play was installed.
      {1, _} =
        Repo.update_all(
          from(r in AgentRuntime, where: r.id == ^runtime.id),
          set: [allowed_bundles: ["space", "play"]]
        )

      runtime = Repo.get!(AgentRuntime, runtime.id)

      assert {:ok, saved} = Federation.update_allowed_bundles(runtime, ["space", "files", "play"])
      assert saved.allowed_bundles == ["space", "files", "play"]
      assert Repo.get!(AgentRuntime, runtime.id).allowed_bundles == ["space", "files", "play"]

      # The same bundle ADDED to a row that never held it is refused.
      {:ok, fresh} = Federation.register_runtime(user.id, %{runtime_id: "fresh-#{unique()}"})
      assert {:error, changeset} = Federation.update_allowed_bundles(fresh, ["space", "play"])
      assert {"has an invalid entry", _} = changeset.errors[:allowed_bundles]

      # And so is one on a new row.
      assert {:error, _} =
               Federation.register_runtime(user.id, %{
                 runtime_id: "new-#{unique()}",
                 allowed_bundles: ["play"]
               })
    end
  end

  describe "an extension whose processes are absent" do
    test "runtime_disconnected with the owner's Registry stopped returns :ok" do
      FixtureExtension.register()
      # The fixture's Registry is not running (its children are never
      # started here), and its callback does not tolerate that: the control.
      assert Process.whereis(FixtureExtension.registry()) == nil
      assert_raise ArgumentError, fn -> FixtureExtension.runtime_disconnected("rt") end

      log = capture_log(fn -> assert Extensions.runtime_disconnected("rt") == :ok end)
      assert log =~ "runtime_disconnected(rt) raised"
    end
  end

  describe "name clashes across merged registries" do
    defmodule CoreToolClash do
      @moduledoc false
      @behaviour Platform.Extension
      def canvas_kinds, do: [Platform.Chat.Canvas.Kinds.Badge]

      def mcp_tool_bundles,
        do: [
          %{
            name: "canvas",
            definitions: [],
            tool_names: ["space_list"],
            execute: fn _, _, _ -> :ok end,
            owns_tool?: &(&1 == "task_get")
          }
        ]

      def runtime_channel_events, do: ["pong"]
      def handle_runtime_event(_e, _r, _p), do: :ok
      def runtime_disconnected(_r), do: :ok
      def live_hooks, do: []
      def experiment_surfaces, do: [Platform.Experiments.Surfaces.DispatchPrompt]
      def experiment_metrics, do: %{"cycle_time" => %{module: __MODULE__}}
      def migrations_path, do: nil
    end

    test "an extension reusing core names is refused, naming both owners, per registry" do
      FixtureExtension.register([CoreToolClash])
      assert {:error, messages} = Extensions.validate()
      owner = inspect(CoreToolClash)

      for expected <- [
            ~s(tool bundle name "canvas" is claimed by core and by #{owner}),
            ~s(tool name "space_list" is claimed by core and by #{owner}),
            ~s(tool name claim "task_get" is claimed by core and by #{owner}),
            ~s(runtime event name "pong" is claimed by core and by #{owner}),
            ~s(canvas kind name "badge" is claimed by core and by #{owner}),
            ~s(experiment surface key "dispatch.prompt" is claimed by core and by #{owner}),
            ~s(experiment metric slug "cycle_time" is claimed by core and by #{owner})
          ] do
        assert expected in messages, "missing #{inspect(expected)} in #{inspect(messages)}"
      end

      assert_raise ArgumentError, ~r/tool name "space_list" is claimed by core/, fn ->
        Extensions.validate!()
      end
    end

    test "two extensions sharing a name are refused, naming both" do
      FixtureExtension.register([FixtureExtension, FixtureExtension.Twin])
      assert {:error, messages} = Extensions.validate()

      assert ~s(tool bundle name "fixture" is claimed by #{inspect(FixtureExtension)} and by #{inspect(FixtureExtension.Twin)}) in messages

      assert ~s(tool name "fixture_echo" is claimed by #{inspect(FixtureExtension)} and by #{inspect(FixtureExtension.Twin)}) in messages
    end
  end

  describe "RuntimeChannel's @core_events matches its own handle_in clauses" do
    test "every string event core handles is listed, and nothing else" do
      source = File.read!("lib/platform_web/channels/runtime_channel.ex")

      handled =
        ~r/def handle_in\(\s*"([^"]+)"/
        |> Regex.scan(source, capture: :all_but_first)
        |> List.flatten()
        |> Enum.uniq()
        |> Enum.sort()

      # The scan must see clauses both on one line and split over lines.
      assert "pong" in handled
      assert "reply_chunk" in handled
      assert handled == Enum.sort(PlatformWeb.RuntimeChannel.core_events())
    end
  end

  describe "parity with main (eb30c8593): this build configures no module" do
    # Measured on main at eb30c8593 in the test env with Play's flag
    # unset. On main the `play` bundle, Play's two surfaces and its two metrics
    # were registered even with the flag unset; this build has no module, so
    # those entries (and only those) are gone. Everything else is main's.
    @main_tool_names_off [
      {"canvas.create", "canvas"},
      {"canvas.patch", "canvas"},
      {"canvas.describe", "canvas"},
      {"canvas.list_kinds", "canvas"},
      {"canvas.template", "canvas"},
      {"canvas.versions", "canvas"},
      {"canvas.restore", "canvas"},
      {"send_media", "messaging"},
      {"react", "messaging"},
      {"project_list", "task"},
      {"org_list_descendants", "task"},
      {"project_update", "task"},
      {"epic_list", "task"},
      {"epic_update", "task"},
      {"epic_create", "task"},
      {"task_create", "task"},
      {"task_get", "task"},
      {"task_transition_list", "task"},
      {"runtime_event_list", "task"},
      {"execution_lease_list", "task"},
      {"task_list", "task"},
      {"task_complete", "task"},
      {"task_close_as_delivered", "task"},
      {"task_delivery_candidate_list", "task"},
      {"task_update", "task"},
      {"task_start", "task"},
      {"task_ack", "task"},
      {"alarm_silence", "task"},
      {"task_dependencies", "task"},
      {"task_attach_canvas", "task"},
      {"task_design_decline", "task"},
      {"task_detach_canvas", "task"},
      {"task_list_canvases", "task"},
      {"stack_create", "task"},
      {"stack_update", "task"},
      {"stack_get", "task"},
      {"stack_list", "task"},
      {"stack_add", "task"},
      {"stack_add_dependency", "task"},
      {"stack_remove_dependency", "task"},
      {"stack_eject", "task"},
      {"stack_abandon", "task"},
      {"stack_complete", "task"},
      {"stack_start", "task"},
      {"stack_retry_member_merge", "task"},
      {"stack_start_planning", "task"},
      {"stack_assign_agents", "task"},
      {"plan_create", "plan"},
      {"plan_update", "plan"},
      {"plan_get", "plan"},
      {"plan_submit", "plan"},
      {"plan_approve", "plan"},
      {"plan_reject", "plan"},
      {"validation_payload_amend", "plan"},
      {"plan_architecture_verdict", "plan"},
      {"stage_architecture_audit", "plan"},
      {"stage_start", "plan"},
      {"stage_list", "plan"},
      {"validation_evaluate", "plan"},
      {"validation_pass", "plan"},
      {"stage_complete", "plan"},
      {"report_blocker", "plan"},
      {"validation_list", "plan"},
      {"prompt_template_list", "plan"},
      {"prompt_template_update", "plan"},
      {"review_request_create", "review"},
      {"review_request_get", "review"},
      {"review_item_list", "review"},
      {"design_critique_request", "review"},
      {"space_create", "space"},
      {"space_list", "space"},
      {"space_list_agents", "space"},
      {"space_leave", "space"},
      {"dm_create", "space"},
      {"space_get_context", "context_read"},
      {"space_search_messages", "context_read"},
      {"space_get_messages", "context_read"},
      {"canvas_list", "context_read"},
      {"canvas_get", "context_read"},
      {"principal_search", "context_read"},
      {"federation_status", "federation"},
      {"memory_view", "memory"},
      {"memory_create", "memory"},
      {"memory_str_replace", "memory"},
      {"memory_insert", "memory"},
      {"memory_delete", "memory"},
      {"memory_rename", "memory"},
      {"memory_search", "memory"},
      {"org_memory_recently_edited", "memory"},
      {"org_memory_recently_deleted", "memory"},
      {"org_memory_feedback_at_path", "memory"},
      {"skill.list", "skill"},
      {"skill.get", "skill"},
      {"skill.upsert", "skill"},
      {"attachment.upload_inline", "attachment"},
      {"attachment.get_inline", "attachment"},
      {"attachment.upload_start", "attachment"},
      {"file_list", "files"},
      {"file_get_text", "files"},
      {"file_get_metadata", "files"},
      {"file_search", "files"},
      {"file_add", "files"},
      {"file_delete", "files"},
      {"meeting_create", "meetings"},
      {"meeting_say", "meetings"},
      {"meeting_activity_push", "meetings"},
      {"intent_ack", "meetings"},
      {"experiment_surface_list", "experiments"},
      {"experiment_list", "experiments"},
      {"experiment_get", "experiments"},
      {"experiment_create", "experiments"},
      {"experiment_variant_add", "experiments"},
      {"experiment_start", "experiments"},
      {"experiment_stop", "experiments"},
      {"experiment_conclude", "experiments"},
      {"experiment_results", "experiments"},
      {"experiment_signals_list", "experiments"},
      {"experiment_exclude", "experiments"},
      {"experiment_goal_set", "experiments"},
      {"experiment_goal_list", "experiments"},
      {"experiment_promote", "experiments"}
    ]

    # Re-pinned by task 01a0fcfa stage 1: attachment.get_inline's `returns`
    # and `limitations` text now document the MCP image content block. That
    # is the only tool-definition change; names and bundles are unchanged.
    @main_tool_digest_off "aeed155fe1eddc517699538d9ec4a22f158c25fb87ac83672892de7adf56fb68"
    @main_kinds_summaries_digest_off "4c060fb7a6914985f94857aaac9effbb519dd2b2170c7a9c0013d4db15a73ea4"
    @main_kinds_tool_schemas_digest_off "e454cd9e2aeb1d821a70b74fe433e81ba98b94f7ae9f2d59c55f8cf5bf509af8"
    # main's lists minus exactly `play`.
    @core_bundles ~w(canvas messaging task plan review space context_read federation memory skill attachment files meetings mail experiments)
    @core_valid_bundles ~w(federation space context_read messaging review canvas task plan memory skill attachment files meetings mail experiments)
    @main_rail [
      :chat,
      :tasks,
      :inbox,
      :activity,
      :skills,
      :files,
      :context,
      :prompts,
      :experiments,
      :meetings,
      :admin
    ]
    # main's lists minus exactly Play's two metric slugs and two surface keys,
    # in main's order.
    @core_metrics ~w(cycle_time manual_gate_rejection_rate overscoped_gate_count plan_revision_count stages_per_plan time_in_phase validation_failure_rate)
    @core_surfaces ~w(dispatch.prompt mail.draft.generator planner.stage_budget chat.context_summary meetings.open_question_classifier dispatch.product_docs_preamble)

    defp canon(%_{} = s), do: canon(Map.from_struct(s))

    defp canon(m) when is_map(m),
      do: {:map, m |> Enum.map(fn {k, v} -> {canon(k), canon(v)} end) |> Enum.sort()}

    defp canon(l) when is_list(l), do: Enum.map(l, &canon/1)

    defp canon(t) when is_tuple(t),
      do: t |> Tuple.to_list() |> Enum.map(&canon/1) |> List.to_tuple()

    defp canon(f) when is_function(f), do: {:fun, inspect(f)}
    defp canon(x), do: x

    defp digest(term),
      do:
        :crypto.hash(:sha256, :erlang.term_to_binary(canon(term))) |> Base.encode16(case: :lower)

    setup do
      assert Extensions.list() == []
      :ok
    end

    test "tool_definitions/0 is main's flag-off list, name for name and byte for byte" do
      defs = ToolSurface.tool_definitions()
      assert Enum.map(defs, &{&1.name, &1.bundle}) == @main_tool_names_off
      assert digest(defs) == @main_tool_digest_off
    end

    test "bundles, kinds, metrics, surfaces and rail are main's minus the module's entries" do
      assert ToolSurface.all_bundles() == @core_bundles
      assert AgentRuntime.valid_bundles() == @core_valid_bundles
      assert Metrics.known_metrics() == @core_metrics
      assert Enum.map(Metrics.catalog(), & &1.slug) |> Enum.sort() == Enum.sort(@core_metrics)
      assert Enum.map(Surfaces.list(), & &1.key()) == @core_surfaces
      assert Enum.map(IconRail.destinations(is_fabrikam_user: true), & &1.key) == @main_rail
      assert Kinds.names() == @core_kinds
      assert digest(Kinds.summaries()) == @main_kinds_summaries_digest_off
      assert digest(Kinds.tool_schemas()) == @main_kinds_tool_schemas_digest_off
    end
  end
end
