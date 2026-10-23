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
      test env on test-host, not copied from this branch. The with-Play parity
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

  @core_kinds ~w(stack row card text markdown heading badge image code mermaid embed form action_row checklist checklist_item table prototype)

  setup do
    on_exit(fn -> Application.delete_env(:platform, :fixture_extension_test_pid) end)
    :ok
  end

  defp unique, do: System.unique_integer([:positive])

  defp insert_ext_user do
    Repo.insert!(%User{
      email: "ext-inbox-#{unique()}@example.com",
      name: "Extensions Inbox User",
      oidc_sub: "ext-inbox-#{unique()}"
    })
  end

  defp fixture_inbox_attrs(user) do
    %{
      user_id: user.id,
      kind: "fixture_request",
      source_type: "fixture_thing",
      source_id: Ecto.UUID.generate(),
      title: "A fixture asks"
    }
  end

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
        tool_profile: []
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
      assert "fixture" in Platform.Access.RuntimeProfiles.valid_modules()
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

    test "tool context: an extension tool gets the calling agent's home org, never a client's" do
      tenant = Platform.TenancyFixtures.tenant_org_id("ext-tenant-#{unique()}")
      other = Platform.TenancyFixtures.tenant_org_id("ext-other-#{unique()}")

      pinned =
        Repo.insert!(%Platform.Agents.Agent{
          slug: "ext-pinned-#{unique()}",
          name: "Pinned",
          metadata: %{"org_id" => tenant}
        })

      unpinned =
        Repo.insert!(%Platform.Agents.Agent{slug: "ext-unpinned-#{unique()}", name: "Unpinned"})

      assert {:ok, %{agent_home_org: {:tenant, ^tenant}}} =
               ToolSurface.execute("fixture_echo", %{"org_id" => other}, %{
                 agent_id: pinned.id
               })

      assert {:ok, %{agent_home_org: :root}} =
               ToolSurface.execute("fixture_echo", %{}, %{agent_id: unpinned.id})

      # A client-supplied context key is overwritten, not trusted.
      assert {:ok, %{agent_home_org: {:tenant, ^tenant}}} =
               ToolSurface.execute("fixture_echo", %{}, %{
                 agent_id: pinned.id,
                 agent_home_org: :root
               })
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
      # ADR 0055 section 2: telemetry handlers, responsibility providers and
      # prompt templates are declared, and deliberately read by nobody yet.
      # routes/0 got its reader in task 01a140a9 (see the routes/0 case).
      optional = Platform.Extension.behaviour_info(:optional_callbacks)

      for callback <- [
            routes: 0,
            telemetry_handlers: 0,
            responsibility_providers: 0,
            prompt_templates: 0
          ] do
        assert callback in optional
      end

      refute function_exported?(Extensions, :telemetry_handlers, 0)
      refute function_exported?(Extensions, :responsibility_providers, 0)
      refute function_exported?(Extensions, :prompt_templates, 0)
    end

    test "canvas kind: the inline chat-message path passes the renderer's viewer through" do
      require Phoenix.LiveViewTest

      canvas = %Platform.Chat.Canvas{
        id: Ecto.UUID.generate(),
        title: "Fixture",
        document: %{
          "version" => 1,
          "revision" => 1,
          "root" => %{"id" => "root", "type" => "fixture_widget", "props" => %{}}
        }
      }

      render = fn viewer ->
        Phoenix.LiveViewTest.render_component(
          &PlatformWeb.Components.ChatInlineCanvas.inline_canvas/1,
          msg: %{id: Ecto.UUID.generate()},
          canvas: canvas,
          title: "Fixture",
          mounted_ids: :all,
          viewer: viewer
        )
      end

      assert render.({:user, "u-1"}) =~ ~s(data-viewer="user:u-1")
      assert render.(nil) =~ ~s(data-viewer="none")
    end

    test "inbox kind: emitted, kept listed on open, labelled, and never core's push or mobile kind" do
      user = insert_ext_user()

      assert {:ok, item} = Platform.Inbox.emit(fixture_inbox_attrs(user))
      assert item.kind == "fixture_request"
      assert "fixture_request" in Platform.Inbox.Item.kinds()
      assert "fixture_thing" in Platform.Inbox.Item.source_types()
      assert "fixture_request" in Platform.Inbox.action_kinds()

      # Opening an action kind marks it read and leaves it listed.
      assert {:ok, opened} = Platform.Inbox.open_item(item.id, user.id)
      assert opened.read_at
      assert opened.dismissed_at == nil
      assert Enum.any?(Platform.Inbox.list_unread_for_user(user.id), &(&1.id == item.id))

      # The label and icon come from the extension's spec.
      html =
        Phoenix.LiveViewTest.rendered_to_string(
          PlatformWeb.Components.InboxItem.inbox_item(%{
            id: "inbox-item-#{item.id}",
            item: opened,
            space_label: nil,
            selectable: false,
            selected: false
          })
        )

      assert html =~ "Fixture needs you"
      assert html =~ "hero-beaker"

      # Core's own lists stay closed: no push, no external reach, no mobile approval.
      refute "fixture_request" in Platform.Inbox.push_kinds()
      refute "fixture_request" in Platform.Inbox.core_action_kinds()
      refute "fixture_request" in Platform.Mobile.AppEntities.approval_kinds()
      refute "fixture_request" in Platform.Inbox.Item.core_kinds()
    end

    test "routes/0 has a reader: the fixture's route is listed and found by prefix" do
      assert [%{prefix: "fixture", plug: FixtureExtension.EchoPlug}] = Extensions.routes()
      assert %{plug: FixtureExtension.EchoPlug} = Extensions.route_for("fixture")
      assert Extensions.route_for("nope") == nil
      assert Extensions.route_for(nil) == nil
    end

    test "live_pages/0 has a reader: the fixture's page is listed and found by prefix" do
      assert [%{prefix: "fixture", live_view: FixtureExtension.Page}] = Extensions.live_pages()
      assert %{live_view: FixtureExtension.Page} = Extensions.live_page_for("fixture")
      assert Extensions.live_page_for("nope") == nil
      assert Extensions.live_page_for(nil) == nil
      assert {:live_pages, 0} in Platform.Extension.behaviour_info(:optional_callbacks)
    end
  end

  describe "with :extensions = []" do
    setup do
      FixtureExtension.register([])
      :ok
    end

    test "an extension inbox kind is a changeset error while its extension is not registered" do
      user = insert_ext_user()

      assert {:error, changeset} = Platform.Inbox.emit(fixture_inbox_attrs(user))
      assert Keyword.has_key?(changeset.errors, :kind)
      assert Keyword.has_key?(changeset.errors, :source_type)
      assert Extensions.inbox_kinds() == []
      assert Platform.Inbox.Item.kinds() == Platform.Inbox.Item.core_kinds()
      # Core's non-approval `briefing` and `meeting_briefing` stay listed on
      # open but are never core (Mobile approval) action kinds (tasks 01a15ee1
      # stage 1 and 01a1694a stage 2).
      assert Platform.Inbox.action_kinds() ==
               Platform.Inbox.core_action_kinds() ++ ["briefing", "meeting_briefing"]

      assert PlatformWeb.Components.InboxItem.kind_label("fixture_request") == "Fixture request"
      assert PlatformWeb.Components.InboxItem.kind_icon("fixture_request") == "hero-bell"
    end

    test "the empty generated entry is exactly core's none.js registry" do
      assert Platform.Extensions.AssetEntry.js([], "/tmp") =~ "export default {\n}"
      assert Extensions.assets() == []
    end

    test "no extension entry appears in any seam, and nothing raises" do
      assert Kinds.names() == @core_kinds
      assert ToolSurface.all_bundles() == ToolSurface.core_bundles()
      refute "play" in Platform.Access.RuntimeProfiles.valid_modules()
      refute Enum.any?(ToolSurface.tool_definitions(), &String.starts_with?(&1.name, "play_"))
      refute Enum.any?(Surfaces.list(), &String.starts_with?(&1.key(), "game_stream."))
      refute Enum.any?(Metrics.known_metrics(), &String.starts_with?(&1, "game_stream"))
      refute :fixture in Enum.map(IconRail.destinations(root_user: true), & &1.key)
      assert Extensions.migrations_paths() == []
      assert Platform.MixSupport.extension_migration_args() == []
      assert Extensions.live_hooks() == []
      assert Extensions.routes() == []
      assert Extensions.live_pages() == []
      assert Extensions.live_page_for("fixture") == nil
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
          from(r in Platform.Access.RuntimeProfile, where: r.runtime_id == ^runtime.id),
          set: [tool_profile: ["space", "play"]]
        )

      runtime = Repo.get!(AgentRuntime, runtime.id)

      assert {:ok, saved} =
               Platform.Access.RuntimeProfiles.set_tool_profile(runtime, [
                 "space",
                 "files",
                 "play"
               ])

      assert saved.tool_profile == ["space", "files", "play"]
      assert Platform.Access.RuntimeProfiles.tool_profile(runtime) == ["space", "files", "play"]

      # The same bundle ADDED to a row that never held it is refused.
      {:ok, fresh} = Federation.register_runtime(user.id, %{runtime_id: "fresh-#{unique()}"})

      assert {:error, :invalid_module} =
               Platform.Access.RuntimeProfiles.set_tool_profile(fresh, ["space", "play"])

      # And so is one on a new row.
      assert {:error, _} =
               Federation.register_runtime(user.id, %{
                 runtime_id: "new-#{unique()}",
                 tool_profile: ["play"]
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
    defmodule BadRoutePrefix do
      @moduledoc false
      @behaviour Platform.Extension
      def canvas_kinds, do: []
      def mcp_tool_bundles, do: []
      def runtime_channel_events, do: []
      def handle_runtime_event(_e, _r, _p), do: :ok
      def runtime_disconnected(_r), do: :ok
      def live_hooks, do: []
      def experiment_surfaces, do: []
      def experiment_metrics, do: %{}
      def migrations_path, do: nil
      def routes, do: [%{prefix: "Bad/Prefix", plug: Platform.FixtureExtension.EchoPlug}]
    end

    defmodule BadLivePage do
      @moduledoc false
      @behaviour Platform.Extension
      def canvas_kinds, do: []
      def mcp_tool_bundles, do: []
      def runtime_channel_events, do: []
      def handle_runtime_event(_e, _r, _p), do: :ok
      def runtime_disconnected(_r), do: :ok
      def live_hooks, do: []
      def experiment_surfaces, do: []
      def experiment_metrics, do: %{}
      def migrations_path, do: nil

      def live_pages,
        do: [
          %{prefix: "fixture", live_view: Platform.FixtureExtension.Page},
          %{prefix: "Bad/Page", live_view: Platform.FixtureExtension.Page}
        ]
    end

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

      assert ~s(route prefix "fixture" is claimed by #{inspect(FixtureExtension)} and by #{inspect(FixtureExtension.Twin)}) in messages

      assert ~s(live page prefix "fixture" is claimed by #{inspect(FixtureExtension)} and by #{inspect(FixtureExtension.Twin)}) in messages
    end

    test "one live page prefix alone validates; a second claim is the only clash" do
      FixtureExtension.register([FixtureExtension])
      assert Extensions.validate() == :ok

      FixtureExtension.register([FixtureExtension, BadLivePage])
      assert {:error, messages} = Extensions.validate()

      assert ~s(live page prefix "fixture" is claimed by #{inspect(FixtureExtension)} and by #{inspect(BadLivePage)}) in messages

      assert ~s(live page prefix "Bad/Page" of #{inspect(BadLivePage)} is not one lowercase path segment) in messages

      assert length(messages) == 2
    end

    defmodule CoreInboxClash do
      @moduledoc false
      @behaviour Platform.Extension
      def canvas_kinds, do: []
      def mcp_tool_bundles, do: []
      def runtime_channel_events, do: []
      def handle_runtime_event(_e, _r, _p), do: :ok
      def runtime_disconnected(_r), do: :ok
      def live_hooks, do: []
      def experiment_surfaces, do: []
      def experiment_metrics, do: %{}
      def migrations_path, do: nil

      def inbox_kinds,
        do: [
          %{
            kind: "chat_mention",
            source_type: "task",
            label: "Mine",
            icon: "hero-bell",
            stays_listed_on_open: true
          }
        ]
    end

    test "an inbox kind or source type reusing core's, or another extension's, is refused" do
      FixtureExtension.register([CoreInboxClash])
      assert {:error, messages} = Extensions.validate()
      owner = inspect(CoreInboxClash)
      assert ~s(inbox kind "chat_mention" is claimed by core and by #{owner}) in messages
      assert ~s(inbox source type "task" is claimed by core and by #{owner}) in messages

      FixtureExtension.register([FixtureExtension, FixtureExtension.Twin])
      assert {:error, messages} = Extensions.validate()
      a = inspect(FixtureExtension)
      b = inspect(FixtureExtension.Twin)
      assert ~s(inbox kind "fixture_request" is claimed by #{a} and by #{b}) in messages
      assert ~s(inbox source type "fixture_thing" is claimed by #{a} and by #{b}) in messages

      FixtureExtension.register([FixtureExtension])
      assert Extensions.validate() == :ok
    end

    test "a route prefix that is not one lowercase path segment is refused" do
      FixtureExtension.register([BadRoutePrefix])
      assert {:error, messages} = Extensions.validate()

      assert ~s(route prefix "Bad/Prefix" of #{inspect(BadRoutePrefix)} is not one lowercase path segment) in messages
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
      {"canvas_create", "canvas"},
      {"canvas_patch", "canvas"},
      {"canvas_describe", "canvas"},
      {"canvas_list_kinds", "canvas"},
      {"canvas_template", "canvas"},
      {"canvas_versions", "canvas"},
      {"canvas_restore", "canvas"},
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
      {"stack_attach_canvas", "task"},
      {"stack_detach_canvas", "task"},
      {"janitor_hand_back", "task"},
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
      {"vault_fetch", "federation"},
      {"vault_list", "federation"},
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
      {"skill_list", "skill"},
      {"skill_get", "skill"},
      {"skill_upsert", "skill"},
      {"attachment_upload_inline", "attachment"},
      {"attachment_get_inline", "attachment"},
      {"attachment_upload_start", "attachment"},
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
      {"experiment_promote", "experiments"},
      {"dispatch_metrics_list", "experiments"},
      {"code_mode_report", "experiments"},
      {"burrow_run", "code_mode"},
      {"burrow_run_describe", "code_mode"},
      {"prototype_publish", "prototype"},
      {"prototype_versions", "prototype"},
      {"prototype_rollback", "prototype"}
    ]

    # Re-pinned by task 01a0fcfa stage 1: attachment_get_inline's `returns`
    # and `limitations` text now document the MCP image content block. That
    # is the only tool-definition change; names and bundles are unchanged.
    #
    # Re-pinned by task 01a114a8 stage 1: `dispatch_metrics_list` joins the
    # `experiments` bundle. Measured on test-host at the stage's branch.
    #
    # Re-pinned by task 01a114a8 stage 2: `suite_run` in the new `code_mode`
    # bundle, last. Measured on test-host at the stage's branch.
    #
    # Re-pinned by task 01a114a8 stage 3: `suite_run_describe`, the
    # `returns_schema` key on 12 definitions, federation_status's filter
    # parameters and the suite_run primer. Measured on test-host.
    #
    # Re-pinned by task 01a114a8 stage 4: `code_mode_report` in `experiments`,
    # plus doc text on experiment_create (dispatch_usage, agent_id cohort,
    # dispatch.code_mode target). Measured on test-host at the stage's branch.
    #
    # Re-pinned by task 01a115b5 stage 2: suite_run_describe's `detail`
    # parameter and description text. Measured on test-host at the stage's branch.
    #
    # Re-pinned by task 019fa1ac stage 1: task_create/task_update expose the
    # first-class kind taxonomy and task read/write docs now name kind.
    # Measured on test-host at the stage's branch (recomputed at the rebased tip
    # after main's Legacy scrub landed; see task 019fa1ac PR).
    #
    # Re-pinned by task 01a11ec3 stage 1: task_create/task_update expose
    # origin, trust and external repository/issue provenance alongside the
    # independent kind taxonomy. Measured on test-host at the stage's branch.
    #
    # Re-pinned by task 019fa1ac-6685 stage 3: `janitor_hand_back` in the
    # `task` bundle, after `stack_assign_agents`. Measured on test-host at the
    # stage's branch.
    #
    # Re-pinned at the stack/feedback-intake-boundary merge of origin/main
    # (c135cbe7, PR #1226): the stack's surface with main's Legacy-scrubbed tool
    # copy. Measured on test-host at the merge.
    #
    # Re-pinned by task 01a1316b-4e46 stage 1: the `prototype` bundle's three
    # tools, last. Measured on test-host at the stage's branch.
    #
    # Re-pinned by task 01a1316b-4e46 stage 2: the `prototype` canvas kind,
    # last in the registry, which also enters canvas_create/patch's document
    # schema. Measured on test-host at the stage's branch.
    #
    # Re-pinned by task 01a1316b-677a stage 1: the `embed` kind's `scripts`
    # and `prototype_ref` props and its srcdoc / list_kinds text, which also
    # enter canvas_create/patch's document schema. Measured on test-host at the
    # stage's branch.
    #
    # Re-pinned by task 01a1316b-aab0 stage 2: canvas_patch's operation
    # description names the new `set_binding` op (the MCP tool's text in
    # tool_surface.ex and the canvas tool schema in canvas/tools.ex).
    # Measured on test-host at the stage's branch.
    #
    # Re-pinned by task 01a131c5 stage 1: `vault_fetch` and `vault_list` in
    # the `federation` bundle, after `federation_status`. Measured on test-host at
    # the stage's branch.
    #
    # Re-pinned by the stack prototype-runtime rollup merge (#1235): both of the
    # above. Measured on test-host at the merge commit.
    #
    # Re-pinned by task 01a1386d-e528 stage 2 for stage 1's change: the
    # `memory_rename` tool's description and `limitations` now document the
    # prefix mode (both paths ending in `/` route to `Wiki.rename_prefix/3`).
    # Tool names and bundles are unchanged (the name assertion above passes
    # unmodified). Measured on test-host at the stage-2 branch.
    #
    # Re-pinned by task 01a1386d-e528 stage 5: the `canvas_get` tool's
    # `limitations` now says a canvas a `canvas.read` deny covers answers
    # exactly as a nonexistent one (canvas_get passes the runtime's Access
    # Scope to `ToolAccess.fetch_for_read/3`). Names and bundles unchanged.
    # Measured on test-host at the stage-5 wip ref.
    #
    # Re-pinned by task 01a14a7f stage 3: the 17 dotted tool names became
    # underscores (`canvas.create` -> `canvas_create`, ...), in names and in
    # every description that cites one, including the image kind's `src`
    # schema text (so the tool-schemas digest moves and the summaries digest
    # does not). Measured on test-host at the stage's branch (ac42fe5e).
    #
    # Re-pinned by task 01a14b9e-50a4 stage 1: `suite_run` / `suite_run_describe`
    # became `burrow_run` / `burrow_run_describe` (names, primer and
    # describe text), "Suite" became "Burrow" in tool_surface.ex's tool
    # descriptions, and code_mode_report's text names burrow_run. Bundles are
    # unchanged. Measured on test-host at the stage's branch (8cefc9fc).
    #
    # Re-pinned by task 01a14b9e-50a4 stage 2: product-name copy "Suite"
    # became "Burrow" in tool descriptions outside tool_surface.ex (canvas
    # tools' sharing boundary, experiment, mail-draft and prototype tools)
    # and in the canvas kind descriptions and the embed kind's `scripts`
    # schema text ("no Burrow cookies"), so the summaries and tool-schemas
    # digests move too. Names and bundles unchanged. Measured on test-host at the
    # stage's branch (512cdde0, 1a46cef5).
    #
    # Re-pinned by task 01a14b9e stage 3: tool descriptions name neutral
    # examples instead of one install's people and hosts (`alex-coder`,
    # `agent-1.host-a`, `infra` (test rig, ...), "a human picks option A or
    # B", "a human editor"). Names, bundles and schemas are unchanged.
    # Re-measured on the test rig after merging main (A2) into the stage branch.
    #
    # Re-pinned by task 01a1559a stage 1: the `limitations` prose of
    # task_attach_canvas, task_detach_canvas and task_list_canvases names the
    # new gate (`tasks.write` / `tasks.read` in the task's org) in place of
    # the deleted assignee / phase assignee / space participant / sponsor /
    # org member rule. Names, bundles and schemas are unchanged. Measured on the
    # test rig at the stage's branch (19ff66f7).
    #
    # Re-pinned by task 01a1559a stage 2: `stack_attach_canvas` and
    # `stack_detach_canvas` in the `task` bundle, after `stack_assign_agents`
    # (the name list above carries them). Summaries and schemas are unchanged.
    # Measured on the test rig at the stage's branch (d8f4696c).
    #
    # Re-pinned by task 01a1655c stage 2: `send_media` gains the optional
    # `attachment_ids` property (attach already-uploaded files) and the prose
    # that describes it. Names and bundles are unchanged. Measured by CI on the
    # task branch (31dffde47), PR #1320.
    @main_tool_digest_off "443265c57c1616d5b40c9aafaefc9ab9ca80cf37b0f95575e1a0363b5aa3efba"
    @main_kinds_summaries_digest_off "514cb7a62dea7ea34226d7b60d2f243d5bb9a940bc1f5d44fd2e0e27e8074c52"
    @main_kinds_tool_schemas_digest_off "45c4c34283c8da212f6ab061ae43d1582e41b7192e8f8a442bfd45b3dd6f8e86"
    # main's lists minus exactly `play`.
    @core_bundles ~w(canvas messaging task plan review space context_read federation memory skill attachment files meetings mail experiments code_mode prototype access)
    @core_valid_bundles ~w(federation space context_read messaging review canvas task plan memory skill attachment files meetings mail experiments code_mode prototype access)
    @main_rail [
      :chat,
      :tasks,
      :inbox,
      :activity,
      :agents,
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
    @core_metrics ~w(cycle_time insight_acceptance_rate manual_gate_rejection_rate overscoped_gate_count plan_revision_count stages_per_plan time_in_phase validation_failure_rate)
    @core_surfaces ~w(dispatch.prompt mail.draft.generator planner.stage_budget chat.context_summary meetings.open_question_classifier dispatch.product_docs_preamble dispatch.code_mode agents.tool_profile memory.insight_synthesis)

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

    defp legacy_kind_props(%{"properties" => %{"type" => %{"const" => kind}}} = node)
         when kind in ["text", "action_row"] do
      path = ["properties", "props", "properties"]

      node =
        if kind == "text",
          do: update_in(node, path, &Map.delete(&1, "principal_id")),
          else:
            update_in(
              node,
              path ++ ["actions", "items", "properties"],
              &Map.delete(&1, "disabled")
            )

      Map.new(node, fn {key, value} -> {key, legacy_kind_props(value)} end)
    end

    defp legacy_kind_props(map) when is_map(map),
      do: Map.new(map, fn {key, value} -> {key, legacy_kind_props(value)} end)

    defp legacy_kind_props(list) when is_list(list), do: Enum.map(list, &legacy_kind_props/1)
    defp legacy_kind_props(value), do: value

    setup do
      assert Extensions.list() == []
      :ok
    end

    test "tool_definitions/0 is main's flag-off list, name for name and byte for byte" do
      defs = ToolSurface.tool_definitions()
      {access, legacy} = Enum.split_with(defs, &(&1.bundle == "access"))

      assert Enum.map(access, & &1.name) ==
               ~w(access_explain access_propose access_apply access_undo)

      assert Enum.map(legacy, &{&1.name, &1.bundle}) == @main_tool_names_off
      # canvas_create embeds the kind union. Strip only the two additive
      # consent-card properties, preserving the legacy definition oracle.
      assert digest(legacy_kind_props(legacy)) == @main_tool_digest_off
    end

    test "bundles, kinds, metrics, surfaces and rail are main's minus the module's entries" do
      assert ToolSurface.all_bundles() == @core_bundles
      assert Platform.Access.RuntimeProfiles.valid_modules() == @core_valid_bundles
      assert Metrics.known_metrics() == @core_metrics
      assert Enum.map(Metrics.catalog(), & &1.slug) |> Enum.sort() == Enum.sort(@core_metrics)
      assert Enum.map(Surfaces.list(), & &1.key()) == @core_surfaces
      assert Enum.map(IconRail.destinations(root_user: true), & &1.key) == @main_rail
      assert Kinds.names() == @core_kinds
      # Consent cards add two optional props; retain the byte-level oracle
      # for every pre-existing field and independently assert each addition.
      summaries =
        Enum.map(Kinds.summaries(), fn
          %{kind: "text"} = row -> %{row | props: Map.delete(row.props, "principal_id")}
          row -> row
        end)

      schemas = Kinds.tool_schemas()
      text_path = ["text", "properties", "props", "properties"]

      action_path = [
        "action_row",
        "properties",
        "props",
        "properties",
        "actions",
        "items",
        "properties"
      ]

      assert get_in(schemas, text_path ++ ["principal_id"]) == %{"type" => "string"}
      assert get_in(schemas, action_path ++ ["disabled"]) == %{"type" => "boolean"}

      legacy_schemas =
        schemas
        |> update_in(text_path, &Map.delete(&1, "principal_id"))
        |> update_in(action_path, &Map.delete(&1, "disabled"))

      assert digest(summaries) == @main_kinds_summaries_digest_off
      assert digest(legacy_schemas) == @main_kinds_tool_schemas_digest_off
    end
  end
end
