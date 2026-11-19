defmodule Platform.Agents.NativeAgents do
  @moduledoc """
  Native (install-managed) agents: agents whose harness CLI (Claude Code or
  Codex) this install runs itself, under its own supervision, instead of a
  runtime federated in from someone else's machine (task 01a10322).

  ## A row shape, not a code path

  A native agent is an ordinary federated agent row (`runtime_type:
  "external"`, pointing at an activated `agent_runtimes` row) whose runtime is
  marked `managed_by: "install"` with a `harness` and a `desired_state`. That
  is the whole difference. Everything that reads an agent through its runtime
  (`Platform.Orchestration.PhaseRuntime.resolve/1`, `AgentResponder`'s
  external dispatch, `Platform.Agents.Kind.classify/1`, the Access-owned runtime profile and owner cap) treats it exactly as a federated agent,
  because it is one. A native agent therefore gets no `runtime_type` value of
  its own; it is `"external"` like any federated agent. (External HTTP agents
  carry `"http"`, which is a different row shape, not a native-agent variant.)

  ## Tokens

  `create/3` provisions through `Platform.Federation.provision_agent_runtime/3`
  and DISCARDS the raw runtime token it returns. Core stores only the token's
  hash; the supervisor mints a fresh token with
  `Platform.Federation.generate_runtime_token/1` on every start, so no
  plaintext token outlives the call that hands it to the agent.

  ## Who can manage one

  `can_manage?/2` is true for the runtime's owner (`owner_user_id`) and for an
  install admin (`Platform.Tenancy.root_admin?/1`, an admin of the root org).
  Agents carry no org of their own, and an install is one trust group, so the
  root org's admins are the install's admins.

  ## Agent files (stage 5)

  Each native agent's local files (`CLAUDE.md` or `AGENTS.md`,
  `.claude/settings.json`, ...) are `agent_workspace_files` rows, written into
  the agent's own work dir, as the agent's uid, on every start
  (`agent.start` carries `files: start_files/1`).

  EDITING THEM IS ROOT-EQUIVALENT on the install: `.claude/settings.json`
  defines hooks, which run arbitrary commands as the agent, and on
  `full_machine` the agent has sudo. So `save_file/5` refuses anyone
  `can_manage?/2` refuses, and every UI path that writes a managed agent's
  files goes through it. A key must pass `valid_file_key?/1`, the same rule
  the agent host enforces before it writes.
  """

  import Ecto.Query

  require Logger

  alias Platform.Agents.{Agent, AgentRuntime, Manners, MemoryContext, WorkspaceFile}
  alias Platform.Federation
  alias Platform.Repo
  alias Platform.Tenancy

  @managed_by "install"
  @created_event "platform.agents.native_runtime_created"
  @owner_changed_event "platform.federation.runtime_owner_changed"

  # Observed states in which the agent's process is up, so a file saved now
  # is not what it is running.
  @live_states [:running, :starting, :needs_login]

  @max_file_depth 4
  # One path component: letters, digits and `._@+-`, not starting with `-`,
  # and a leading dot only before a letter, digit or `_` (so never "." or
  # ".."). The agent host's `isFileKey` (services/agent-host/src/files.ts) is
  # the same rule.
  @file_component ~r/\A(?:[A-Za-z0-9_][A-Za-z0-9._@+-]*|\.[A-Za-z0-9_][A-Za-z0-9._@+-]*)\z/

  @type entry :: %{agent: Agent.t(), runtime: AgentRuntime.t()}

  @doc """
  Create a native agent named `name` running `harness` ("claude_code" or
  "codex"), owned by `owner_user_id`.

  The runtime starts `desired_state: "stopped"`; starting it is the
  supervisor's job. Its `runtime_id` is `<slug>-native-<8 hex>`.

  Seeds the agent's files in the same transaction: `CLAUDE.md` (Claude Code)
  or `AGENTS.md` (Codex) from `identity_template/2`, and
  the harness's settings file (`.claude/settings.json` as `{}`, or
  `.codex/config.toml`).

  Returns `{:ok, agent, runtime}`. The raw runtime token is discarded, never
  returned or logged.

  ## Who created it (task 01a1f42d)

  Every create writes one `"#{@created_event}"` audit event in the SAME
  transaction as the runtime and agent rows, so a failed audit insert rolls
  the whole create back and no runtime exists without its record. Options:

    * `:actor` - the user id of the person who asked for the agent, or
      `:system` when no person did. Defaults to `:system`: the owner is
      never assumed to be the actor, because the owner is who the agent
      belongs to, not who made it (Kobo's Burrow was created by a boot
      task and attributed to whichever admin a random id sorted first).
    * `:path` - the caller, recorded as `metadata["path"]`: `"connect_ai"`,
      `"starter"`, `"control_center"`, or any other name. Defaults to
      `"unspecified"`.

  The event name lives in the `platform.agents` namespace on purpose; the
  owner-transfer event (`platform.federation.runtime_owner_changed`) keeps
  the name a hand-written Kobo row already uses. Do not "fix" either one.
  """
  @spec create(binary(), map(), keyword()) ::
          {:ok, Agent.t(), AgentRuntime.t()} | {:error, Ecto.Changeset.t() | atom()}
  def create(owner_user_id, attrs, opts \\ [])
      when is_binary(owner_user_id) and is_map(attrs) and is_list(opts) do
    name = attrs |> fetch(:name) |> to_string() |> String.trim()
    harness = fetch(attrs, :harness)
    actor = Keyword.get(opts, :actor, :system)
    path = opts |> Keyword.get(:path, "unspecified") |> to_string()

    if name == "" do
      {:error, :name_required}
    else
      slug = slugify(name)

      agent_attrs = %{slug: slug, name: name, status: "active"}

      runtime_attrs = %{
        runtime_id: "#{slug}-native-#{short_suffix()}",
        display_name: name,
        transport: "websocket",
        managed_by: @managed_by,
        harness: harness,
        desired_state: "stopped"
      }

      Repo.transaction(fn ->
        with {:ok, agent, runtime, _raw_token} <-
               Federation.provision_agent_runtime(
                 Platform.Access.Scope.for_user(%{id: owner_user_id}),
                 agent_attrs,
                 runtime_attrs
               ),
             :ok <- seed_files(agent, harness),
             {:ok, _event} <- record_created(agent, runtime, actor, path) do
          {agent, runtime}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, {agent, runtime}} -> {:ok, agent, runtime}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "The audit event type every `create/3` writes."
  @spec created_event() :: String.t()
  def created_event, do: @created_event

  defp record_created(agent, runtime, actor, path) do
    {actor_type, actor_id} = created_actor(actor)

    Platform.Audit.record(%{
      event_type: @created_event,
      action: "native_runtime_created",
      actor_type: actor_type,
      actor_id: actor_id,
      resource_type: "agent_runtime",
      resource_id: runtime.id,
      metadata: %{
        "runtime_id" => runtime.id,
        "runtime_slug" => runtime.runtime_id,
        "agent_id" => agent.id,
        "owner_user_id" => runtime.owner_user_id,
        "harness" => runtime.harness,
        "path" => path
      }
    })
  end

  defp created_actor(:system), do: {"system", nil}
  defp created_actor(user_id) when is_binary(user_id), do: {"user", user_id}

  @doc "Every native agent with its runtime, ordered by agent name."
  @spec list() :: [entry()]
  def list do
    from(a in Agent,
      join: r in AgentRuntime,
      on: r.id == a.runtime_id,
      where: r.managed_by == @managed_by,
      order_by: [asc: a.name],
      select: %{agent: a, runtime: r}
    )
    |> Repo.all()
  end

  @doc "The install-managed runtime behind `agent`, or nil for any other agent."
  @spec get_managed_runtime(Agent.t() | nil) :: AgentRuntime.t() | nil
  def get_managed_runtime(%Agent{runtime_id: nil}), do: nil

  def get_managed_runtime(%Agent{} = agent) do
    case Federation.get_runtime_for_agent(agent) do
      %AgentRuntime{managed_by: @managed_by} = runtime -> runtime
      _ -> nil
    end
  end

  def get_managed_runtime(_), do: nil

  @doc "True when `agent` is a native (install-managed) agent."
  @spec managed?(Agent.t() | nil) :: boolean()
  def managed?(agent), do: not is_nil(get_managed_runtime(agent))

  @doc """
  Record whether the install should keep `agent` running ("running") or not
  ("stopped"). Refuses an agent that is not install-managed.
  """
  @spec set_desired_state(Agent.t() | AgentRuntime.t(), String.t()) ::
          {:ok, AgentRuntime.t()} | {:error, :not_managed | Ecto.Changeset.t()}
  def set_desired_state(%AgentRuntime{managed_by: @managed_by} = runtime, state) do
    runtime
    |> AgentRuntime.changeset(%{desired_state: state})
    |> Repo.update()
  end

  def set_desired_state(%AgentRuntime{}, _state), do: {:error, :not_managed}

  def set_desired_state(%Agent{} = agent, state) do
    case get_managed_runtime(agent) do
      nil -> {:error, :not_managed}
      runtime -> set_desired_state(runtime, state)
    end
  end

  @doc """
  Switch a native agent's harness (`"claude_code"` or `"codex"`), seeding the
  new harness's instructions and settings files. A no-op when it already runs
  `harness`. The caller stops the agent first and starts it after (task
  01a10315 stage 5; `Platform.Agents.Burrow.ensure/2`).
  """
  @spec set_harness(Agent.t(), String.t()) ::
          {:ok, AgentRuntime.t()} | {:error, :not_managed | term()}
  def set_harness(%Agent{} = agent, harness) when harness in ~w(claude_code codex) do
    case get_managed_runtime(agent) do
      nil ->
        {:error, :not_managed}

      %AgentRuntime{harness: ^harness} = runtime ->
        {:ok, runtime}

      %AgentRuntime{} = runtime ->
        Repo.transaction(fn ->
          with {:ok, updated} <-
                 runtime |> AgentRuntime.changeset(%{harness: harness}) |> Repo.update(),
               :ok <- seed_files(agent, harness) do
            updated
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
    end
  end

  def set_harness(%Agent{}, harness), do: {:error, {:unsupported_harness, harness}}

  @doc """
  May `user` manage `agent` (start, stop, restart, edit its files, log it in)?

  True for the owner of the agent's runtime and for an install admin
  (`Tenancy.root_admin?/1`); false for everyone else, and for a `nil` user.
  `user` is a user struct or map with an `:id`, or a bare user id.
  """
  @spec can_manage?(map() | binary() | nil, Agent.t() | nil) :: boolean()
  def can_manage?(nil, _agent), do: false
  def can_manage?(_user, nil), do: false

  def can_manage?(user_id, agent) when is_binary(user_id),
    do: can_manage?(%{id: user_id}, agent)

  def can_manage?(%{id: user_id} = user, %Agent{} = agent) when is_binary(user_id) do
    owner? =
      case Federation.get_runtime_for_agent(agent) do
        %AgentRuntime{owner_user_id: ^user_id} -> true
        _ -> false
      end

    (owner? or Tenancy.root_admin?(user)) and
      Platform.Access.Agents.manage?(Platform.Access.Scope.for_user(%{id: user_id}), agent)
  end

  def can_manage?(_user, _agent), do: false

  # ── Owner transfer (task 01a1f42d stage 2) ────────────────────────

  @doc "The audit event type every successful `transfer_owner/4` writes."
  @spec owner_changed_event() :: String.t()
  def owner_changed_event, do: @owner_changed_event

  @doc """
  The PubSub topic `transfer_owner/4` broadcasts `{:runtime_owner_changed,
  %{runtime_id, previous_owner_user_id, new_owner_user_id}}` on, keyed by the
  runtime's `runtime_id` slug.

  Processes that took an authorization decision from the owner when they
  started and then keep running subscribe to it: `PlatformWeb.RuntimeChannel`
  (its pushed `capabilities` were computed from a Scope capped by the old
  owner) and `PlatformWeb.TerminalViewChannel` (an open terminal is the
  owner's alone, so the previous owner's session is closed).
  """
  @spec owner_topic(String.t()) :: String.t()
  def owner_topic(runtime_id) when is_binary(runtime_id), do: "runtime_owner:" <> runtime_id

  @doc """
  The users a native agent can be transferred to: every non-archived member of
  the root org, at any role, ordered by name. The same rule
  `transfer_owner/4` enforces, so a picker built from this list offers nobody
  the call refuses.
  """
  @spec eligible_owners() :: [Platform.Accounts.User.t()]
  def eligible_owners do
    from(u in Platform.Accounts.User,
      where: u.id in subquery(Tenancy.root_member_ids_query()) and is_nil(u.archived_at),
      order_by: [asc: u.name, asc: u.id]
    )
    |> Repo.all()
  end

  @doc """
  May `user` transfer the ownership of `agent`? The same decision
  `transfer_owner/4` makes first (the runtime's owner, or an install admin),
  for a surface that only shows the control to people the call would let
  through. `false` for an agent that is not install-managed, and for a `nil`
  or malformed user.

  This is an affordance check only: `transfer_owner/4` re-makes the decision
  against the locked runtime row, so a caller that skips this learns nothing.
  """
  @spec can_transfer_owner?(map() | binary() | nil, Agent.t() | nil) :: boolean()
  def can_transfer_owner?(user, %Agent{} = agent) do
    case get_managed_runtime(agent) do
      %AgentRuntime{} = runtime -> authorize_transfer(actor_id(user), runtime) == :ok
      nil -> false
    end
  end

  def can_transfer_owner?(_user, _agent), do: false

  @doc """
  Make `new_owner_user_id` the owner of `agent`'s install-managed runtime.

  `actor` is the person asking (a user struct or map with an `:id`, or a user
  id). Authorization is checked FIRST, before any other property of the
  request: the actor must be the runtime's current owner or an install admin
  (`Tenancy.root_admin?/1`). Anyone else, and a `nil` actor, gets
  `{:error, :forbidden}`, so a refused caller learns nothing about the agent
  or the proposed owner.

  Then, writing nothing on any of them:

    * `{:error, :not_managed}` - `agent` is not an install-managed agent;
    * `{:error, :invalid_owner}` - the new owner is not an existing,
      non-archived member of the root org (`eligible_owners/0`);
    * `{:error, :same_owner}` - the new owner already owns it.

  On success, ONE transaction updates `owner_user_id` through
  `AgentRuntime.changeset/2` and records a `"#{@owner_changed_event}"` audit
  event (actor, previous and new owner, runtime and agent ids). The runtime
  row is locked `FOR UPDATE` and every check above is made against the locked
  row, so two concurrent transfers cannot both pass the owner check.

  After commit:

    * the previous owner is notified (`Platform.Notifications.fan_out_to_user/2`,
      linking `/control/<agent slug>`), unless the actor IS the previous owner.
      A notification failure is logged and never undoes the transfer;
    * `{:runtime_owner_changed, ...}` is broadcast on `owner_topic/1`.

  Nothing else caches the owner: `can_manage?/2`, `Platform.Access.Agents.manage?/2`
  and `Platform.Access.Scope.for_runtime/1` (the owner cap) all read the
  runtime row on every call.

  Options: `:notify` - a 2-arity function replacing
  `Platform.Notifications.fan_out_to_user/2` (tests).

  The event name is in the `platform.federation` namespace because a
  hand-written row on Kobo already uses it; see `create/3`.
  """
  @spec transfer_owner(map() | binary() | nil, Agent.t(), binary(), keyword()) ::
          {:ok, AgentRuntime.t()}
          | {:error, :forbidden | :not_managed | :invalid_owner | :same_owner}
          | {:error, Ecto.Changeset.t()}
  def transfer_owner(actor, agent, new_owner_user_id, opts \\ [])

  def transfer_owner(actor, %Agent{} = agent, new_owner_user_id, opts) when is_list(opts) do
    actor_id = actor_id(actor)

    Repo.transaction(fn ->
      runtime = lock_runtime(agent)

      with :ok <- authorize_transfer(actor_id, runtime),
           :ok <- check_managed(runtime),
           :ok <- check_new_owner(new_owner_user_id),
           :ok <- check_not_same(runtime, new_owner_user_id),
           {:ok, updated} <-
             runtime
             |> AgentRuntime.changeset(%{owner_user_id: new_owner_user_id})
             |> Repo.update(),
           {:ok, _event} <- record_owner_changed(actor_id, agent, runtime, updated) do
        {runtime.owner_user_id, updated}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {previous_owner_id, updated}} ->
        after_transfer(actor_id, agent, previous_owner_id, updated, opts)
        {:ok, updated}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def transfer_owner(_actor, _agent, _new_owner_user_id, _opts), do: {:error, :forbidden}

  defp actor_id(%{id: id}) when is_binary(id), do: actor_id(id)

  defp actor_id(id) when is_binary(id) do
    if Platform.UUID.valid?(id), do: id, else: nil
  end

  defp actor_id(_), do: nil

  defp lock_runtime(%Agent{runtime_id: nil}), do: nil

  defp lock_runtime(%Agent{runtime_id: runtime_pk}) do
    from(r in AgentRuntime, where: r.id == ^runtime_pk, lock: "FOR UPDATE")
    |> Repo.one()
  end

  # The one authorization decision. Owner of the runtime, or an install admin;
  # a nil actor, and anyone else, is refused before anything else is looked at.
  defp authorize_transfer(nil, _runtime), do: {:error, :forbidden}

  defp authorize_transfer(actor_id, runtime) do
    owner? = match?(%AgentRuntime{owner_user_id: ^actor_id}, runtime)

    if owner? or Tenancy.root_admin?(%{id: actor_id}),
      do: :ok,
      else: {:error, :forbidden}
  end

  defp check_managed(%AgentRuntime{managed_by: @managed_by}), do: :ok
  defp check_managed(_), do: {:error, :not_managed}

  defp check_new_owner(user_id) when is_binary(user_id) do
    with true <- Platform.UUID.valid?(user_id),
         %Platform.Accounts.User{archived_at: nil} = user <-
           Repo.get(Platform.Accounts.User, user_id),
         true <- Tenancy.root_member?(user) do
      :ok
    else
      _ -> {:error, :invalid_owner}
    end
  end

  defp check_new_owner(_), do: {:error, :invalid_owner}

  defp check_not_same(%AgentRuntime{owner_user_id: owner}, owner), do: {:error, :same_owner}
  defp check_not_same(_runtime, _new_owner), do: :ok

  defp record_owner_changed(actor_id, agent, previous, updated) do
    Platform.Audit.record(%{
      event_type: @owner_changed_event,
      action: "runtime_owner_changed",
      actor_type: "user",
      actor_id: actor_id,
      resource_type: "agent_runtime",
      resource_id: updated.id,
      metadata: %{
        "previous_owner_user_id" => previous.owner_user_id,
        "new_owner_user_id" => updated.owner_user_id,
        "runtime_id" => updated.id,
        "runtime_slug" => updated.runtime_id,
        "agent_id" => agent.id
      }
    })
  end

  defp after_transfer(actor_id, agent, previous_owner_id, updated, opts) do
    Phoenix.PubSub.broadcast(
      Platform.PubSub,
      owner_topic(updated.runtime_id),
      {:runtime_owner_changed,
       %{
         runtime_id: updated.runtime_id,
         previous_owner_user_id: previous_owner_id,
         new_owner_user_id: updated.owner_user_id
       }}
    )

    if is_binary(previous_owner_id) and previous_owner_id != actor_id do
      notify = Keyword.get(opts, :notify, &Platform.Notifications.fan_out_to_user/2)
      notify_previous_owner(notify, actor_id, agent, previous_owner_id, updated.owner_user_id)
    end

    :ok
  end

  defp notify_previous_owner(notify, actor_id, agent, previous_owner_id, new_owner_id) do
    new_owner = display_name(new_owner_id)
    by = display_name(actor_id)

    payload = %{
      title: "#{agent.name} has a new owner",
      body: "#{by} made #{new_owner} the owner of #{agent.name}. You no longer own it.",
      url: "/control/#{agent.slug}"
    }

    case notify.(previous_owner_id, payload) do
      :ok ->
        :ok

      other ->
        Logger.warning(
          "[NativeAgents] owner-change notification for runtime of agent #{agent.id} " <>
            "returned #{inspect(other)}; the transfer stands"
        )
    end
  rescue
    e ->
      Logger.warning(
        "[NativeAgents] owner-change notification for agent #{agent.id} failed: " <>
          "#{Exception.message(e)}; the transfer stands"
      )
  catch
    kind, reason ->
      Logger.warning(
        "[NativeAgents] owner-change notification for agent #{agent.id} failed: " <>
          "#{inspect({kind, reason})}; the transfer stands"
      )
  end

  defp display_name(user_id) do
    case Platform.Accounts.get_user(user_id) do
      %{name: name} when is_binary(name) and name != "" -> name
      %{email: email} when is_binary(email) -> email
      _ -> "Someone"
    end
  end

  # ── Agent files (stage 5) ─────────────────────────────────────────

  @doc """
  The instructions file a harness reads, from its adapter (`AGENTS.md` for
  Codex, `CLAUDE.md` for Claude Code). A harness with no adapter is
  `:unsupported`; it no longer defaults to `CLAUDE.md`.
  """
  @spec instructions_key(String.t() | nil) :: String.t() | :unsupported
  def instructions_key(harness) do
    case Platform.Agents.Harness.adapter_for(harness) do
      {:ok, adapter} -> adapter.instructions_path()
      :unsupported -> :unsupported
    end
  end

  @doc """
  The settings file a harness reads, from its adapter (`.claude/settings.json`
  for Claude Code, `.codex/config.toml` for Codex), or `:unsupported`.
  """
  @spec settings_key(String.t() | nil) :: String.t() | :unsupported
  def settings_key(harness) do
    case Platform.Agents.Harness.adapter_for(harness) do
      {:ok, adapter} -> adapter.settings_path()
      :unsupported -> :unsupported
    end
  end

  defp settings_seed(harness) do
    {:ok, adapter} = Platform.Agents.Harness.adapter_for(harness)
    adapter.settings_seed()
  end

  @doc """
  The identity file a new native agent starts with. It tells the agent what
  it may do on this machine (sudo, packages, its own services) and that a
  consent step goes to a person as a link. It does not claim the agent is
  walled off from other agents: per-agent users stop accidents only.
  """
  @spec identity_template(String.t(), String.t() | nil) :: String.t()
  def identity_template(name, harness) do
    harness_name = if harness == "codex", do: "Codex CLI", else: "Claude Code"

    """
    # #{name}

    You are #{name}, an agent on this Burrow install. You run #{harness_name} on this
    server, as your own user, in your own work folder.

    ## What you can do here

    - You may use sudo, install packages, and run your own services on this machine.
    - Keep your work in this folder. Services you want to outlive a restart can run as
      user services (`systemctl --user`).
    - When something needs a person's consent (a login, an approval, a payment), send
      them the link in Burrow and wait for them. Never complete it on their behalf.

    ## Other agents

    Other agents on this install may run on the same machine. Separate users keep you
    from crossing into each other by accident; they are not a wall. Leave other
    agents' files alone.

    #{Manners.handoff_rule()}
    ## This file

    This file is managed from Agents in Burrow and is rewritten every time you
    start. Ask your owner to change it there; edits made here do not last.
    """
  end

  @doc """
  Is `key` a file key a native agent's files may use? Relative only: no
  leading "/" or "~", no "", "." or ".." component, at most #{@max_file_depth}
  components, each made of letters, digits and `._@+-`. The agent host
  applies the same rule before it writes, and also refuses a key whose real
  path leaves the work dir.
  """
  @spec valid_file_key?(term()) :: boolean()
  def valid_file_key?(key) when is_binary(key) and byte_size(key) in 1..255 do
    parts = String.split(key, "/")

    not String.starts_with?(key, ["/", "~"]) and length(parts) <= @max_file_depth and
      Enum.all?(parts, &Regex.match?(@file_component, &1))
  end

  def valid_file_key?(_), do: false

  @doc "A managed agent's files, ordered by key."
  @spec list_files(Agent.t()) :: [WorkspaceFile.t()]
  def list_files(%Agent{id: id}), do: MemoryContext.list_workspace_files(id)

  @doc """
  Save one of `agent`'s files as `actor`.

  `expected_version` is the version the editor loaded (nil for a new file);
  a mismatch is `{:error, :stale_workspace_file}`, and a nil version for a
  key that already exists is `{:error, :file_exists}`, so two editors never
  silently overwrite each other.

  Refused, writing nothing, with:

    * `{:error, :not_managed}` when `agent` is not a native agent;
    * `{:error, :forbidden}` unless `can_manage?(actor, agent)`, checked
      before anything else about the request;
    * `{:error, :invalid_key}` unless `valid_file_key?/1`;
    * `{:error, {:invalid_json, line}}` for a `.json` key whose content does
      not parse.
  """
  @spec save_file(map() | binary() | nil, Agent.t(), String.t(), String.t(), integer() | nil) ::
          {:ok, WorkspaceFile.t()}
          | {:error,
             :not_managed
             | :forbidden
             | :invalid_key
             | :file_exists
             | :stale_workspace_file
             | {:invalid_json, pos_integer()}
             | Ecto.Changeset.t()}
  def save_file(actor, %Agent{} = agent, key, content, expected_version)
      when is_binary(content) do
    cond do
      not managed?(agent) -> {:error, :not_managed}
      not can_manage?(actor, agent) -> {:error, :forbidden}
      not valid_file_key?(key) -> {:error, :invalid_key}
      true -> write_file(agent, key, content, expected_version)
    end
  end

  defp write_file(agent, key, content, expected_version) do
    with :ok <- check_json(key, content) do
      case {expected_version, MemoryContext.get_workspace_file(agent.id, key)} do
        {nil, %WorkspaceFile{}} ->
          {:error, :file_exists}

        {nil, nil} ->
          MemoryContext.upsert_workspace_file(agent.id, key, content)

        {version, _} ->
          MemoryContext.upsert_workspace_file(agent.id, key, content, expected_version: version)
      end
    end
  end

  @doc """
  `{:error, {:invalid_json, line}}` when `key` is a `.json` file whose
  content does not parse (`line` is 1-based), else `:ok`.
  """
  @spec check_json(String.t(), String.t()) :: :ok | {:error, {:invalid_json, pos_integer()}}
  def check_json(key, content) when is_binary(key) and is_binary(content) do
    if String.ends_with?(key, ".json") do
      case Jason.decode(content) do
        {:ok, _} ->
          :ok

        {:error, %Jason.DecodeError{position: pos}} ->
          {:error, {:invalid_json, line_at(content, pos)}}
      end
    else
      :ok
    end
  end

  defp line_at(content, pos) do
    pos = min(max(pos, 0), byte_size(content))
    content |> binary_part(0, pos) |> :binary.matches("\n") |> length() |> Kernel.+(1)
  end

  @doc """
  The files `agent.start` carries: every file with a valid key, as
  `%{"key", "content", "version"}`. Every agent's instructions file carries
  the handoff rule (`Platform.Agents.Manners.ensure/1`, added only if
  absent). For the Burrow agent (`Platform.Agents.Burrow`) it also carries a
  generated owner / admins section, read from the database on every call.
  """
  @spec start_files(Agent.t()) :: [map()]
  def start_files(%Agent{} = agent) do
    burrow? = Platform.Agents.Burrow.burrow?(agent)

    section =
      if burrow?,
        do:
          Platform.Agents.Burrow.admins_section(agent) <>
            Platform.Agents.Burrow.Starter.instructions_section(agent),
        else: ""

    # The instructions file of the harness the agent actually runs (task 01a19505).
    key = runtime_instructions_key(agent)

    for %WorkspaceFile{} = f <- list_files(agent), valid_file_key?(f.file_key) do
      # Every native agent's instructions file carries the handoff rule, so an
      # agent whose stored file predates it picks it up at its next start
      # (task 01a1b733). Not stored: versions and drift are unaffected.
      content =
        cond do
          f.file_key != key -> f.content
          burrow? -> Manners.ensure(f.content) <> section
          true -> Manners.ensure(f.content)
        end

      %{"key" => f.file_key, "content" => content, "version" => f.version}
    end
  end

  defp runtime_instructions_key(agent) do
    case get_managed_runtime(agent) do
      %AgentRuntime{harness: harness} -> instructions_key(harness)
      nil -> nil
    end
  end

  @doc """
  The keys of `files` that a running agent has not picked up: the host's
  `files_applied` (key => version written at its last start) names an older
  version, or not the key at all. Empty when the agent is not up (the next
  start applies everything) or the host has not reported what it applied.
  """
  @spec pending_file_keys([WorkspaceFile.t()], map() | nil) :: [String.t()]
  def pending_file_keys(files, %{state: state, files_applied: applied})
      when state in @live_states and is_map(applied) do
    for %WorkspaceFile{file_key: key, version: version} <- files,
        valid_file_key?(key),
        Map.get(applied, key) != version,
        do: key
  end

  def pending_file_keys(_files, _observed), do: []

  @doc """
  Keys the agent changed on disk since the host last wrote them
  (`files_drifted` in the host's `agent.state`). Empty when unknown.
  """
  @spec drifted_keys(Agent.t()) :: [String.t()]
  def drifted_keys(%Agent{id: id}) do
    case Platform.AgentHost.status(id) do
      %{files_drifted: keys} when is_list(keys) -> Enum.filter(keys, &is_binary/1)
      _ -> []
    end
  end

  @doc """
  The drifted keys an owner has since resolved: their stored version is newer
  than the one the host last applied (`Config` only lets a drifted key be
  saved once the owner has seen the disk copy). Sent as `force_keys` in
  `agent.start`/`agent.restart`; the host overwrites a drifted key only when
  it is named there.
  """
  @spec force_keys(Agent.t()) :: [String.t()]
  def force_keys(%Agent{id: id} = agent) do
    applied =
      case Platform.AgentHost.status(id) do
        %{files_applied: %{} = applied} -> applied
        _ -> %{}
      end

    drifted = drifted_keys(agent)

    for %WorkspaceFile{file_key: key, version: version} <- list_files(agent),
        key in drifted,
        Map.get(applied, key) != version,
        do: key
  end

  @doc "True when a running agent has not picked up a saved file (\"Restart to apply\")."
  @spec restart_to_apply?([WorkspaceFile.t()], map() | nil) :: boolean()
  def restart_to_apply?(files, observed), do: pending_file_keys(files, observed) != []

  @doc "True when the observed state is one in which the agent's process is up."
  @spec live?(map() | nil) :: boolean()
  def live?(%{state: state}) when state in @live_states, do: true
  def live?(_), do: false

  defp seed_instructions(name, harness)
       when name == "Burrow" and harness in ~w(claude_code codex),
       do: Platform.Agents.Burrow.identity_template(name, harness)

  defp seed_instructions(name, harness), do: identity_template(name, harness)

  defp seed_files(%Agent{}, harness) when harness not in ~w(claude_code codex),
    do: {:error, {:unsupported_harness, harness}}

  defp seed_files(%Agent{id: id, name: name}, harness) do
    seeds = [
      {instructions_key(harness), seed_instructions(name, harness)},
      {settings_key(harness), settings_seed(harness)}
    ]

    Enum.reduce_while(seeds, :ok, fn {key, content}, :ok ->
      case MemoryContext.upsert_workspace_file(id, key, content) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp fetch(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> Map.get(attrs, Atom.to_string(key))
    end
  end

  defp slugify(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> case do
      "" -> "agent"
      slug -> slug
    end
  end

  defp short_suffix do
    :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
  end
end
