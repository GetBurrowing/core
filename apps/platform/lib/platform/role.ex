defmodule Platform.Role do
  @moduledoc """
  The boot role of this node (task 01a155a6). `:full` is today's node: it
  serves HTTP and runs every background process. `:web` serves HTTP and
  LiveView only, so a preview instance (burrow-exp) can run a branch against
  the production database without a second TaskRouter, scheduler, sweeper or
  purger acting on prod's rows.

  The role is read from `PLATFORM_ROLE` in `config/runtime.exs` through
  `parse!/1` and `validate!/2`, and stored as `config :platform, :role`.
  Unset or `"full"` is `:full`, `"web"` is `:web`, and anything else raises.
  The web role refuses to boot outside `MIX_ENV=prod`: a dev build compiles
  `/dev/login` (sign in as anyone) and the CSRF-less `/dev/*` routes, and a
  web node is public behind prod's OIDC gate with prod's data.

  ## Classification rule

  Every child `Platform.Application.children/2` can produce is listed by its
  `Supervisor.child_spec/2` id in exactly one of `@web` and `@background`
  (`test/platform/role_test.exs` derives the set from the same function
  `start/2` uses, so a new child that nobody classified fails CI).

  A child is WEB when it is one of:

    * an inert container: a `Registry`, an empty `DynamicSupervisor`, a
      `Task.Supervisor`, a connection pool;
    * an ETS owner whose only timer prunes its own table (a ttl sweep acts
      on node-local memory and nothing else);
    * an ETS owner whose timer is armed only by a request on THIS node and
      acts only on the state that request created (`PressWindow`,
      `AskFloor`). Those are request-path effects: they fire once, on the
      node whose request armed them;
    * something that serves HTTP or LiveView: `Repo`, `Vault.Encryption`,
      `PubSub`, `Presence`, the `Endpoint`, the telemetry poller.

  A child is BACKGROUND when it has a timer or tick that acts beyond its own
  memory (a DB write, a dispatch, a push, a broadcast nobody asked for), does a
  boot-time DB write (seeds, `Responsibilities.Registry` upsert, a backfill),
  subscribes to PubSub or telemetry and then acts, or opens an outbound
  connection on its own. A child whose only purpose is to hold state for a
  background child (`LeaseManager` for the router, `StallRegistry` for the
  sweepers, `Peers.Supervisor` for `Peers.Boot`) goes with it.

  ## The five children the plan left open

    * `Platform.Agents.RuntimeSupervisor`: WEB. An empty `DynamicSupervisor`
      at boot; it starts an `AgentServer` only when a caller asks, and two of
      its callers are request-path LiveViews (`control_center_live.ex`,
      `shell_live.ex`).
    * `Platform.Agents.ContextBroker`: WEB. `init/1` does nothing and it has
      no timer or subscription; it writes `agent_context_shares` only inside
      a caller's `GenServer.call`.
    * `Platform.Context.Supervisor`: WEB. Its one child, `Context.Cache`, is
      an ETS owner with no timer that broadcasts only on a caller's write;
      `tasks.ex` and the task context hydrator read it on the request path.
    * `Platform.Artifacts.Store`: WEB. Two ETS tables, no timer, no DB, no
      PubSub.
    * `Platform.Meetings.IntentQueue.Supervisor`: BACKGROUND. Its children
      own ack-timeout and claim-watchdog timers that write the intent mirror
      and broadcast dispatch state, and `IntentDispatcher` drains only the
      queues registered on its own node. A queue on a web node would be a
      second owner for the meeting that prod's dispatcher never sees.

  `DNSCluster` is BACKGROUND: it connects to Erlang nodes it finds by DNS, and
  whether a web node joins a cluster is a separate, explicit decision, not a
  side effect of `DNS_CLUSTER_QUERY` being set.

  ## The web-only boot gate (stage 2)

  `Platform.Role.BootGate` is in `@web` and also in `@web_only`:
  `children/2` inserts it, directly after `Vault.Encryption` and `Repo`, only
  under `:web`, so it never appears in the full list. It refuses to boot on
  an unapplied migration, a missing `VAULT_MASTER_KEY`, or a key that does not
  decrypt a `vault_credentials` row. See its moduledoc.

  The web role's signing secrets (`SECRET_KEY_BASE`, `ATTACHMENT_SIGNING_KEY`,
  `MEETING_GUEST_SIGNING_KEY`, `MEETING_CALENDAR_SIGNING_KEY`) come from the
  environment because `validate!/2` confines the role to `MIX_ENV=prod`, and
  `config/runtime.exs` reads and requires all four under prod. There is no
  web-specific read: a dev-mode web node never gets that far.

  ## Clustering with the full peer (stage 3)

  A web node joins its full peer over distributed Erlang:
  `Platform.Role.PeerLink` (web only, directly after `Phoenix.PubSub`) reads
  `PLATFORM_CLUSTER_PEER` through `parse_peer!/2` and keeps the connection up.
  `Phoenix.PubSub` and `Platform.Chat.Presence` then span both nodes with no
  further code, and every PubSub-driven background consumer on the full node
  receives the web node's broadcasts exactly once, because the web node runs
  none of them.

  `:telemetry` is node-local, so the consumers that read it
  (`Platform.Role.Relay.consumers/0`) would never see a web node's events.
  Under `:web`, `Platform.Application.start/2` attaches `Platform.Role.Relay`,
  which broadcasts each one; `Platform.Role.RelayReceiver` (background) re-executes
  it on the full node as `[:platform, :role_relay | event]`, and only those
  consumers attach to that twin. The handlers `start/2` attaches on both roles
  (audit, vault, chat, meetings, memory, external admission) attach to the
  original event only, so a write on the web node is audited once, there.

  `Platform.Chat.ActiveAgentStore` stays web (an ETS owner its own request
  path writes), but under `:web` with a peer every write goes to the peer's
  store (`ActiveAgentStore.server/0`). The mutex that decides routing lives
  with `AttentionRouter` on the full node, and a local timer would broadcast
  releases the full node's LiveViews would believe.

  Limitation: while the peer is down, a message posted on the web node is
  stored and shown but never routed to agents. The relay is fire-and-forget
  and nothing replays it.

  ## Side effects: where each one fires (stage 4)

  The rule: an effect fires on the node that consumes its trigger.

    * A REQUEST-PATH effect runs inside the process that served the write
      (a LiveView event, a controller, an MCP tool call). The write happens
      once, on one node, so the effect fires once, there. On a web node that
      means a web node sends it, so it needs prod's VAPID, APNs, LiveKit,
      FILES and MEMORY service credentials.
    * A BACKGROUND effect runs in a background child (`@background`), which
      only the full node starts. The web node's trigger reaches it once:
      PubSub over the cluster, telemetry through `Platform.Role.Relay`, or a
      row the child later reads.
    * A WIRE module is the transport under one of the above, and fires
      wherever its caller runs.

  `effects/0` is the table, one row per file that calls
  `Notifications.fan_out_*` or `Push.send_*` (`:push`), `Mail.Deliverer` or
  `Mail.Mailer` (`:mail`), `Req` or `Finch` (`:http`), or
  `ExternalAgents.Dispatcher.dispatch` (`:agent_dispatch`).
  `test/platform/role/effects_test.exs` greps `lib/` for those calls and
  fails when a file appears that the table does not classify, or the table
  names a file that no longer calls one.

  Classes: `:request`, `:background`, `:both` (one module, one path of
  each kind, named in the note), `:follows_caller` (a client with no
  trigger of its own, fired by whichever path calls it), `:wire`, `:none`
  (no production caller: console or mix only).

  ## Node-local state a web node's request path reads (stage 4)

  A web node runs no background child, and some web children hold state
  only the full node fills (runtimes connect to prod). `node_local/0` lists
  every call from web-reachable code into such state, with how it is
  handled:

    * `:peer`: under `:web` with a cluster peer, read from or call the peer
      through `Platform.Role.Peer` (`:erpc`, 2s timeout). An unreachable
      peer answers the default (offline, no active agent, no lease);
    * `:tolerates`: the call already answers sensibly when the process or
      table is absent, and the effect it would have had reaches the full
      node another way, named in the note;
    * `:full_only`: no web-reachable caller (a background child, a mix task
      or the console calls it);
    * `:pure`: a function on a background module that reads no process
      state, so it is safe anywhere.

  ## Trust: a web node is exactly as trusted as prod

  The two nodes share an Erlang cookie. Anyone who can run code on a web node
  can run arbitrary code on its full peer, which holds prod's superuser
  database connection and every prod secret. A preview branch on exp is
  therefore as trusted as merged main. The DML-only database role a web node
  connects with does not bound this: a branch that wants DDL can call the
  peer's `Repo`. A branch that changes the shape of a broadcast struct can
  also crash the full node's LiveViews that receive it; the migration refusal
  in `Platform.Role.BootGate` bounds that for Ecto schema fields only.

  ## Previewing a rung that carries a migration

  A web node never migrates, and the gate refuses a branch whose migrations
  the database has not applied. A rung that needs schema therefore cannot be
  previewed on exp until its migration is on main and prod has applied it.
  Such a rung ships its expand-only migration (additive: new tables, nullable
  columns, indexes; nothing the running prod code would trip on) as its own
  PR first, and the rung that uses it is previewed after.
  """

  @type t :: :full | :web

  # Ordered as `Platform.Application.children/2` produces them.
  @web [
    Platform.Chat.AttachmentStorage.BootCheck,
    Platform.Vault.Encryption,
    Platform.Repo,
    # Web-only: see @web_only.
    Platform.Role.BootGate,
    PlatformWeb.Telemetry,
    Phoenix.PubSub.Supervisor,
    # Web-only: see @web_only. Joins the full peer so PubSub spans both.
    Platform.Role.PeerLink,
    Platform.Agents.Registry,
    Platform.Execution.Registry,
    Platform.Orchestration.Registry,
    Platform.Chat.Registry,
    Platform.Meetings.Registry,
    Platform.Agents.RuntimeSupervisor,
    Platform.Chat.CanvasSupervisor,
    Platform.Agents.ContextBroker,
    Platform.Context.Supervisor,
    Platform.Artifacts.Store,
    Platform.Federation.NodeContext,
    Platform.Federation.RuntimePresence,
    Platform.Federation.Peers.NonceCache,
    Platform.Federation.Peers.Registry,
    Platform.Federation.RuntimeHostRegistry,
    Platform.TaskSupervisor,
    Platform.CodeMode.Slots,
    Platform.Canvas.ScriptEngine.Slots,
    Platform.CodeMode.Store,
    Platform.Push.RelayRateLimit,
    Platform.Push.APNsFinch,
    Platform.Chat.ContextSummaryCache,
    Platform.Chat.ReplyFailure.Dedupe,
    Platform.Chat.ActiveAgentStore,
    Platform.ExternalAgents.EphemeralCredentials,
    Platform.Chat.Presence,
    Platform.Meetings.State,
    Platform.Meetings.PressWindow,
    Platform.Meetings.AskFloor,
    Platform.Meetings.SayRegistry,
    Platform.Meetings.VoiceSeatCache,
    Platform.Meetings.AgentActivity.Store,
    # Inert: seeded from its own @built_in_steps in init/1, and the task
    # transition request path reads it (lifecycle/executor.ex).
    Platform.Lifecycle.StepRegistry,
    PlatformWeb.Endpoint
  ]

  @background [
    DNSCluster,
    # Subscribes to the relay topic and re-executes telemetry: it acts.
    Platform.Role.RelayReceiver,
    Platform.Org.Wiki.Indexer,
    Platform.Execution.RunSupervisor,
    Platform.Orchestration.LeaseManager,
    Platform.Orchestration.TaskRouterSupervisor,
    Platform.Chat.AttentionRouter,
    Platform.Federation.DeadLetterReplay,
    Platform.Federation.Peers.Supervisor,
    Platform.Federation.Peers.Boot,
    Platform.Chat.ContextPlane,
    Platform.Chat.ReplyFailure.Watchdog,
    Platform.AgentHost.Reconciler,
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
    Platform.Orchestration.TaskRouterWatcher,
    Platform.Federation.NodeClient,
    :meetings_sender_seed,
    Platform.Mail.Inbound.Supervisor,
    Platform.Mail.Outbox,
    :canvas_search_backfill,
    :burrow_docs_seed,
    :default_space_seed
  ]

  # Web children that `Platform.Application.children/2` adds only under :web,
  # so they are absent from the full list by construction.
  @web_only [Platform.Role.BootGate, Platform.Role.PeerLink]

  # The children whose presence on a web node would double-dispatch,
  # double-schedule or double-send against prod. Asserted absent from
  # `Platform.Application.children(:web, all_on)` independently of @web, so
  # adding one of these to @web by mistake is caught twice.
  @never_on_web [
    Platform.Orchestration.TaskRouterWatcher,
    Platform.Orchestration.TaskRouterSupervisor,
    Platform.Chat.AttentionRouter,
    Platform.Agents.SystemEventScheduler,
    Platform.Responsibilities.Router,
    Platform.Mail.Outbox,
    Platform.Memory.Insights.Disseminator
  ]

  # ── stage 4 tables ─────────────────────────────────────────────────────

  @effects [
    # :push. Notifications fan-out and direct Push sends.
    %{
      kind: :push,
      file: "lib/platform/inbox.ex",
      class: :request,
      note:
        "Inbox.emit/1 pushes the push_kinds rows in the writer's process (plan submit, review request)"
    },
    %{
      kind: :push,
      file: "lib/platform/tasks.ex",
      class: :request,
      note: "sponsor assignment on create_task/update_task"
    },
    %{
      kind: :push,
      file: "lib/platform/meetings/ringing.ex",
      class: :request,
      note: "ring and ring-cancel on a call started or answered by a request"
    },
    %{
      kind: :push,
      file: "lib/platform/meetings/invite_delivery.ex",
      class: :request,
      note: "invite on meeting create or invite"
    },
    %{
      kind: :push,
      file: "lib/platform/accounts/external_admission_notifier.ex",
      class: :request,
      note:
        "boot telemetry handler on both roles, attached to the original event only: fires where the login happened"
    },
    %{
      kind: :push,
      file: "lib/platform/meetings/meeting_briefings.ex",
      class: :follows_caller,
      note:
        "meeting briefing push on delivery: end_meeting/1 (the room_finished webhook request), complete_transcript/2 and triage call deliver/1 in their own process; it pushes only on a created Inbox row"
    },
    %{
      kind: :push,
      file: "lib/platform/meetings/meeting_notifier.ex",
      class: :background,
      note: "MeetingNotifier, PubSub consumer, full only"
    },
    %{
      kind: :push,
      file: "lib/platform/chat/attention_router.ex",
      class: :background,
      note:
        "human push on routing; AttentionRouter is full only and reads a web post through the relay twin"
    },
    %{
      kind: :push,
      file: "lib/platform/memory/insights/disseminator.ex",
      class: :both,
      note:
        "tick is background (full only); deliver_now/3 is the request path of an insight action"
    },
    %{
      kind: :push,
      file: "lib/platform/notifications.ex",
      class: :wire,
      note: "the fan-out layer every :push row above calls"
    },
    # :mail.
    %{
      kind: :mail,
      file: "lib/platform/mail/dispatch.ex",
      class: :request,
      note: "dispatch/3: EmailLive 'Send now' and the account test send, in the caller"
    },
    %{
      kind: :mail,
      file: "lib/platform/mail/outbox.ex",
      class: :background,
      note:
        "Mail.Outbox drains queued rows, full only; enqueue/3 on a web node is a row plus a clustered nudge"
    },
    %{
      kind: :mail,
      file: "lib/platform/mail/deliverer.ex",
      class: :wire,
      note: "the one Swoosh call site"
    },
    # :agent_dispatch.
    %{
      kind: :agent_dispatch,
      file: "lib/platform/responsibilities/router.ex",
      class: :both,
      note:
        "chat_pattern, cron and event triggers are background (Router is full only); fire/2 runs in the caller (plan submit, preplan, audit_diff)"
    },
    %{
      kind: :agent_dispatch,
      file: "lib/platform/design/critique.ex",
      class: :request,
      note: "Critique.request/1 from the design critique MCP tool, synchronous in the caller"
    },
    # :http. Req and Finch.
    %{
      kind: :http,
      file: "lib/platform/accounts/user_avatar_cache.ex",
      class: :request,
      note: "read-only avatar GET on render"
    },
    %{
      kind: :http,
      file: "lib/platform/agents/providers/anthropic.ex",
      class: :follows_caller,
      note: "model call; native agent turns run under prod's AttentionRouter dispatch"
    },
    %{
      kind: :http,
      file: "lib/platform/agents/providers/codex.ex",
      class: :follows_caller,
      note: "model call, as anthropic.ex"
    },
    %{
      kind: :http,
      file: "lib/platform/agents/providers/ollama.ex",
      class: :follows_caller,
      note: "model call, as anthropic.ex"
    },
    %{
      kind: :http,
      file: "lib/platform/agents/providers/openai.ex",
      class: :follows_caller,
      note: "model call, as anthropic.ex"
    },
    %{
      kind: :http,
      file: "lib/platform/agents/tool_runner.ex",
      class: :background,
      note: "a native agent's tool fetch, inside its turn on the full node"
    },
    %{
      kind: :http,
      file: "lib/platform/execution/suite_runnerd_client.ex",
      class: :background,
      note: "RunServer under Execution.RunSupervisor, full only"
    },
    %{
      kind: :http,
      file: "lib/platform/external_agents.ex",
      class: :request,
      note: "probe/1, read-only, from the agent admin page"
    },
    %{
      kind: :http,
      file: "lib/platform/external_agents/dispatcher.ex",
      class: :follows_caller,
      note: "the :agent_dispatch rows above"
    },
    %{
      kind: :http,
      file: "lib/platform/federation/peers/client.ex",
      class: :follows_caller,
      note: "PeerConnection under Peers.Supervisor (full only), and a request that calls a peer"
    },
    %{
      kind: :http,
      file: "lib/platform/feedback/disposition/broker.ex",
      class: :request,
      note: "feedback disposition through the broker"
    },
    %{
      kind: :http,
      file: "lib/platform/feedback/github_publisher/broker.ex",
      class: :request,
      note: "feedback_submit through the broker"
    },
    %{
      kind: :http,
      file: "lib/platform/feedback/github_publisher/github_app.ex",
      class: :request,
      note: "feedback publish with an App credential"
    },
    %{
      kind: :http,
      file: "lib/platform/files/service_client.ex",
      class: :request,
      note: "files-service extraction on upload; needs FILES credentials on a web node"
    },
    %{
      kind: :http,
      file: "lib/platform/lifecycle/steps/completion_webhook.ex",
      class: :request,
      note:
        "Lifecycle edge on a task transition, in the transition's process; StepRegistry is web"
    },
    %{
      kind: :http,
      file: "lib/platform/meetings.ex",
      class: :request,
      note:
        "LiveKit room and token calls on meeting start and join; needs LiveKit credentials on a web node"
    },
    %{
      kind: :http,
      file: "lib/platform/meetings/open_question_pilot/runner.ex",
      class: :none,
      note: "pilot runner, console only"
    },
    %{
      kind: :http,
      file: "lib/platform/memory/providers/memory_service.ex",
      class: :follows_caller,
      note: "memory search and ingest; needs MEMORY credentials on a web node"
    },
    %{kind: :http, file: "lib/platform/push.ex", class: :wire, note: "web push transport"},
    %{kind: :http, file: "lib/platform/push/apns.ex", class: :wire, note: "APNs transport"},
    %{kind: :http, file: "lib/platform/push/fcm.ex", class: :wire, note: "FCM transport"},
    %{
      kind: :http,
      file: "lib/platform/push/relay.ex",
      class: :wire,
      note: "push relay transport"
    },
    %{
      kind: :http,
      file: "lib/platform/security/scanners/cve_scan/osv_client.ex",
      class: :background,
      note: "Security.Sweeper, full only"
    },
    %{
      kind: :http,
      file: "lib/platform/sign_in_admin/pocket_id.ex",
      class: :request,
      note: "admin Users page against the sign-in provider"
    },
    %{
      kind: :http,
      file: "lib/platform/vault/oauth.ex",
      class: :both,
      note: "OAuth callback is request; token refresh is Vault.RefreshWorker, full only"
    }
  ]

  @node_local [
    %{
      target:
        "Platform.Federation.RuntimePresence: online?/1, status/1, list_online/0, list_all/0",
      handling: :peer,
      note:
        "runtimes connect to prod; read peer and local, merged. Every presence reader in LiveViews and the tool surface"
    },
    %{
      target:
        "Platform.Chat.ActiveAgentStore: get_active/1, get_last_agent/1 (writes via server/0 since stage 3)",
      handling: :peer,
      note: "the mutex lives with prod's AttentionRouter"
    },
    %{
      target: "Platform.Orchestration.LeaseManager: record_ack/3, silence/3, get/1",
      handling: :peer,
      note: "task_ack and alarm_silence MCP tools; leases live with prod's routers"
    },
    %{
      target: "Platform.Orchestration.TaskRouterWatcher.force_dispatch/1",
      handling: :peer,
      note:
        "needs-human release and the in_progress to in_review hook in Platform.Tasks; locally it would start a router under an absent TaskRouterSupervisor"
    },
    %{
      target: "Platform.AgentHost.Reconciler client API, AgentHost.status/1, AgentHost.host/0",
      handling: :peer,
      note: "control center; the agent host connects to prod"
    },
    %{
      target: "Platform.Chat.ContextPlane: get_*/1, build_context_bundle/1, update_agent_state/3",
      handling: :peer,
      note: "MCP tool surface; with no table and no peer, reads answer the empty default"
    },
    %{
      target: "Platform.Chat.ReplyFailure.Watchdog: activity/1, arm/1",
      handling: :tolerates,
      note: "whereis guard; runtime channel and MCP controller. The watch it feeds runs on prod"
    },
    %{
      target: "Platform.Security.sweep_now/0",
      handling: :tolerates,
      note: "answers {:error, :sweeper_not_started}"
    },
    %{
      target: "Platform.Federation.Peers.Boot.peer_activated/2",
      handling: :tolerates,
      note: "whereis guard; prod's Boot starts the connection at its next 60s scan"
    },
    %{
      target: "Platform.Orchestration.TaskRouterSupervisor.stop_assignment/1 from Platform.Tasks",
      handling: :tolerates,
      note:
        "web's Orchestration.Registry is empty, so {:error, :not_found}; prod's watcher stops the router on the board broadcast or as an orphan at its next reconcile"
    },
    %{
      target: "Platform.Federation.DeadLetterReplay.schedule/1",
      handling: :tolerates,
      note:
        "a cast to an unregistered name is a no-op; runtimes reconnect to prod, whose channel schedules it"
    },
    %{
      target: "Platform.Mail.Outbox.nudge/0",
      handling: :tolerates,
      note: "a PubSub broadcast; prod's Outbox receives it over the cluster"
    },
    %{
      target: "Platform.Execution.start_run/2 (Execution.RunSupervisor)",
      handling: :full_only,
      note: "proof-of-life launch, console only"
    },
    %{
      target: "Platform.Responsibilities.StallRegistry.register/2",
      handling: :full_only,
      note: "Application.start/2 under :full and the IntentClassify handler under the Router"
    },
    %{
      target: "Platform.Responsibilities.Registry.stamp_last_successful_fire/2",
      handling: :full_only,
      note: "Responsibilities.Router, background"
    },
    %{
      target:
        "Platform.Responsibilities.CutoverMonitor.report/0, Platform.Tasks.DeployMergeReconciler.live_gate/1",
      handling: :full_only,
      note: "mix tasks"
    },
    %{
      target:
        "Platform.Chat.AttentionRouter: mentioned?/2,3, extract_bracketed_tokens/1, untrusted_inbound?/1",
      handling: :pure,
      note: "Platform.Chat and Responsibilities.Router call them; no process state"
    },
    %{
      target:
        "Platform.Orchestration.TaskRouterWatcher: should_run?/1, active_statuses/0; LeaseManager.stage_kind_timeouts/0",
      handling: :pure,
      note: "Platform.Tasks and the tool surface; no process state"
    },
    %{
      target: "Platform.Meetings.IntentClassifier: decide/1, format_*",
      handling: :pure,
      note: "intent eval harness and pilot; no process state"
    }
  ]

  @doc "Every side-effect call site in lib/, classified. See the moduledoc."
  @spec effects() :: [map()]
  def effects, do: @effects

  @doc "Every node-local read a web node's request path makes, and its handling."
  @spec node_local() :: [map()]
  def node_local, do: @node_local

  @doc "This node's role. Defaults to `:full` when unset."
  @spec role() :: t()
  def role, do: Application.get_env(:platform, :role, :full)

  @doc "True when this node boots the web role."
  @spec web?() :: boolean()
  def web?, do: role() == :web

  @doc "Child ids that start under the web role."
  @spec web_ids() :: [term()]
  def web_ids, do: @web

  @doc "Web child ids that `Platform.Application.children/2` adds only under `:web`."
  @spec web_only_ids() :: [term()]
  def web_only_ids, do: @web_only

  @doc "Child ids that start only under the full role."
  @spec background_ids() :: [term()]
  def background_ids, do: @background

  @doc "Child ids that must never start under the web role."
  @spec never_on_web() :: [term()]
  def never_on_web, do: @never_on_web

  @doc """
  Parse `PLATFORM_ROLE`. `nil`, `""` and `"full"` give `:full`, `"web"` gives
  `:web`, and any other value raises naming it.
  """
  @spec parse!(String.t() | nil) :: t()
  def parse!(nil), do: :full
  def parse!(""), do: :full
  def parse!("full"), do: :full
  def parse!("web"), do: :web

  def parse!(other) do
    raise ArgumentError,
          "PLATFORM_ROLE=#{inspect(other)} is not a role; expected unset, \"full\" or \"web\""
  end

  @doc """
  Parse `PLATFORM_CLUSTER_PEER` for `role`. Unset or `""` gives `nil` (no
  peer). Under `:web` a `name@host` value gives that node name. A value under
  `:full` raises, because a full node is the peer and never dials one, and
  a value without `@` raises naming it.
  """
  @spec parse_peer!(String.t() | nil, t()) :: node() | nil
  def parse_peer!(nil, _role), do: nil
  def parse_peer!("", _role), do: nil

  def parse_peer!(value, :full) do
    raise ArgumentError,
          "PLATFORM_CLUSTER_PEER=#{inspect(value)} is set but PLATFORM_ROLE is not \"web\"; " <>
            "only a web node joins a peer"
  end

  def parse_peer!(value, :web) do
    case String.split(value, "@") do
      [name, host] when name != "" and host != "" ->
        String.to_atom(value)

      _ ->
        raise ArgumentError,
              "PLATFORM_CLUSTER_PEER=#{inspect(value)} is not a node name; expected name@host"
    end
  end

  @doc """
  Refuse a role the build environment cannot run safely. The web role is
  public behind prod's OIDC gate and reads prod's data, so it must run
  `MIX_ENV=prod`: a dev or test build compiles `/dev/login` (sign in as any
  user) and the CSRF-less `/dev/*` routes.
  """
  @spec validate!(t(), atom()) :: :ok
  def validate!(:web, :prod), do: :ok

  def validate!(:web, env) do
    raise ArgumentError,
          "PLATFORM_ROLE=web refuses to boot with MIX_ENV=#{env}: only a prod build " <>
            "is safe to expose, because #{env} compiles /dev/login (sign in as anyone) " <>
            "and the CSRF-less /dev/* routes. Build and run the web node with MIX_ENV=prod."
  end

  def validate!(:full, _env), do: :ok

  @doc """
  Split `children` by `Supervisor.child_spec/2` id into
  `{web, background}`, keeping order. A child is web when its id is in
  `web_ids`. Ids rather than terms, because `{Registry, name: X}` and
  `{Task, fun}` children are only told apart by their ids.
  """
  @spec partition([Supervisor.child_spec() | module() | {module(), term()}], [term()]) ::
          {list(), list()}
  def partition(children, web_ids) do
    Enum.split_with(children, &(child_id(&1) in web_ids))
  end

  @doc """
  The children `role` starts: all of them under `:full`, the web part of
  `partition/2` under `:web`.
  """
  @spec select(list(), t(), [term()]) :: list()
  def select(children, :full, _web_ids), do: children

  def select(children, :web, web_ids) do
    {web, _background} = partition(children, web_ids)
    web
  end

  @doc "The supervisor child id of `child`."
  @spec child_id(Supervisor.child_spec() | module() | {module(), term()}) :: term()
  def child_id(child), do: Supervisor.child_spec(child, []).id
end
