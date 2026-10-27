defmodule Platform.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Recent-log tail for the admin_logs tool (task 01a17b10 stage 3).
    Platform.Admin.LogTail.install()

    Platform.Config.validate!()

    # The terminal relay's refusal-audit window (task 01a17b17). An ETS table
    # owned by this start process; no DB.
    Platform.Terminal.init_refusals()

    # Task 01a08b49 stage 1 — FIRST, ahead of the seven handlers below.
    # `:telemetry` detaches a handler that raises OR exits, VM-wide and for
    # the rest of the run; this listens on `[:telemetry, :handler, :failure]`
    # and re-attaches the casualty before `:telemetry.execute/3` returns to
    # the emitter. Going first is a window argument, not an ordering one:
    # `:telemetry` only orders handlers within one event name and none of the
    # seven subscribe to the failure event, so this cannot be about dispatch
    # order. It is so that no handler is ever attached-and-unguarded, not even
    # for the microseconds between these lines. See the moduledoc for what
    # this does NOT do — it does not save the failed write.
    Platform.Telemetry.HandlerGuardian.attach()
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

    # ADR 0055: refuse to boot when a build-time module reuses a name core
    # (or another module) already owns, rather than letting one silently
    # shadow the other. Raises naming both owners.
    Platform.Extensions.validate!()

    role = Platform.Role.role()

    # Task 01a155a6 stage 3: a web node forwards the telemetry its full peer's
    # background consumers read (AttentionRouter, ContextPlane, ...), because
    # `:telemetry` does not cross nodes. Web only; the full node is the
    # receiver. See Platform.Role.Relay.
    if role == :web, do: Platform.Role.Relay.attach()

    children = children(role, &boot_flag/3)

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
    # running. Full role only: under :web StallRegistry never starts, and
    # registering with it would crash boot (task 01a155a6).
    if role == :full, do: maybe_register_default_sweep_callback()

    result
  end

  @doc """
  The supervision tree's children for `role` (task 01a155a6). `start/2` calls
  it with `boot_flag/3`; a test calls it with its own `flag` to see every
  child a gate can add. `flag` has `Application.get_env/3`'s shape:
  `flag.(app, key, default)` returns the gate's value.

  Under `:full` this is today's list in today's order. Under `:web` it is
  that list filtered to `Platform.Role.web_ids/0` by child id; see
  `Platform.Role` for the classification rule.
  """
  @spec children(Platform.Role.t(), (atom(), atom(), term() -> term())) :: [
          Supervisor.child_spec() | module() | {module(), term()}
        ]
  def children(role, flag) do
    (maybe_chat_storage_boot_check(flag) ++
       List.flatten([
         Platform.Vault.Encryption,
         Platform.Repo,
         PlatformWeb.Telemetry,
         {DNSCluster, query: Application.get_env(:platform, :dns_cluster_query) || :ignore},
         {Phoenix.PubSub, name: Platform.PubSub},
         # Re-executes telemetry a clustered web peer relays, as
         # `[:platform, :role_relay | event]` (task 01a155a6 stage 3). Background:
         # only the full role starts it. See Platform.Role.Relay.
         Platform.Role.RelayReceiver,
         {Registry, keys: :unique, name: Platform.Agents.Registry},
         {Registry, keys: :duplicate, name: Platform.Terminal.Registry},
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
         # No build-time module's processes start here: each module's own
         # Application starts them, AFTER the Endpoint, and every extension
         # callback tolerates them being absent. See
         # 0055-extension-contract-and-build-time-modules.md § 3. Supervision is the module's own
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
         # Peer-envelope replay cache (task 01a0d90f stage 3, ADR 0054) —
         # owns the :federation_peer_nonces table. Pure ETS lifecycle
         # owner (PressWindow shape), no DB and no PubSub; it must exist
         # before the Endpoint accepts the first inbox POST.
         Platform.Federation.Peers.NonceCache,
         # Per-peer outbound connections (task 01a0d90f stage 4, ADR 0054
         # section 4). The Registry names each peer's connection
         # `{:peer, id}` and its wrapper `{:peer_sup, id}`; it must start
         # before the Supervisor whose children register in it.
         {Registry, keys: :unique, name: Platform.Federation.Peers.Registry},
         # The burrow-cli hosts joined on `runtime_host:<id>`, one entry per
         # joined channel process (RuntimeHostChannel); see RuntimeHosts.
         {Registry, keys: :duplicate, name: Platform.Federation.RuntimeHostRegistry},
         # One wrapper Supervisor per peer under this DynamicSupervisor, so
         # a crash-looping peer exhausts only its own restart budget.
         Platform.Federation.Peers.Supervisor,
         # Starts a connection per active peer at boot and re-scans every
         # 60 s. Returns :ignore (starts nothing) when federation is off.
         # After Repo (it lists peers) and after the Supervisor it fills.
         Platform.Federation.Peers.Boot,
         # Task supervisor for parallel agent dispatch (ADR 0027)
         {Task.Supervisor, name: Platform.TaskSupervisor},
         # Code mode (task 01a114a8 stage 2): burrow_run's concurrency slots
         # and its ephemeral ETS store (NonceCache shape). No DB, no
         # PubSub; both must exist before the Endpoint takes a tools/call.
         Platform.CodeMode.Slots,
         # Canvas handlers' own slot pool (task 01a1316b-aab0 stage 1):
         # the same module under a second name, so a busy canvas can never
         # take an agent's burrow_run slot or the reverse.
         Supervisor.child_spec(
           {Platform.CodeMode.Slots, name: Platform.Canvas.ScriptEngine.Slots},
           id: Platform.Canvas.ScriptEngine.Slots
         ),
         Platform.CodeMode.Store,
         # Push relay rate-limit counters (task 01a1261e stage 2). Pure ETS
         # lifecycle owner (NonceCache shape); must exist before the
         # Endpoint takes a relay POST. Idle on installs not in relay mode.
         Platform.Push.RelayRateLimit,
         # Dedicated HTTP/2 pool for APNs (task 01a10882 stage 2). Apple
         # requires HTTP/2 and multiplexes every push for one provider
         # over a connection, so the pool is its own and HTTP/2 only.
         {Finch,
          name: Platform.Push.APNs.finch_name(),
          pools: %{default: [protocols: [:http2], count: 1]}},
         # Context plane — shared ETS context for federation (after Repo, before AttentionRouter)
         Platform.Chat.ContextPlane,
         # On-demand agent-message context summaries (task 01a0d8de) —
         # owns the :chat_context_summary_cache ETS table. No Repo, no
         # PubSub: a lifecycle owner only, lost on restart by design.
         Platform.Chat.ContextSummaryCache,
         # Reply-failure notice dedupe (task 01a10322 stage 1) — owns the
         # :chat_reply_failure_notices table. ETS lifecycle owner only
         # (NonceCache shape); lost on restart by design.
         Platform.Chat.ReplyFailure.Dedupe,
         # No-reply watchdog for native agents (task 01a10322 stage 7) —
         # timers only; its verdicts run under Platform.TaskSupervisor.
         # Off in the test env (`:native_reply_watchdog_ms` false).
         Platform.Chat.ReplyFailure.Watchdog,
         # Native agents' observed state and the agent host's command
         # channel (task 01a10322 stage 2). ETS, rebuilt from the host's
         # inventory on every join.
         Platform.AgentHost.Reconciler,
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
         # Per-agent ask-floor ownership (task 01a0cf5c stage 1) — owns
         # the :meeting_ask_floor table. Same shape as PressWindow: pure
         # ETS lifecycle owner plus a stuck-claim timer, reusing
         # PressWindow.max_hold_ms/0 rather than a second constant.
         # Must start after PressWindow (reads its max_hold_ms/0, a
         # module-attribute read with no runtime process dependency,
         # but ordering keeps the two press-adjacent modules visibly
         # paired here) and after PubSub (its stuck-claim timeout can
         # broadcast on a room topic).
         Platform.Meetings.AskFloor,
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
         # Self-declared agent activity (task 01a07400 stage 1) — owns
         # the :meeting_agent_pushed_state table and its ttl sweep. Same
         # ETS-lifecycle-owner shape as the three above; no PubSub and no
         # DB, so its position here is only about existing before a
         # federated runtime can push a state. It is a SEPARATE module
         # from the `%AgentActivity{}` value it stores state for, and a
         # process, deliberately, so that `AgentActivity` itself stays a
         # value module with no `init/1` — see that module's
         # `pushed_table/0` and the store's own moduledoc.
         Platform.Meetings.AgentActivity.Store,
         # Per-ask answer accumulators for the `voice_ask` tools (task
         # 01a17b10 stage 4): a Registry and an empty DynamicSupervisor.
         # Needs PubSub (each accumulator subscribes to a space topic).
         Platform.Meetings.VoiceAsk.Supervisor,
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
       ]))
    |> maybe_add_task_router_watcher(flag)
    |> maybe_add_attention_router(flag)
    |> maybe_add_node_client(flag)
    |> maybe_add_responsibilities_registry(flag)
    |> maybe_add_responsibility_router(flag)
    |> maybe_add_cutover_monitor(flag)
    |> maybe_add_system_event_scheduler(flag)
    |> maybe_add_wiki_indexer(flag)
    |> maybe_add_meeting_historian_handler(flag)
    |> maybe_add_meeting_notifier(flag)
    |> maybe_add_meetings_sender_seed(flag)
    |> maybe_add_mail_inbound(flag)
    |> maybe_add_mail_outbox(flag)
    |> maybe_add_meeting_intent_classifier(flag)
    |> maybe_add_meeting_intent_dispatcher(flag)
    |> maybe_add_stall_registry(flag)
    |> maybe_add_lifecycle_step_registry(flag)
    |> maybe_add_summarizer_sweeper(flag)
    |> maybe_add_candidate_sweeper(flag)
    |> maybe_add_security_sweeper(flag)
    |> maybe_add_space_purger(flag)
    |> maybe_add_experiments_mail_subscriber(flag)
    |> maybe_add_container_purger(flag)
    |> maybe_add_file_purger(flag)
    |> maybe_add_prototype_purger(flag)
    |> maybe_add_insight_purger(flag)
    |> maybe_add_insight_disseminator(flag)
    |> maybe_add_catalog_emitter(flag)
    |> maybe_add_deploy_merge_reconciler(flag)
    |> maybe_add_canvas_search_backfill(flag)
    |> maybe_add_burrow_docs_seed(flag)
    |> maybe_add_default_space_seed(flag)
    |> maybe_add_burrow_seed(flag)
    |> ensure_task_router_watcher_after_endpoint()
    |> maybe_add_web_boot_gate(role)
    |> maybe_add_web_peer_link(role)
    |> Platform.Role.select(role, Platform.Role.web_ids())
  end

  # The web role's boot gate (task 01a155a6 stage 2): directly after
  # Vault.Encryption and Repo, which it reads, and before everything that
  # serves. Under :full there is no gate; the full role migrates in the
  # entrypoint and `Platform.Release.migrate/0`.
  defp maybe_add_web_boot_gate(children, :web) do
    {head, tail} = Enum.split_while(children, &(&1 != Platform.Repo))
    head ++ [hd(tail), Platform.Role.BootGate | tl(tail)]
  end

  defp maybe_add_web_boot_gate(children, :full), do: children

  # The web role's link to its full peer (task 01a155a6 stage 3): directly
  # after PubSub, whose PG2 groups span the cluster once the nodes connect,
  # and before anything serves. Under :full there is no link; a full node is
  # the peer, and DNSCluster stays its own background decision.
  defp maybe_add_web_peer_link(children, :web) do
    {head, tail} =
      Enum.split_while(children, &(Platform.Role.child_id(&1) != Phoenix.PubSub.Supervisor))

    head ++ [hd(tail), Platform.Role.PeerLink | tl(tail)]
  end

  defp maybe_add_web_peer_link(children, :full), do: children

  @doc """
  The gate reader `start/2` passes to `children/2`. Every gate is an
  `Application.get_env/3` read except four, which keep their existing
  sources so `:full` boots exactly as before: `:attachment_storage_boot_check`
  is the negation of `:skip_attachment_storage_check`, `:meetings_enabled`
  and `:mail_enabled` go through their modules' `enabled?/0`, and
  `:node_client_enabled` is `OPENCLAW_NODE_ENABLED == "true"`.
  """
  @spec boot_flag(atom(), atom(), term()) :: term()
  def boot_flag(:platform, :attachment_storage_boot_check, _default),
    do: not Application.get_env(:platform, :skip_attachment_storage_check, false)

  def boot_flag(:platform, :meetings_enabled, _default), do: Platform.Meetings.Config.enabled?()
  def boot_flag(:platform, :mail_enabled, _default), do: Platform.Mail.Config.enabled?()

  def boot_flag(:platform, :node_client_enabled, _default),
    do: System.get_env("OPENCLAW_NODE_ENABLED") == "true"

  def boot_flag(app, key, default), do: Application.get_env(app, key, default)

  # Fail-closed: run unless explicitly skipped (dev/test). Prevents the
  # durability check from being silently bypassed in staging or any other
  # non-:prod-but-still-real environment.
  defp maybe_chat_storage_boot_check(flag) do
    if flag.(:platform, :attachment_storage_boot_check, true) do
      [Platform.Chat.AttachmentStorage.BootCheck]
    else
      []
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
  defp maybe_add_task_router_watcher(children, flag) do
    if flag.(:platform, :start_task_router_watcher, true) do
      idx =
        Enum.find_index(children, &(&1 == Platform.Federation.NodeContext)) || length(children)

      List.insert_at(children, idx, Platform.Orchestration.TaskRouterWatcher)
    else
      children
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  defp maybe_add_attention_router(children, flag) do
    if flag.(:platform, :start_attention_router, true) do
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

  defp maybe_add_node_client(children, flag) do
    if flag.(:platform, :node_client_enabled, false) do
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
  defp maybe_add_meetings_sender_seed(children, flag) do
    if flag.(:platform, :meetings_enabled, false) do
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

  # Email IMAP pollers (task 01a0cf21 stage 3). Mirrors
  # `maybe_add_meetings_sender_seed/1`: gated on `Platform.Mail.Config.enabled?/0`,
  # the one place the flag is read. Off → no supervisor, no poller, no IMAP
  # connection. Appended, so it starts after `Platform.Repo`. Public (and
  # `@doc false`) so a test can assert the flag-off child list directly.
  @doc false
  def maybe_add_mail_inbound(children, flag) do
    if flag.(:platform, :mail_enabled, false) do
      children ++ [Platform.Mail.Inbound.Supervisor]
    else
      children
    end
  end

  # Email outbox (task 01a0cf21 stage 6): hands `queued` deliveries — the
  # email deploy strategy's, recorded inside the plan engine's transaction —
  # to SMTP after commit. Same gate and shape as `maybe_add_mail_inbound/1`.
  @doc false
  def maybe_add_mail_outbox(children, flag) do
    if flag.(:platform, :mail_enabled, false) do
      children ++ [Platform.Mail.Outbox]
    else
      children
    end
  end

  # Canvas body search backfill (task 01a07402 stage 3). Modelled on
  # `maybe_add_meetings_sender_seed/1` above: a one-shot `Task`, appended so
  # it runs after `Platform.Repo`, `restart: :transient` so a normal exit
  # does not restart it.
  #
  # The entry point is `run_at_boot/0`, NOT `run/1`, and that difference is
  # load-bearing. `:transient` restarts on *abnormal* exit, so a backfill
  # that raised on production data would be restarted, raise again, and trip
  # this supervisor's max-restart intensity — taking the whole application
  # down over an unindexed canvas. `run_at_boot/0` catches everything and
  # returns `:ok`, so this child either finishes or logs and exits normally;
  # it can never crash-loop the tree. Per-row failures never get that far —
  # `run/1` skips them and reports them in `:remaining`.
  #
  # Disabled in config/test.exs — tests call `run/1` directly inside the
  # DataCase sandbox, the way the purgers' tests call `sweep/0`.
  defp maybe_add_canvas_search_backfill(children, flag) do
    if flag.(:platform, :start_canvas_search_backfill, true) do
      children ++
        [
          Supervisor.child_spec(
            {Task, fn -> Platform.Chat.CanvasSearchBackfill.run_at_boot() end},
            id: :canvas_search_backfill,
            restart: :transient
          )
        ]
    else
      children
    end
  end

  # Burrow Docs seed (task 01a10a44 stage 1). Modelled on
  # `maybe_add_canvas_search_backfill/1` above: a one-shot `Task`, appended so
  # it runs after `Platform.Repo`, `restart: :transient` so a normal exit
  # does not restart it. It runs on EVERY boot, not only the first: the docs
  # are product-owned, so each release must converge the `burrow/page/*` rows
  # onto the corpus it was built with.
  #
  # The entry point is `run_at_boot/0`, NOT `sync/0`, and that difference is
  # load-bearing. `:transient` restarts on *abnormal* exit, so a sync that
  # raised on production data would be restarted, raise again, and trip
  # this supervisor's max-restart intensity — taking the whole application
  # down over a docs page. `run_at_boot/0` catches everything and returns
  # `:ok`, so this child either finishes or logs and exits normally; it can
  # never crash-loop the tree. Per-row failures never get that far — `sync/0`
  # collects them in `:failed`.
  #
  # Disabled in config/test.exs — tests call `sync/0` directly inside the
  # DataCase sandbox.
  # A fresh install's "#general" (task 01a10322 stage 6): a release booted on
  # an empty database had zero spaces. Same shape as the seeds above: a
  # one-shot `Task`, `restart: :transient`, entry point `run_at_boot/0`, which
  # never raises. It creates the channel only when the install has none.
  # Disabled in config/test.exs; tests call `DefaultSpace.ensure/0`.
  defp maybe_add_default_space_seed(children, flag) do
    if flag.(:platform, :start_default_space_seed, true) do
      children ++
        [
          Supervisor.child_spec(
            {Task, fn -> Platform.Chat.DefaultSpace.run_at_boot() end},
            id: :default_space_seed,
            restart: :transient
          )
        ]
    else
      children
    end
  end

  # Burrow, the install's own native agent (task 01a17b10 stage 3): installs
  # that already have users never insert a new one, so the login hook alone
  # would never create Burrow there. Same shape as the seeds above: a one-shot
  # `Task`, `restart: :transient`, entry point `run_at_boot/0`, which never
  # raises. A no-op without AGENT_HOST_TOKEN or a root admin. Disabled in
  # config/test.exs; tests call `Burrow.ensure/1`.
  defp maybe_add_burrow_seed(children, flag) do
    if flag.(:platform, :start_burrow_seed, true) do
      children ++
        [
          Supervisor.child_spec(
            {Task, fn -> Platform.Agents.Burrow.run_at_boot() end},
            id: :burrow_seed,
            restart: :transient
          )
        ]
    else
      children
    end
  end

  defp maybe_add_burrow_docs_seed(children, flag) do
    if flag.(:platform, :start_burrow_docs_seed, true) do
      children ++
        [
          Supervisor.child_spec(
            {Task, fn -> Platform.Org.BurrowDocs.run_at_boot() end},
            id: :burrow_docs_seed,
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
  defp maybe_add_space_purger(children, flag) do
    if flag.(:platform, :start_space_purger, true) do
      idx = Enum.find_index(children, &(&1 == PlatformWeb.Endpoint)) || length(children)
      List.insert_at(children, idx, Platform.Chat.SpacePurger)
    else
      children
    end
  end

  # Experiments MailSubscriber (task 01a0d415 stage 3): turns Mail.Inbound's
  # ID-only ingest event into labelled experiment signals, reconciling missed
  # rows on start. Needs Repo, PubSub and Platform.TaskSupervisor, so it goes
  # ahead of the Endpoint like the SpacePurger. Disabled in config/test.exs —
  # a DB-touching subscriber would otherwise fire on every mail test outside
  # the sandbox; its tests start it with start_supervised/1.
  defp maybe_add_experiments_mail_subscriber(children, flag) do
    if flag.(:platform, :start_experiments_mail_subscriber, true) do
      idx = Enum.find_index(children, &(&1 == PlatformWeb.Endpoint)) || length(children)
      List.insert_at(children, idx, Platform.Experiments.Signals.MailSubscriber)
    else
      children
    end
  end

  # ContainerPurger (task 019f4eaa stage 4): daily hard-delete of projects
  # and cascade-hidden chat_spaces whose container's scheduled deletion
  # passed the retention window. NEVER deletes org rows. Needs Repo.
  # Disabled in config/test.exs — tests call `sweep/0` directly inside the
  # DataCase sandbox.
  defp maybe_add_container_purger(children, flag) do
    if flag.(:platform, :start_container_purger, true) do
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
  defp maybe_add_file_purger(children, flag) do
    if flag.(:platform, :start_file_purger, true) do
      idx = Enum.find_index(children, &(&1 == PlatformWeb.Endpoint)) || length(children)
      List.insert_at(children, idx, Platform.Files.Purger)
    else
      children
    end
  end

  # PrototypePurger (task 01a1316b-4e46 stage 1): daily retention for
  # prototype versions (never a prototype's latest). Needs Repo. Disabled in
  # config/test.exs — tests call `sweep/1` directly inside the sandbox.
  defp maybe_add_prototype_purger(children, flag) do
    if flag.(:platform, :start_prototype_purger, true) do
      idx = Enum.find_index(children, &(&1 == PlatformWeb.Endpoint)) || length(children)
      List.insert_at(children, idx, Platform.Prototypes.Purger)
    else
      children
    end
  end

  # InsightPurger (task 01a13867 stage 1): hourly hard-delete of every
  # memory_insights row past expires_at, whatever its state. Never touches
  # memory_insight_verdicts. Needs Repo. Disabled in config/test.exs — tests
  # call `sweep/1` directly inside the sandbox.
  defp maybe_add_insight_purger(children, flag) do
    if flag.(:platform, :start_insight_purger, true) do
      idx = Enum.find_index(children, &(&1 == PlatformWeb.Endpoint)) || length(children)
      List.insert_at(children, idx, Platform.Memory.Insights.Purger)
    else
      children
    end
  end

  # InsightDisseminator (task 01a13867 stage 3): daily 07:00 America/Chicago
  # delivery of dreaming insights as a briefing canvas, beside the purger.
  # Needs Repo. Disabled in config/test.exs — tests call `run/1` directly
  # inside the sandbox.
  defp maybe_add_insight_disseminator(children, flag) do
    if flag.(:platform, :start_insight_disseminator, true) do
      idx = Enum.find_index(children, &(&1 == PlatformWeb.Endpoint)) || length(children)
      List.insert_at(children, idx, Platform.Memory.Insights.Disseminator)
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
  defp maybe_add_catalog_emitter(children, flag) do
    if flag.(:platform, :start_catalog_emitter, true) do
      idx = Enum.find_index(children, &(&1 == PlatformWeb.Endpoint)) || length(children)
      List.insert_at(children, idx, Platform.Files.CatalogEmitter)
    else
      children
    end
  end

  defp maybe_add_system_event_scheduler(children, flag) do
    if flag.(:platform, :start_system_event_scheduler, true) do
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
  defp maybe_add_responsibilities_registry(children, flag) do
    if flag.(:platform, :start_responsibilities_registry, true) do
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
  defp maybe_add_responsibility_router(children, flag) do
    if flag.(:platform, :start_responsibility_router, true) do
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
  defp maybe_add_cutover_monitor(children, flag) do
    if flag.(:platform, :start_cutover_monitor, true) do
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
  defp maybe_add_wiki_indexer(children, flag) do
    if flag.(:platform, :start_wiki_indexer, true) do
      insert_at =
        Enum.find_index(children, fn child ->
          child == Platform.Agents.RuntimeSupervisor
        end) || length(children)

      List.insert_at(children, insert_at, Platform.Org.Wiki.Indexer)
    else
      children
    end
  end

  defp maybe_add_meeting_historian_handler(children, flag) do
    if flag.(:platform, :start_meeting_historian_handler, true) do
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
  defp maybe_add_meeting_notifier(children, flag) do
    if flag.(:platform, :start_meeting_notifier, true) do
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
  defp maybe_add_meeting_intent_classifier(children, flag) do
    if flag.(:platform, :start_meeting_intent_classifier, true) do
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
  defp maybe_add_meeting_intent_dispatcher(children, flag) do
    if flag.(:platform, :start_meeting_intent_dispatcher, true) do
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
  defp maybe_add_summarizer_sweeper(children, flag) do
    if flag.(:platform, :start_summarizer_sweeper, true) do
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
  defp maybe_add_candidate_sweeper(children, flag) do
    if flag.(:platform, :start_candidate_sweeper, true) do
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
  defp maybe_add_deploy_merge_reconciler(children, flag) do
    if flag.(:platform, :start_deploy_merge_reconciler, true) do
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
  defp maybe_add_security_sweeper(children, flag) do
    if flag.(:platform, :start_security_sweeper, true) do
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
  defp maybe_add_stall_registry(children, flag) do
    if flag.(:platform, :start_stall_registry, true) do
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
  defp maybe_add_lifecycle_step_registry(children, flag) do
    if flag.(:platform, :start_lifecycle_step_registry, true) do
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
