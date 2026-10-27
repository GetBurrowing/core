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
  because it is one. A new `runtime_type` value is ruled out.

  ## Tokens

  `create/2` provisions through `Platform.Federation.provision_agent_runtime/3`
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

  alias Platform.Agents.{Agent, AgentRuntime, MemoryContext, WorkspaceFile}
  alias Platform.Federation
  alias Platform.Repo
  alias Platform.Tenancy

  @managed_by "install"

  # Observed states in which the agent's process is up, so a file saved now
  # is not what it is running.
  @live_states [:running, :starting, :needs_login]

  @max_file_depth 3
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
  `.claude/settings.json` as `{}`.

  Returns `{:ok, agent, runtime}`. The raw runtime token is discarded, never
  returned or logged.
  """
  @spec create(binary(), map()) ::
          {:ok, Agent.t(), AgentRuntime.t()} | {:error, Ecto.Changeset.t() | atom()}
  def create(owner_user_id, attrs) when is_binary(owner_user_id) and is_map(attrs) do
    name = attrs |> fetch(:name) |> to_string() |> String.trim()
    harness = fetch(attrs, :harness)

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
             :ok <- seed_files(agent, harness) do
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

  # ── Agent files (stage 5) ─────────────────────────────────────────

  @doc """
  The instructions file a harness reads: `AGENTS.md` for Codex, `CLAUDE.md`
  for Claude Code (and anything else).
  """
  @spec instructions_key(String.t() | nil) :: String.t()
  def instructions_key("codex"), do: "AGENTS.md"
  def instructions_key(_), do: "CLAUDE.md"

  @doc "The settings file seeded for every native agent."
  def settings_key, do: ".claude/settings.json"

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
  `%{"key", "content", "version"}`. For the Burrow agent
  (`Platform.Agents.Burrow`) the instructions file also carries a generated
  owner / admins section, read from the database on every call.
  """
  @spec start_files(Agent.t()) :: [map()]
  def start_files(%Agent{} = agent) do
    burrow? = Platform.Agents.Burrow.burrow?(agent)
    section = if burrow?, do: Platform.Agents.Burrow.admins_section(), else: ""

    for %WorkspaceFile{} = f <- list_files(agent), valid_file_key?(f.file_key) do
      content =
        if burrow? and f.file_key == instructions_key("claude_code"),
          do: f.content <> section,
          else: f.content

      %{"key" => f.file_key, "content" => content, "version" => f.version}
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

  @doc "True when a running agent has not picked up a saved file (\"Restart to apply\")."
  @spec restart_to_apply?([WorkspaceFile.t()], map() | nil) :: boolean()
  def restart_to_apply?(files, observed), do: pending_file_keys(files, observed) != []

  @doc "True when the observed state is one in which the agent's process is up."
  @spec live?(map() | nil) :: boolean()
  def live?(%{state: state}) when state in @live_states, do: true
  def live?(_), do: false

  defp seed_instructions(name, "claude_code") when name == "Burrow",
    do: Platform.Agents.Burrow.identity_template(name)

  defp seed_instructions(name, harness), do: identity_template(name, harness)

  defp seed_files(%Agent{id: id, name: name}, harness) do
    seeds = [
      {instructions_key(harness), seed_instructions(name, harness)},
      {settings_key(), "{}"}
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
