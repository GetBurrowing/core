defmodule Platform.RoleTest do
  @moduledoc """
  The web role's child classification (task 01a155a6 stage 1).

  Every id here is computed from `Platform.Application.children/2`, the
  function `start/2` itself calls, with a flag reader that turns every gate
  on, so a child added to the boot list tomorrow is classified or this file
  fails. The one transcribed list is test (c)'s golden order, which is the
  point of that test: it pins today's `:full` boot order.

  NOT async: the runtime.exs cases set `PLATFORM_ROLE` in the OS
  environment, restored on exit.
  """

  use ExUnit.Case, async: false

  alias Platform.Role

  @runtime_exs Path.expand("../../config/runtime.exs", __DIR__)

  defp all_on, do: fn _app, _key, _default -> true end

  defp ids(role), do: Enum.map(Platform.Application.children(role, all_on()), &Role.child_id/1)

  describe "(a) classification is total and disjoint" do
    test "every child the full role can start is in @web or @background" do
      unclassified = ids(:full) -- (Role.web_ids() ++ Role.background_ids())

      assert unclassified == [], """
      Platform.Application starts children that Platform.Role does not
      classify. Add each id to @web or @background in lib/platform/role.ex,
      following the rule in its moduledoc:

      #{Enum.map_join(unclassified, "\n", &"  - #{inspect(&1)}")}
      """
    end

    test "@web and @background do not overlap" do
      overlap =
        MapSet.intersection(MapSet.new(Role.web_ids()), MapSet.new(Role.background_ids()))

      assert MapSet.size(overlap) == 0, "classified as both: #{inspect(MapSet.to_list(overlap))}"
    end

    test "no classified id is stale" do
      stale = (Role.web_ids() ++ Role.background_ids()) -- (ids(:full) ++ Role.web_only_ids())
      assert stale == [], "classified but never started: #{inspect(stale)}"
    end

    test "child ids are unique, so filtering by id cannot drop or keep a twin" do
      assert ids(:full) == Enum.uniq(ids(:full))
    end
  end

  describe "(b) the web role never starts a dispatcher, scheduler or sender" do
    test "@never_on_web has an empty intersection with children(:web, all_on)" do
      started = MapSet.intersection(MapSet.new(Role.never_on_web()), MapSet.new(ids(:web)))
      assert MapSet.size(started) == 0, "started under :web: #{inspect(MapSet.to_list(started))}"
    end

    test "nothing classified background starts under :web" do
      started = MapSet.intersection(MapSet.new(Role.background_ids()), MapSet.new(ids(:web)))
      assert MapSet.size(started) == 0, "started under :web: #{inspect(MapSet.to_list(started))}"
    end

    test "the web role still serves: Repo, PubSub, Presence and the Endpoint start" do
      serving = [Platform.Repo, Phoenix.PubSub.Supervisor, Platform.Chat.Presence]

      for id <- serving ++ [PlatformWeb.Endpoint] do
        assert id in ids(:web), "#{inspect(id)} missing under :web"
      end
    end

    test "the web list keeps the full role's relative order" do
      assert ids(:web) -- Role.web_only_ids() ==
               Enum.filter(ids(:full), &(&1 in Role.web_ids()))
    end

    test "web-only children start under :web and never under :full" do
      for id <- Role.web_only_ids() do
        assert id in Role.web_ids(), "#{inspect(id)} is web-only but not in @web"
        assert id in ids(:web), "#{inspect(id)} missing under :web"
        refute id in ids(:full), "#{inspect(id)} starts under :full"
      end
    end

    test "the boot gate starts directly after Vault.Encryption and Repo, before anything serves" do
      web = ids(:web)
      gate = Enum.find_index(web, &(&1 == Platform.Role.BootGate))

      assert Enum.slice(web, gate - 2, 3) == [
               Platform.Vault.Encryption,
               Platform.Repo,
               Platform.Role.BootGate
             ]

      assert gate < Enum.find_index(web, &(&1 == PlatformWeb.Endpoint))
    end
  end

  describe "stage 3: the peer link and the relay receiver" do
    test "the peer link starts directly after PubSub under :web, before the Endpoint" do
      web = ids(:web)
      link = Enum.find_index(web, &(&1 == Platform.Role.PeerLink))

      assert Enum.at(web, link - 1) == Phoenix.PubSub.Supervisor
      assert link < Enum.find_index(web, &(&1 == PlatformWeb.Endpoint))
    end

    test "the relay receiver starts under :full only" do
      assert Platform.Role.RelayReceiver in ids(:full)
      refute Platform.Role.RelayReceiver in ids(:web)
    end
  end

  describe "(c) :full boots exactly as before" do
    test "children(:full, all_on) keeps today's order, TaskRouterWatcher right after Endpoint" do
      assert ids(:full) == [
               Platform.Chat.AttachmentStorage.BootCheck,
               Platform.Vault.Encryption,
               Platform.Repo,
               PlatformWeb.Telemetry,
               DNSCluster,
               Phoenix.PubSub.Supervisor,
               Platform.Role.RelayReceiver,
               Platform.Agents.Registry,
               Platform.Execution.Registry,
               Platform.Orchestration.Registry,
               Platform.Chat.Registry,
               Platform.Meetings.Registry,
               Platform.Org.Wiki.Indexer,
               Platform.Agents.RuntimeSupervisor,
               Platform.Chat.CanvasSupervisor,
               Platform.Agents.ContextBroker,
               Platform.Context.Supervisor,
               Platform.Artifacts.Store,
               Platform.Execution.RunSupervisor,
               Platform.Orchestration.LeaseManager,
               Platform.Orchestration.TaskRouterSupervisor,
               Platform.Chat.AttentionRouter,
               Platform.Federation.NodeContext,
               Platform.Federation.RuntimePresence,
               Platform.Federation.DeadLetterReplay,
               Platform.Federation.Peers.NonceCache,
               Platform.Federation.Peers.Registry,
               Platform.Federation.Peers.Supervisor,
               Platform.Federation.Peers.Boot,
               Platform.TaskSupervisor,
               Platform.CodeMode.Slots,
               Platform.Canvas.ScriptEngine.Slots,
               Platform.CodeMode.Store,
               Platform.Push.RelayRateLimit,
               Platform.Push.APNsFinch,
               Platform.Chat.ContextPlane,
               Platform.Chat.ContextSummaryCache,
               Platform.Chat.ReplyFailure.Dedupe,
               Platform.Chat.ReplyFailure.Watchdog,
               Platform.AgentHost.Reconciler,
               Platform.Chat.ActiveAgentStore,
               Platform.ExternalAgents.EphemeralCredentials,
               Platform.Chat.Presence,
               Platform.Meetings.State,
               Platform.Meetings.PressWindow,
               Platform.Meetings.AskFloor,
               Platform.Meetings.SayRegistry,
               Platform.Meetings.VoiceSeatCache,
               Platform.Meetings.AgentActivity.Store,
               Platform.Meetings.IntentQueue.Supervisor,
               Platform.Vault.RefreshWorker,
               Platform.Chat.AttachmentReaper,
               Platform.Chat.AdHocFreezeListener,
               Platform.Responsibilities.Registry,
               Platform.Responsibilities.Router,
               Platform.Responsibilities.CutoverMonitor,
               Platform.Agents.SystemEventScheduler,
               Platform.Agents.MeetingHistorianHandler,
               Platform.Meetings.MeetingNotifier,
               Platform.Meetings.IntentClassifier,
               Platform.Meetings.IntentDispatcher,
               Platform.Responsibilities.StallRegistry,
               Platform.Lifecycle.StepRegistry,
               Platform.Meetings.SummarizerSweeper,
               Platform.Meetings.CandidateSweeper,
               Platform.Security.Sweeper,
               Platform.Chat.SpacePurger,
               Platform.Experiments.Signals.MailSubscriber,
               Platform.Tenancy.ContainerPurger,
               Platform.Files.Purger,
               Platform.Prototypes.Purger,
               Platform.Memory.Insights.Purger,
               Platform.Memory.Insights.Disseminator,
               Platform.Files.CatalogEmitter,
               Platform.Tasks.DeployMergeReconciler,
               PlatformWeb.Endpoint,
               Platform.Orchestration.TaskRouterWatcher,
               Platform.Federation.NodeClient,
               :meetings_sender_seed,
               Platform.Mail.Inbound.Supervisor,
               Platform.Mail.Outbox,
               :canvas_search_backfill,
               :burrow_docs_seed,
               :default_space_seed
             ]
    end

    test "the boot reader keeps the non-app-env gates on their existing sources" do
      prev = Application.get_env(:platform, :skip_attachment_storage_check)

      try do
        Application.put_env(:platform, :skip_attachment_storage_check, true)
        refute Platform.Application.boot_flag(:platform, :attachment_storage_boot_check, true)
        Application.put_env(:platform, :skip_attachment_storage_check, false)
        assert Platform.Application.boot_flag(:platform, :attachment_storage_boot_check, true)
      after
        Application.put_env(:platform, :skip_attachment_storage_check, prev)
      end

      assert Platform.Application.boot_flag(:platform, :mail_enabled, true) ==
               Platform.Mail.Config.enabled?()

      assert Platform.Application.boot_flag(:platform, :meetings_enabled, true) ==
               Platform.Meetings.Config.enabled?()

      assert Platform.Application.boot_flag(:platform, :node_client_enabled, true) ==
               (System.get_env("OPENCLAW_NODE_ENABLED") == "true")
    end
  end

  describe "(d) PLATFORM_ROLE parsing" do
    test "unset, empty and \"full\" give :full; \"web\" gives :web" do
      assert Role.parse!(nil) == :full
      assert Role.parse!("") == :full
      assert Role.parse!("full") == :full
      assert Role.parse!("web") == :web
    end

    test "any other value raises naming it; no aliases" do
      for value <- ["Web", "FULL", "worker", "web "] do
        assert_raise ArgumentError, ~r/PLATFORM_ROLE=#{Regex.escape(inspect(value))}/, fn ->
          Role.parse!(value)
        end
      end
    end

    test "role/0 defaults to :full" do
      prev = Application.fetch_env(:platform, :role)

      try do
        Application.delete_env(:platform, :role)
        assert Role.role() == :full
        refute Role.web?()
      after
        with {:ok, value} <- prev, do: Application.put_env(:platform, :role, value)
      end
    end
  end

  describe "PLATFORM_CLUSTER_PEER parsing" do
    test "unset or empty is no peer, on either role" do
      for role <- [:web, :full], value <- [nil, ""] do
        assert Role.parse_peer!(value, role) == nil
      end
    end

    test "a name@host under :web is that node" do
      assert Role.parse_peer!("platform@core-platform", :web) == :"platform@core-platform"
    end

    test "a value without name@host shape raises naming it" do
      for value <- ["core-platform", "@core-platform", "platform@"] do
        assert_raise ArgumentError,
                     ~r/PLATFORM_CLUSTER_PEER=#{Regex.escape(inspect(value))}/,
                     fn ->
                       Role.parse_peer!(value, :web)
                     end
      end
    end

    test "a peer under :full raises: the full node is the peer" do
      assert_raise ArgumentError, ~r/PLATFORM_ROLE is not "web"/, fn ->
        Role.parse_peer!("platform@core-platform", :full)
      end
    end
  end

  describe "(e) the web role runs only as a prod build" do
    test ":web with MIX_ENV dev or test raises, naming /dev/login" do
      for env <- [:dev, :test] do
        assert_raise ArgumentError, ~r{MIX_ENV=#{env}.*/dev/login}s, fn ->
          Role.validate!(:web, env)
        end
      end
    end

    test ":web with prod, and :full with any env, are accepted" do
      assert Role.validate!(:web, :prod) == :ok
      assert Role.validate!(:full, :dev) == :ok
      assert Role.validate!(:full, :test) == :ok
      assert Role.validate!(:full, :prod) == :ok
    end
  end

  describe "runtime.exs wiring" do
    setup do
      prev = System.get_env("PLATFORM_ROLE")

      on_exit(fn ->
        if prev,
          do: System.put_env("PLATFORM_ROLE", prev),
          else: System.delete_env("PLATFORM_ROLE")
      end)
    end

    test "unset PLATFORM_ROLE configures :full" do
      System.delete_env("PLATFORM_ROLE")
      config = Config.Reader.read!(@runtime_exs, env: :test)
      assert get_in(config, [:platform, :role]) == :full
    end

    test "PLATFORM_CLUSTER_PEER under the full role raises at config time" do
      System.delete_env("PLATFORM_ROLE")
      prev = System.get_env("PLATFORM_CLUSTER_PEER")
      System.put_env("PLATFORM_CLUSTER_PEER", "platform@core-platform")

      try do
        assert_raise ArgumentError, ~r/PLATFORM_CLUSTER_PEER/, fn ->
          Config.Reader.read!(@runtime_exs, env: :test)
        end
      after
        if prev,
          do: System.put_env("PLATFORM_CLUSTER_PEER", prev),
          else: System.delete_env("PLATFORM_CLUSTER_PEER")
      end
    end

    test "an unknown PLATFORM_ROLE raises at config time" do
      System.put_env("PLATFORM_ROLE", "worker")

      assert_raise ArgumentError, ~r/PLATFORM_ROLE="worker"/, fn ->
        Config.Reader.read!(@runtime_exs, env: :test)
      end
    end

    test "PLATFORM_ROLE=web outside prod raises at config time" do
      System.put_env("PLATFORM_ROLE", "web")

      assert_raise ArgumentError, ~r/MIX_ENV=test/, fn ->
        Config.Reader.read!(@runtime_exs, env: :test)
      end
    end
  end
end
