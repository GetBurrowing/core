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
    Platform.Meetings.TelemetryHandler.attach()
    # Task 019f70b8 stage 6: the two SYSTEM-originated writers of the
    # `meeting_intent_corrections` few-shot corpus. Separate from the
    # Meetings handler above, which mirrors telemetry into the audit
    # store — these events produce a durable tuning row, not an audit
    # event, and conflating them would put the corpus behind audit's
    # retention rules.
    Platform.Meetings.IntentCorrections.TelemetryHandler.attach()
    Platform.Memory.TelemetryHandler.attach()
    # rbac-external-users M3 stage 3 (task 019f8837): fan out an admin
    # notification + live-append broadcast on every ungranted (holding)
    # external login.
    Platform.Accounts.ExternalAdmissionNotifier.attach()

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
           # Per-meeting process registry (task 019f70b8 stage 2).
           # Holds TWO key shapes, both owned by
           # Platform.Meetings.IntentQueue.Server: the meeting_id
           # binary the server is registered under, and a
           # `{:intent, intent_id}` reverse index (stage 3) so the
           # `intent_ack` MCP tool can resolve an intent id — the only
           # handle a remote runtime has — back to its meeting.
           {Registry, keys: :unique, name: Platform.Meetings.Registry},
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
           # Orchestration — ephemeral in-memory lease store (task
           # 019f640d stage 2). Owns the `:orchestration_lease_manager`
           # ETS table backing the event-driven router's ack/safety-net
           # state. Must start BEFORE TaskRouterSupervisor so any
           # router boot can call `record_dispatch/4` without racing
           # the table.
           Platform.Orchestration.LeaseManager,
           # Orchestration — task router supervisor (registry started above)
           Platform.Orchestration.TaskRouterSupervisor,
           # Orchestration — declarative watcher: starts/stops routers based on
           # task state. NOT listed inline: it is inserted here by
           # `maybe_add_task_router_watcher/1`, which gates it on
           # `:start_task_router_watcher` (false in test).
           #
           # Node context — ETS-backed space tracking for node canvas commands
           Platform.Federation.NodeContext,
           # Federation runtime presence tracker — before Endpoint so channels can use it
           Platform.Federation.RuntimePresence,
           # Dead-letter replay drain (task 019fa56b-ca2d stage 3). Immediately
           # AFTER RuntimePresence and for a structural reason: every delivery
           # re-checks presence, so this must not outlive the process it reads.
           Platform.Federation.DeadLetterReplay,
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
           # Push-to-talk press windows (task 01a03f4e stage 1) — owns
           # the :meeting_press_windows table. Pure ETS lifecycle owner,
           # no PubSub and no DB, so its position here is only about
           # existing before the first meeting can open a window.
           Platform.Meetings.PressWindow,
           # In-flight `meeting_say` utterances (task 01a06672 stage 1) —
           # owns the :meeting_say_registry table. Same shape as PressWindow:
           # ETS lifecycle owner plus a ttl sweep, no PubSub and no DB.
           Platform.Meetings.SayRegistry,
           # Short-TTL cache in front of `Meetings.resolve_voice_target/1`
           # (task 01a06e07 stage 2) — owns the :meeting_voice_seat_cache
           # table. Bounds the "no voice worker in this room" delay-reason
           # cause, which is a DB read plus a presence read, against a
           # per-agent-per-second render tick. No sweep: bounded by agent
           # count, not by ticks. Needs Repo (its cache-miss path calls
           # `resolve_voice_target/1`) and RuntimePresence, both already
           # started above.
           Platform.Meetings.VoiceSeatCache,
           # Per-MEETING intent queues (task 019f70b8 stage 2) — one
           # on-demand GenServer per meeting, each owning an unnamed
           # ETS table that dies with it. No sweeper: cleanup is
           # structural. Needs the Meetings Registry (above) and PubSub.
           #
           # Replaced the single global `Platform.Meetings.IntentQueue`
           # (task 019f2452) and its named `:meeting_intent_queue`
           # table + 30-minute sweep, deleted in task 019f70b8 stage 3.
           Platform.Meetings.IntentQueue.Supervisor,
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
      |> maybe_add_task_router_watcher()
      |> maybe_add_attention_router()
      |> maybe_add_node_client()
      |> maybe_add_responsibilities_registry()
      |> maybe_add_responsibility_router()
      |> maybe_add_cutover_monitor()
      |> maybe_add_system_event_scheduler()
      |> maybe_add_wiki_indexer()
      |> maybe_add_meeting_historian_handler()
      |> maybe_add_meeting_notifier()
      |> maybe_add_meetings_sender_seed()
      |> maybe_add_meeting_intent_classifier()
      |> maybe_add_meeting_intent_dispatcher()
      |> maybe_add_stall_registry()
      |> maybe_add_lifecycle_step_registry()
      |> maybe_add_summarizer_sweeper()
      |> maybe_add_candidate_sweeper()
      |> maybe_add_security_sweeper()
      |> maybe_add_space_purger()
      |> maybe_add_container_purger()
      |> maybe_add_file_purger()
      |> maybe_add_catalog_emitter()
      |> maybe_add_deploy_merge_reconciler()
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

  # TaskRouterWatcher (task 019fb978 stage 2) — the declarative router
  # watcher. Subscribes to `tasks:board` at `init/1` and runs Repo queries
  # from its own process on every `{:task_created | :task_updated, task}` and
  # `{:runtime_reconnected, runtime_id}` broadcast.
  #
  # MUST run FIRST in the pipeline, before `maybe_add_attention_router/1`,
  # which uses this child as its insertion anchor: putting the watcher back
  # into the list here keeps that anchor resolving exactly as it did when the
  # watcher was listed inline.
  #
  # Disabled in test env; the five files that need a live watcher start their
  # own per-case instance and `Sandbox.allow/3` it themselves. See
  # `config/test.exs` for the measurement that motivated the gate.
  defp maybe_add_task_router_watcher(children) do
    if Application.get_env(:platform, :start_task_router_watcher, true) do
      idx =
        Enum.find_index(children, &(&1 == Platform.Federation.NodeContext)) || length(children)

      List.insert_at(children, idx, Platform.Orchestration.TaskRouterWatcher)
    else
      children
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

  # Meetings sender agent seed (task 019fb955 stage 2). Modelled on
  # `maybe_add_node_client/1` above, but gated on
  # `Platform.Meetings.Config.enabled?/0` rather than reading
  # `MEETINGS_ENABLED` a second time — the flag is read in exactly one
  # place so the injected-config short-circuit works everywhere.
  #
  # A one-shot `Task`, not a GenServer: it inserts a row and exits.
  # `restart: :transient` so a transient DB hiccup at boot retries but a
  # normal exit does not. Appended, so it runs after `Platform.Repo`.
  #
  # This seeds; it never un-seeds. See `Platform.Meetings.SenderSeed`.
  defp maybe_add_meetings_sender_seed(children) do
    if Platform.Meetings.Config.enabled?() do
      children ++
        [
          Supervisor.child_spec({Task, fn -> Platform.Meetings.SenderSeed.ensure!() end},
            id: :meetings_sender_seed,
            restart: :transient
          )
        ]
    else
      children
    end
  end

  # SpacePurger (task 019e95ea stage 3): daily hard-delete of channels
  # whose scheduled deletion passed the retention window. Needs Repo.
  # Disabled in config/test.exs — tests call `sweep/0` directly inside
  # the DataCase sandbox.
  defp maybe_add_space_purger(children) do
    if Application.get_env(:platform, :start_space_purger, true) do
      idx = Enum.find_index(children, &(&1 == PlatformWeb.Endpoint)) || length(children)
      List.insert_at(children, idx, Platform.Chat.SpacePurger)
    else
      children
    end
  end

  # ContainerPurger (task 019f4eaa stage 4): daily hard-delete of projects
  # and cascade-hidden chat_spaces whose container's scheduled deletion
  # passed the retention window. NEVER deletes org rows. Needs Repo.
  # Disabled in config/test.exs — tests call `sweep/0` directly inside the
  # DataCase sandbox.
  defp maybe_add_container_purger(children) do
    if Application.get_env(:platform, :start_container_purger, true) do
      idx = Enum.find_index(children, &(&1 == PlatformWeb.Endpoint)) || length(children)
      List.insert_at(children, idx, Platform.Tenancy.ContainerPurger)
    else
      children
    end
  end

  # FilePurger (task 019f7cb0 stage 3): daily hard-delete of soft-deleted
  # files whose 30-day restore window elapsed — stored bytes + row (chunk
  # and extracted-text rows cascade at the DB level). Needs Repo. Disabled
  # in config/test.exs — tests call `sweep/1` directly inside the DataCase
  # sandbox.
  defp maybe_add_file_purger(children) do
    if Application.get_env(:platform, :start_file_purger, true) do
      idx = Enum.find_index(children, &(&1 == PlatformWeb.Endpoint)) || length(children)
      List.insert_at(children, idx, Platform.Files.Purger)
    else
      children
    end
  end

  # CatalogEmitter (task 01a0008c stage 3): attaches to
  # `[:platform, :files, :ingested, :stop]` in its own `init/1` and is the
  # single process that runs card passes, which is how the burst bound is
  # enforced (see its moduledoc). Disabled in test — an ingest inside the
  # Ecto sandbox would otherwise hand DB work to a process that does not
  # own the connection; tests start their own instance.
  defp maybe_add_catalog_emitter(children) do
    if Application.get_env(:platform, :start_catalog_emitter, true) do
      idx = Enum.find_index(children, &(&1 == PlatformWeb.Endpoint)) || length(children)
      List.insert_at(children, idx, Platform.Files.CatalogEmitter)
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
  # the per-meeting IntentQueue supervisor so the enqueue path has
  # somewhere to start a queue. Disabled in test env; tests start
  # their own instance per case for DataCase sandbox ownership.
  defp maybe_add_meeting_intent_classifier(children) do
    if Application.get_env(:platform, :start_meeting_intent_classifier, true) do
      idx = Enum.find_index(children, &(&1 == PlatformWeb.Endpoint)) || length(children)
      List.insert_at(children, idx, Platform.Meetings.IntentClassifier)
    else
      children
    end
  end

  # IntentDispatcher (task 019f2452 stage 4): global GenServer that
  # drains the IntentQueue and hands each classified intent off to the
  # agent currently assigned to `target_role`. Inserted AFTER the
  # classifier in the child pipeline so the conceptual boot order —
  # `intent_queue -> classifier -> dispatcher` — matches the runtime
  # flow. Disabled in test env; tests start per-case instances for
  # DataCase sandbox ownership.
  defp maybe_add_meeting_intent_dispatcher(children) do
    if Application.get_env(:platform, :start_meeting_intent_dispatcher, true) do
      idx = Enum.find_index(children, &(&1 == PlatformWeb.Endpoint)) || length(children)
      List.insert_at(children, idx, Platform.Meetings.IntentDispatcher)
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

  # CandidateSweeper (task 01a03fba stage 3): the server-side countdown.
  # Every second it claims the `meeting_candidates` rows whose `acts_at`
  # has passed and graduates them. Must start after Repo (it is entirely
  # a Repo query) and after Chat/Tasks are reachable, since firing mints
  # a task or a canvas. Disabled in test env; tests start their own
  # per-case instance or call `sweep/1` directly, so no ambient sweeper
  # races the DataCase sandbox.
  defp maybe_add_candidate_sweeper(children) do
    if Application.get_env(:platform, :start_candidate_sweeper, true) do
      idx = Enum.find_index(children, &(&1 == PlatformWeb.Endpoint)) || length(children)
      List.insert_at(children, idx, Platform.Meetings.CandidateSweeper)
    else
      children
    end
  end

  # DeployMergeReconciler (task 019fa63a stage 6): five-minute poll of the
  # repositories that have no webhook installed, so their per-repo
  # `pr_merged` gate can be passed on an observed merge instead of hanging
  # forever waiting for a delivery that can never arrive. Needs Repo.
  #
  # Sibling of `Platform.Chat.AttachmentReaper` in shape, but registered
  # here through the conditional pipeline rather than inline in the static
  # child list: the reaper runs in the test environment harmlessly, whereas
  # this one would shell out to `gh` from a process outside the Ecto sandbox.
  # Disabled in config/test.exs — tests call `sweep/1` directly with a stub
  # runner, which is also the only shape in which its behaviour is
  # observable.
  defp maybe_add_deploy_merge_reconciler(children) do
    if Application.get_env(:platform, :start_deploy_merge_reconciler, true) do
      idx = Enum.find_index(children, &(&1 == PlatformWeb.Endpoint)) || length(children)
      List.insert_at(children, idx, Platform.Tasks.DeployMergeReconciler)
    else
      children
    end
  end

  # Security Sweeper (task 019f3e8e-4406 stage 2, ADR-0043): periodic
  # sweep over the four `security.*` responsibility keys. Must start
  # after Repo (queries the responsibilities table for the row +
  # cadence metadata) and after `Platform.TaskSupervisor` (it spawns
  # scanner bodies under it as `async_nolink/2` tasks for crash
  # isolation). Insert before `PlatformWeb.Endpoint` and after
  # `Platform.Responsibilities.StallRegistry` so registry lookups
  # work at boot. Disabled in test env; tests start per-case
  # instances with their own `:name`, shortened intervals, and
  # `respect_cadence: false`.
  defp maybe_add_security_sweeper(children) do
    if Application.get_env(:platform, :start_security_sweeper, true) do
      idx = Enum.find_index(children, &(&1 == PlatformWeb.Endpoint)) || length(children)
      List.insert_at(children, idx, Platform.Security.Sweeper)
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

  # Lifecycle StepRegistry (task 019fe1b6 stage 1, ADR-0046): pure
  # in-memory map of declared hook steps, seeded from its own
  # `@built_in_steps` attribute in `init/1`. Deliberately NO companion
  # registration call here — the built-ins list is the single source of
  # truth, and a second registration site would be free to drift from
  # it. Boot only starts the process. Disabled in test env; tests start
  # their own per-case instance with a `:name`.
  defp maybe_add_lifecycle_step_registry(children) do
    if Application.get_env(:platform, :start_lifecycle_step_registry, true) do
      idx = Enum.find_index(children, &(&1 == PlatformWeb.Endpoint)) || length(children)
      List.insert_at(children, idx, Platform.Lifecycle.StepRegistry)
    else
      children
    end
  end

  # Wire the summarizer's own sweep body into StallRegistry after the
  # supervision tree comes up. Idempotent (MapSet-backed) so accidental
  # re-application on a hot reload is harmless. Guarded on both flags
  # so it's a no-op in test env, where per-case sweepers drive
  # `sweep_now/1` directly.
  #
  # The IntentDispatcher's own `sweep_stalled/0` callback (task 019f2452
  # stage 4) is registered here too — same pattern, same idempotence
  # guarantee. Gated on `:start_meeting_intent_dispatcher` so a test
  # env with the dispatcher off doesn't leave a callback pointing at a
  # process that isn't running. The registry itself must be up for the
  # `register/1` call to land, so `:start_stall_registry` gates both.
  defp maybe_register_default_sweep_callback do
    start_sweeper? = Application.get_env(:platform, :start_summarizer_sweeper, true)
    start_registry? = Application.get_env(:platform, :start_stall_registry, true)
    start_dispatcher? = Application.get_env(:platform, :start_meeting_intent_dispatcher, true)

    if start_sweeper? and start_registry? do
      Platform.Responsibilities.StallRegistry.register(
        {Platform.Meetings.SummarizerSweeper, :sweep_meetings_summarize}
      )
    end

    if start_dispatcher? and start_registry? do
      Platform.Responsibilities.StallRegistry.register(
        {Platform.Meetings.IntentDispatcher, :sweep_stalled}
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
