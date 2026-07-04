defmodule Platform.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Platform.Config.validate!()

    Platform.Audit.TelemetryHandler.attach()
    Platform.Vault.TelemetryHandler.attach()
    Platform.Chat.TelemetryHandler.attach()
    Platform.Memory.TelemetryHandler.attach()

    children =
      (maybe_chat_storage_boot_check() ++
         [
           Platform.Vault.Encryption,
           Platform.Repo,
           PlatformWeb.Telemetry,
           {DNSCluster, query: Application.get_env(:platform, :dns_cluster_query) || :ignore},
           {Phoenix.PubSub, name: Platform.PubSub},
           {Registry, keys: :unique, name: Platform.Agents.Registry},
           {Registry, keys: :unique, name: Platform.Execution.Registry},
           {Registry, keys: :unique, name: Platform.Orchestration.Registry},
           {Registry, keys: :unique, name: Platform.Chat.Registry},
           Platform.Agents.RuntimeSupervisor,
           Platform.Chat.CanvasSupervisor,
           # ContextBroker — must start after the agent registry/runtime tree
           Platform.Agents.ContextBroker,
           # Context plane supervisor — must start after PubSub
           Platform.Context.Supervisor,
           # Artifact substrate — task/run artifact records + publication history
           Platform.Artifacts.Store,
           # Execution plane — run supervisor (registry started above)
           Platform.Execution.RunSupervisor,
           # Orchestration — task router supervisor (registry started above)
           Platform.Orchestration.TaskRouterSupervisor,
           # Orchestration — declarative watcher: starts/stops routers based on task state
           Platform.Orchestration.TaskRouterWatcher,
           # Node context — ETS-backed space tracking for node canvas commands
           Platform.Federation.NodeContext,
           # Federation runtime presence tracker — before Endpoint so channels can use it
           Platform.Federation.RuntimePresence,
           # Dead letter buffer — in-process ring buffer for delivery failures
           Platform.Federation.DeadLetterBuffer,
           # Task supervisor for parallel agent dispatch (ADR 0027)
           {Task.Supervisor, name: Platform.TaskSupervisor},
           # Context plane — shared ETS context for federation (after Repo, before AttentionRouter)
           Platform.Chat.ContextPlane,
           # Active agent mutex — ETS-backed per-space agent tracking (ADR 0027)
           Platform.Chat.ActiveAgentStore,
           # External-agent ephemeral credentials — ETS-backed, lost on
           # restart (M3 decision 6: no orphaned secrets). DB-backed
           # vault path lives in Platform.Vault.
           Platform.ExternalAgents.EphemeralCredentials,
           # Chat presence — must start after PubSub
           Platform.Chat.Presence,
           # Per-user meeting state — ETS-backed cache + PubSub broadcaster
           # (task 019ee06b). Owns :meeting_user_state table; must start
           # after PubSub so broadcast_* helpers always have a bus.
           Platform.Meetings.State,
           # Per-room intent queue — ETS-backed staging area for
           # classified transcript intents (task 019f2452). Owns
           # :meeting_intent_queue table; subscribes to meeting:finished
           # so must start after PubSub. Meeting-lifetime state, not
           # durable — deliberately ETS not Ecto.
           Platform.Meetings.IntentQueue,
           # Vault OAuth token refresh worker — must start after Repo and Vault.Encryption
           Platform.Vault.RefreshWorker,
           # Reap expired pending attachments (ADR 0039) — needs Repo
           Platform.Chat.AttachmentReaper,
           # Policy 2 ad-hoc freeze listener (consumer side of D-6) —
           # subscribes to "chat:agent_runtime" and freezes in-context
           # messages on :agent_first_state_op signals. Needs Repo + PubSub.
           Platform.Chat.AdHocFreezeListener,
           # Start to serve requests, typically the last entry
           PlatformWeb.Endpoint
         ])
      |> maybe_add_attention_router()
      |> maybe_add_node_client()
      |> maybe_add_responsibilities_registry()
      |> maybe_add_responsibility_router()
      |> maybe_add_cutover_monitor()
      |> maybe_add_system_event_scheduler()
      |> maybe_add_wiki_indexer()
      |> maybe_add_meeting_historian_handler()
      |> maybe_add_meeting_notifier()
      |> maybe_add_meeting_intent_classifier()
      |> maybe_add_stall_registry()
      |> maybe_add_summarizer_sweeper()
      |> ensure_task_router_watcher_after_endpoint()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Platform.Supervisor]
    result = Supervisor.start_link(children, opts)

    # After the supervision tree comes up, wire the default sweep
    # callback into StallRegistry so the sweeper's `:tick` handler
    # picks it up alongside any callbacks registered by follow-up
    # runtimes (task 019f2566 stage 6). Guarded on the sweeper boot
    # flag so tests — which start their own per-case sweeper — don't
    # end up with a global registration pointing at a name that isn't
    # running.
    maybe_register_default_sweep_callback()

    result
  end

  # Fail-closed: run unless explicitly skipped (dev/test). Prevents the
  # durability check from being silently bypassed in staging or any other
  # non-:prod-but-still-real environment.
  defp maybe_chat_storage_boot_check do
    if Application.get_env(:platform, :skip_attachment_storage_check, false) do
      []
    else
      [Platform.Chat.AttachmentStorage.BootCheck]
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  defp maybe_add_attention_router(children) do
    if Application.get_env(:platform, :start_attention_router, true) do
      insert_at =
        Enum.find_index(children, fn child ->
          child == Platform.Orchestration.TaskRouterWatcher
        end) ||
          -1

      List.insert_at(children, insert_at, Platform.Chat.AttentionRouter)
    else
      children
    end
  end

  defp maybe_add_node_client(children) do
    if System.get_env("OPENCLAW_NODE_ENABLED") == "true" do
      children ++ [Platform.Federation.NodeClient]
    else
      children
    end
  end

  defp maybe_add_system_event_scheduler(children) do
    if Application.get_env(:platform, :start_system_event_scheduler, true) do
      idx = Enum.find_index(children, &(&1 == PlatformWeb.Endpoint)) || length(children)
      List.insert_at(children, idx, Platform.Agents.SystemEventScheduler)
    else
      children
    end
  end

  # Responsibilities Registry (ADR-0041 M1 stage 4): boot-time upsert of
  # every provider-declared responsibility row. Must come after
  # `Platform.Repo` (it writes to the DB on init) and before
  # `Platform.Agents.SystemEventScheduler` (M6 will eventually swap the
  # scheduler over to read the table). Tests disable this via
  # `:start_responsibilities_registry false` and spin up per-case
  # instances with their own registered name for DataCase ownership.
  defp maybe_add_responsibilities_registry(children) do
    if Application.get_env(:platform, :start_responsibilities_registry, true) do
      idx =
        Enum.find_index(children, &(&1 == Platform.Agents.SystemEventScheduler)) ||
          Enum.find_index(children, &(&1 == PlatformWeb.Endpoint)) ||
          length(children)

      List.insert_at(children, idx, Platform.Responsibilities.Registry)
    else
      children
    end
  end

  # Responsibilities Router (ADR-0041 M6 stage 1): runtime trigger
  # router that walks the registry on boot and (in later stages)
  # dispatches cron / event_topic / chat_pattern / webhook fires. Must
  # start AFTER `Platform.Responsibilities.Registry` so the registry
  # rows are upserted before the router walks them, and AFTER
  # `Platform.Repo` for the same reason. Runs side-by-side with
  # `Platform.Agents.SystemEventScheduler` until M8 cutover. Tests
  # disable this via `:start_responsibility_router false` and start
  # per-case instances with their own registered name.
  defp maybe_add_responsibility_router(children) do
    if Application.get_env(:platform, :start_responsibility_router, true) do
      idx =
        Enum.find_index(children, &(&1 == Platform.Agents.SystemEventScheduler)) ||
          Enum.find_index(children, &(&1 == PlatformWeb.Endpoint)) ||
          length(children)

      List.insert_at(children, idx, Platform.Responsibilities.Router)
    else
      children
    end
  end

  # Cutover monitor (ADR-0041 M8 stage 6): subscribes to
  # `[:platform, :responsibility, :fired]` + `[:platform, :responsibilities, :dual_write]`
  # telemetry events to maintain per-day counters of router vs legacy
  # firings. The `mix responsibilities.cutover_report` task reads from
  # this singleton. Must start after the Router (telemetry emitter) and
  # before SystemEventScheduler (the other emitter) so neither one
  # races the monitor at first fire — both are tolerant of an attached
  # handler that hasn't seen its first message yet, so order is a
  # belt-and-braces choice rather than strict.
  defp maybe_add_cutover_monitor(children) do
    if Application.get_env(:platform, :start_cutover_monitor, true) do
      idx =
        Enum.find_index(children, &(&1 == Platform.Agents.SystemEventScheduler)) ||
          Enum.find_index(children, &(&1 == PlatformWeb.Endpoint)) ||
          length(children)

      List.insert_at(children, idx, Platform.Responsibilities.CutoverMonitor)
    else
      children
    end
  end

  # T3 (ADR-0041): Platform.Org.Wiki.Indexer subscribes to the
  # "org_wiki:index" PubSub topic at init/1. Insert it after PubSub (its
  # dependency) and before the agent supervisors, so any agent-driven
  # wiki write has a subscriber attached. Tests set
  # `:start_wiki_indexer` to false and start their own indexer per
  # case — keeps DataCase-sandboxed tests from racing a real subscriber.
  defp maybe_add_wiki_indexer(children) do
    if Application.get_env(:platform, :start_wiki_indexer, true) do
      insert_at =
        Enum.find_index(children, fn child ->
          child == Platform.Agents.RuntimeSupervisor
        end) || length(children)

      List.insert_at(children, insert_at, Platform.Org.Wiki.Indexer)
    else
      children
    end
  end

  defp maybe_add_meeting_historian_handler(children) do
    if Application.get_env(:platform, :start_meeting_historian_handler, true) do
      idx = Enum.find_index(children, &(&1 == PlatformWeb.Endpoint)) || length(children)
      List.insert_at(children, idx, Platform.Agents.MeetingHistorianHandler)
    else
      children
    end
  end

  # MeetingNotifier subscribes to project meeting lifecycle topics at boot
  # and fans out push notifications on `:meeting_started`. Must live in the
  # supervisor (not a LiveView) because per-session subscribers drop the
  # broadcast when no MeetingLive is open. Disabled in test env; tests
  # start their own instance per case for sandbox ownership.
  defp maybe_add_meeting_notifier(children) do
    if Application.get_env(:platform, :start_meeting_notifier, true) do
      idx = Enum.find_index(children, &(&1 == PlatformWeb.Endpoint)) || length(children)
      List.insert_at(children, idx, Platform.Meetings.MeetingNotifier)
    else
      children
    end
  end

  # IntentClassifier (task 019f2452 stage 3): GenServer that subscribes
  # to `meeting:transcript_chunk` and (in later stages) fires the
  # `meetings.intent_classify` responsibility per chunk. Boots after
  # IntentQueue so the enqueue path (stage 4) has a live table to
  # write into. Disabled in test env; tests start their own instance
  # per case for DataCase sandbox ownership.
  defp maybe_add_meeting_intent_classifier(children) do
    if Application.get_env(:platform, :start_meeting_intent_classifier, true) do
      idx = Enum.find_index(children, &(&1 == PlatformWeb.Endpoint)) || length(children)
      List.insert_at(children, idx, Platform.Meetings.IntentClassifier)
    else
      children
    end
  end

  # SummarizerSweeper (task 019f2566 stage 2): periodic sweep over
  # stalled router-owned summarize dispatches. Must start after Repo
  # (queries meeting_transcripts) and after Platform.TaskSupervisor (it
  # spawns fallback bodies under it). Disabled in test env; tests start
  # their own per-case instance with a shortened `check_interval_ms` +
  # `stall_window_ms` for DataCase sandbox ownership.
  defp maybe_add_summarizer_sweeper(children) do
    if Application.get_env(:platform, :start_summarizer_sweeper, true) do
      idx = Enum.find_index(children, &(&1 == PlatformWeb.Endpoint)) || length(children)
      List.insert_at(children, idx, Platform.Meetings.SummarizerSweeper)
    else
      children
    end
  end

  # StallRegistry (task 019f2566 stage 6): pure in-memory MapSet of
  # `{module, function/0}` sweep callbacks that the SummarizerSweeper's
  # tick handler walks. Must start BEFORE the sweeper so the sweeper's
  # first tick has a populated (or at least reachable) registry.
  # Disabled in test env; tests start their own per-case instance.
  defp maybe_add_stall_registry(children) do
    if Application.get_env(:platform, :start_stall_registry, true) do
      idx =
        Enum.find_index(children, &(&1 == Platform.Meetings.SummarizerSweeper)) ||
          Enum.find_index(children, &(&1 == PlatformWeb.Endpoint)) ||
          length(children)

      List.insert_at(children, idx, Platform.Responsibilities.StallRegistry)
    else
      children
    end
  end

  # Wire the summarizer's own sweep body into StallRegistry after the
  # supervision tree comes up. Idempotent (MapSet-backed) so accidental
  # re-application on a hot reload is harmless. Guarded on both flags
  # so it's a no-op in test env, where per-case sweepers drive
  # `sweep_now/1` directly.
  defp maybe_register_default_sweep_callback do
    start_sweeper? = Application.get_env(:platform, :start_summarizer_sweeper, true)
    start_registry? = Application.get_env(:platform, :start_stall_registry, true)

    if start_sweeper? and start_registry? do
      Platform.Responsibilities.StallRegistry.register(
        {Platform.Meetings.SummarizerSweeper, :sweep_meetings_summarize}
      )
    end

    :ok
  end

  defp ensure_task_router_watcher_after_endpoint(children) do
    {watchers, others} =
      Enum.split_with(children, &(&1 == Platform.Orchestration.TaskRouterWatcher))

    case watchers do
      [] ->
        children

      [watcher] ->
        insert_at =
          (Enum.find_index(others, &(&1 == PlatformWeb.Endpoint)) || length(others) - 1) + 1

        List.insert_at(others, insert_at, watcher)
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    PlatformWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
