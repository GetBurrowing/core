defmodule Platform.Designer do
  @moduledoc """
  The UX super agent: the existing `designer` role made richer (no new role;
  task 01a1af00 decided that). Phase 1 of the UX super agent spec.

  `provision/1` is the one way to switch it on for an install. It is a plain
  function so it runs on a release node through `bin/platform rpc`; there is
  deliberately no mix task (Mix is not in a release, which is what broke the
  showrunner's mix task). Ids are given at run time and never committed.

  ## Where the designer's own configuration lives

  The escalation human is `escalate_user_id` in the `ux.friction_watch` row's
  `trigger_config`, stamped `"operator_set" => true` so the boot-time
  re-registration keeps it (the `Platform.Showrunner.Config` pattern). Read it
  with `escalate_user_id/0`. The friction watch files its `decision` findings
  to that user; unset, it falls back to the install owner, as before.

  The friction-watch spaces are the spaces the agent participates in
  (`Platform.Ux.FrictionWatch` scopes to exactly those), so provisioning a
  space means joining the agent to it. The weekly digest space is the agent's
  `metadata["ux_digest_space_id"]` (`Platform.Ux.Digest`).

  ## Runtime fitness, and why an external runtime is NOT required

  The Responsibilities Router calls a handler's `handle_output/3` only for a
  `kind: "external"` agent (an OpenAI-compatible or Ollama endpoint); native
  and federated runtimes, Claude Code included, get a prompt and act through
  tools (task 01a1eb2f). Per designer key:

    * `ux.friction_watch` runs server-side; no runtime is involved.
    * `design.task_direction` tells a native agent to attach a canvas with
      `task_attach_canvas` (or `task_design_decline`); `handle_output/3` is the
      external-only twin. Works natively.
    * `meetings.visual_adjust` / `meetings.interaction_design`: the recipient
      writes the canvas with tools; `handle_output/2` is a no-op. Works
      natively, and CANNOT work on an external endpoint, which has no tools.
    * `design.critique`: an external assignee answers the
      `design_critique_request` tool synchronously; a native one is
      dispatched and returns its verdict with `design_critique_complete`,
      which lands through the same `Critique.land_verdict/2` (task 01a1eb2f).
      Works natively.
    * `design.spec_writer` / `design.brand_check` are placeholders on every
      runtime.

  An external endpoint has no tools, no subagents and no web, so it cannot be
  the lead. `provision/1` therefore accepts a native or federated runtime and
  reports what it found instead of refusing.

  ## Tool grants

  A runtime created with an explicit module list carries a
  `restricted_permissions` map fixed at creation
  (`Platform.Federation.register_runtime`). Turning a bundle on later does
  not widen it, so the designer tools stayed hidden on a native agent whose
  bundles were on. `provision/1` adds the missing bundles AND the missing
  permissions of `required_tools/0` to the runtime's profile
  (`apply_grants: false` only reports them). It never adds
  `prompts.manage`, `admin.use` or `access.manage`, and it cannot lift the
  owner cap: a permission the runtime's owner lacks is reported, not granted.
  """

  import Ecto.Query

  alias Platform.Access.RuntimeProfile
  alias Platform.Access.RuntimeProfiles
  alias Platform.Access.ToolPermissions
  alias Platform.Access.Tools
  alias Platform.Accounts
  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Agents.ConfigFiles
  alias Platform.Chat
  alias Platform.Experiments.Goal
  alias Platform.Federation
  alias Platform.Federation.ToolSurface
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.Handlers.UxFrictionWatch
  alias Platform.Responsibilities.Responsibility
  alias Platform.Roles
  alias Platform.Roles.Seeds
  alias Platform.Ux.Digest

  @role "designer"
  @config_key "ux.friction_watch"
  @changed_topic "responsibilities:changed"
  @goal_metric "ux_finding_keep_rate"
  @goal_statement "Raise the UX finding keep rate: the share of the designer's UX decisions " <>
                    "a human keeps rather than dismisses."
  @template_dir "agent_templates/designer"
  # The name a native agent's `.mcp.json` gives the Burrow server
  # (`Platform.Agents.Harness.Config.burrow_server_names/0`).
  @template_mcp_server "burrow"
  @template_files ~w(
    CLAUDE.md
    .claude/settings.json
    .claude/agents/scout.md
    .claude/agents/critic.md
    .claude/agents/prototyper.md
    .claude/agents/evaluator.md
  )

  # The tools the lead needs on its runtime. Missing ones are a warning.
  @required_tools ~w(
    canvas_create canvas_patch canvas_get task_attach_canvas task_design_decline task_get
    task_create prototype_publish prototype_versions memory_view memory_create memory_search
    memory_str_replace experiment_goal_list design_critique_complete
  )

  # Never granted by provisioning, whatever a future required tool maps to.
  @never_grant ~w(prompts.manage admin.use access.manage)
  @external_warning "this agent is kind: \"external\" (an HTTP endpoint with no tools): " <>
                      "meetings.visual_adjust and meetings.interaction_design cannot write " <>
                      "canvases, and there is no swarm or web. Use a Claude Code runtime for the lead."

  @typedoc "What `provision/1` did and found."
  @type report :: %{
          agent_id: String.t(),
          role: :assigned | :unchanged | :reassigned,
          escalate_user_id: String.t(),
          watch_space_ids: [String.t()],
          digest_space_id: String.t() | nil,
          goal: {:created | :exists, String.t()} | :skipped,
          runtime: map(),
          warnings: [String.t()]
        }

  @reflection_marker "## Reflect before you stop"
  @reflection """
  #{@reflection_marker}

  After you have delivered or declined, and only if you hold the memory tools, write ONE entry in your private journal (`space/<your space id>/private/<your agent id>/journal/`): what you did and which pattern cards you used, what you would do differently, and each card whose confidence should move, with its evidence. Cap a reflection-only raise at 0.7. A human agreeing with you is not evidence and never raises a card. Never edit a prompt template, including this one. Save work in progress before any long step, and run at most 3 subagents at once.
  """

  @doc """
  The end-of-job reflection instruction appended to the designer's
  tool-bearing prompt templates until a real `design.reflect`
  responsibility exists. Starts with `reflection_marker/0`.
  """
  @spec reflection_instruction() :: String.t()
  def reflection_instruction, do: @reflection

  @doc "The heading that marks the reflection instruction in a template body."
  @spec reflection_marker() :: String.t()
  def reflection_marker, do: @reflection_marker

  @doc "The role key."
  @spec role() :: String.t()
  def role, do: @role

  @doc "The metric the L1 experiment goal raises."
  @spec goal_metric() :: String.t()
  def goal_metric, do: @goal_metric

  @doc "The tools the designer's runtime must expose."
  @spec required_tools() :: [String.t()]
  def required_tools, do: @required_tools

  @doc """
  The designer's escalation human: `escalate_user_id` on the
  `ux.friction_watch` row, or nil when unset or malformed. Never raises.
  """
  @spec escalate_user_id() :: String.t() | nil
  def escalate_user_id do
    case Responsibilities.get_by_key(@config_key) do
      %Responsibility{} = row -> escalate_user_id(row)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc "`escalate_user_id` read from a row (or its `trigger_config` map)."
  @spec escalate_user_id(Responsibility.t() | map() | nil) :: String.t() | nil
  def escalate_user_id(%Responsibility{trigger_config: config}), do: escalate_user_id(config)

  def escalate_user_id(%{} = config) do
    case Map.get(config, "escalate_user_id") do
      id when is_binary(id) -> if Platform.UUID.valid?(id), do: id, else: nil
      _ -> nil
    end
  end

  def escalate_user_id(_), do: nil

  @doc """
  Switches the designer super agent on for one agent. Idempotent.

  Attrs (map or keyword, atom or string keys):

    * `agent_id` (required) — the agent to hold `designer`;
    * `escalate_user_id` (required) — the one human escalations go to;
    * `watch_space_ids` (optional list) — spaces the friction watch reads; the
      agent is joined to each;
    * `digest_space_id` (optional) — where the weekly digest posts; joined too;
    * `set_goal` (default true) — ensure ONE active goal raising
      `ux_finding_keep_rate`;
    * `reassign: true` — move the role from another agent; without it a role
      held by someone else is refused;
    * `apply_grants` (default true) — add the bundles and permissions the
      runtime needs for `required_tools/0` (see "Tool grants"); false only
      reports them under `runtime.grants_needed`.

  Returns `{:ok, report}` or `{:error, reason}`. Writes nothing when a
  required id is missing or unknown.
  """
  @spec provision(map() | keyword()) :: {:ok, report()} | {:error, term()}
  def provision(attrs) when is_list(attrs), do: provision(Map.new(attrs))

  def provision(attrs) when is_map(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    with {:ok, agent} <- agent(attrs["agent_id"]),
         {:ok, user_id} <- user(attrs["escalate_user_id"]),
         {:ok, watch} <- spaces(attrs["watch_space_ids"] || [], :watch_space_ids),
         {:ok, digest} <- digest_space(attrs["digest_space_id"]),
         :ok <- Seeds.seed_defaults(only_keys: [@role]),
         {:ok, role} <- assign(agent, attrs["reassign"] == true),
         :ok <- join_all(Enum.uniq(watch ++ List.wrap(digest)), agent.id),
         {:ok, agent} <- put_digest_space(agent, digest),
         {:ok, _row} <- configure(user_id),
         {:ok, goal} <- goal(Map.get(attrs, "set_goal", true)) do
      Phoenix.PubSub.broadcast(Platform.PubSub, @changed_topic, {:responsibilities_changed, :all})

      grants = grant_tools(agent, Map.get(attrs, "apply_grants", true))
      runtime = agent |> runtime_report() |> Map.merge(grants)

      {:ok,
       %{
         agent_id: agent.id,
         role: role,
         escalate_user_id: user_id,
         watch_space_ids: watch,
         digest_space_id: digest,
         goal: goal,
         runtime: runtime,
         warnings: warnings(agent, runtime)
       }}
    end
  end

  def provision(_attrs), do: {:error, :attrs_must_be_a_map}

  @doc """
  The agent-side template files (`priv/agent_templates/designer`), as
  `[{path, content}]`. `opts[:mcp_server]` renames the Burrow MCP server in
  subagent tool lists (default `"burrow"`, the name a native agent's
  `.mcp.json` uses), for a runtime whose `.mcp.json` names it differently.
  """
  @spec template_files(keyword()) :: [{String.t(), String.t()}]
  def template_files(opts \\ []) do
    server = Keyword.get(opts, :mcp_server, @template_mcp_server)
    dir = Application.app_dir(:platform, Path.join("priv", @template_dir))

    Enum.map(@template_files, fn path ->
      content =
        dir
        |> Path.join(path)
        |> File.read!()
        |> String.replace("mcp__#{@template_mcp_server}__", "mcp__#{server}__")

      {path, content}
    end)
  end

  @doc """
  Writes `template_files/1` into the agent's workspace through
  `Platform.Agents.ConfigFiles.write/5` as `actor` (a user who may manage the
  agent: its owner or an install admin). Never discards an operator's edit:

    * `CLAUDE.md` — the manifest is APPENDED to what is there (a new native
      agent's identity file, or an operator's text), once: a file already
      carrying the manifest heading is `:kept`;
    * `.claude/settings.json` — written only over the harness's empty seed
      (`{}`) or when absent; otherwise `:kept`;
    * subagent files — create-only; an existing one is `:kept`.

  Every write carries the hash it read, so a concurrent edit is a conflict,
  reported `:kept`. `{:ok, [{path, :written | :kept | {:error, reason}}]}` or
  `{:error, reason}`.
  """
  @spec install_files(term(), String.t(), keyword()) ::
          {:ok, [{String.t(), :written | :kept | {:error, term()}}]} | {:error, term()}
  def install_files(actor, agent_id, opts \\ []) do
    with {:ok, agent} <- agent(agent_id),
         {:ok, _} <- ConfigFiles.list(actor, agent) do
      {:ok,
       Enum.map(template_files(opts), fn {path, content} ->
         current =
           case ConfigFiles.read(actor, agent, path) do
             {:ok, %{content: existing, sha256: sha}} -> {existing, sha}
             _ -> nil
           end

         {path, install_file(actor, agent, path, content, current)}
       end)}
    end
  end

  @manifest_marker "# Designer (UX super agent)"

  defp install_file(actor, agent, path, content, nil),
    do: put_file(actor, agent, path, content, nil)

  defp install_file(actor, agent, "CLAUDE.md", content, {existing, sha}) do
    if String.contains?(existing, @manifest_marker),
      do: :kept,
      else:
        put_file(
          actor,
          agent,
          "CLAUDE.md",
          String.trim_trailing(existing) <> "\n\n" <> content,
          sha
        )
  end

  defp install_file(actor, agent, ".claude/settings.json", content, {existing, sha}) do
    if String.trim(existing) in ["", "{}"],
      do: put_file(actor, agent, ".claude/settings.json", content, sha),
      else: :kept
  end

  defp install_file(_actor, _agent, _path, _content, _current), do: :kept

  defp put_file(actor, agent, path, content, sha) do
    case ConfigFiles.write(actor, agent, path, content, sha) do
      {:ok, _sha} -> :written
      {:conflict, _sha} -> :kept
      {:error, reason} -> {:error, reason}
    end
  end

  # ── internals ──

  defp agent(id) when is_binary(id) do
    with true <- Platform.UUID.valid?(id),
         %Agent{} = agent <- Repo.get(Agent, id) do
      {:ok, agent}
    else
      _ -> {:error, {:not_found, :agent_id}}
    end
  end

  defp agent(_), do: {:error, {:missing, :agent_id}}

  defp user(id) when is_binary(id) do
    with true <- Platform.UUID.valid?(id),
         %{} <- Accounts.get_user(id) do
      {:ok, id}
    else
      _ -> {:error, {:not_found, :escalate_user_id}}
    end
  end

  defp user(_), do: {:error, {:missing, :escalate_user_id}}

  defp spaces(ids, field) when is_list(ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      if is_binary(id) and Platform.UUID.valid?(id) and Chat.get_space(id) do
        {:cont, {:ok, acc ++ [id]}}
      else
        {:halt, {:error, {:not_found, field, id}}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.uniq(ids)}
      error -> error
    end
  end

  defp spaces(_ids, field), do: {:error, {:not_a_list, field}}

  defp digest_space(nil), do: {:ok, nil}

  defp digest_space(id) do
    case spaces([id], :digest_space_id) do
      {:ok, [id]} ->
        if id in Chat.external_space_ids(),
          do: {:error, {:external_space, :digest_space_id}},
          else: {:ok, id}

      error ->
        error
    end
  end

  defp assign(agent, reassign?) do
    case Roles.agent_id_for_role(@role) do
      id when id == agent.id ->
        {:ok, :unchanged}

      nil ->
        with {:ok, _} <- Roles.assign_role(@role, agent.id), do: {:ok, :assigned}

      _other when reassign? ->
        :ok = Roles.unassign_role(@role)
        with {:ok, _} <- Roles.assign_role(@role, agent.id), do: {:ok, :reassigned}

      other ->
        {:error, {:role_held_by, other}}
    end
  end

  defp join_all(space_ids, agent_id) do
    Enum.reduce_while(space_ids, :ok, fn space_id, :ok ->
      case join(space_id, agent_id) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp join(space_id, agent_id) do
    case Chat.get_agent_participant(space_id, agent_id) do
      %{} ->
        :ok

      nil ->
        case Chat.add_participant(space_id, %{
               participant_type: "agent",
               participant_id: agent_id,
               joined_at: DateTime.utc_now()
             }) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, {:join_failed, space_id, reason}}
        end
    end
  end

  defp put_digest_space(agent, nil), do: {:ok, agent}

  defp put_digest_space(%Agent{} = agent, space_id) do
    metadata = Map.put(agent.metadata || %{}, Digest.digest_space_key(), space_id)

    if metadata == agent.metadata do
      {:ok, agent}
    else
      agent |> Agent.changeset(%{metadata: metadata}) |> Repo.update()
    end
  end

  # Registers the friction-watch row if boot has not, then merges the
  # escalation user into its config. The cron `expression`/`timezone` already
  # there are kept; `operator_set` makes the boot re-registration keep it all.
  defp configure(user_id) do
    [spec] = UxFrictionWatch.register()

    row =
      case Responsibilities.get_by_key(@config_key) do
        %Responsibility{} = row -> {:ok, row}
        nil -> Responsibilities.upsert_by_key(spec)
      end

    with {:ok, row} <- row do
      config =
        (row.trigger_config || %{})
        |> Map.put("escalate_user_id", user_id)
        |> Map.put("operator_set", true)

      if config == row.trigger_config,
        do: {:ok, row},
        else: Responsibilities.update_responsibility(row, %{trigger_config: config})
    end
  end

  # Install-wide (org_id nil): one active goal on the metric, whatever its org,
  # is enough; an operator who scoped one to an org keeps it.
  defp goal(false), do: {:ok, :skipped}

  defp goal(_set?) do
    existing =
      from(g in Goal,
        where: g.status == "active",
        where: fragment("?->>'slug' = ?", g.metric_spec, ^@goal_metric),
        order_by: [asc: g.inserted_at],
        limit: 1
      )
      |> Repo.one()

    case existing do
      %Goal{id: id} ->
        {:ok, {:exists, id}}

      nil ->
        %Goal{}
        |> Goal.changeset(%{
          "statement" => @goal_statement,
          "metric_spec" => %{"kind" => "registered", "slug" => @goal_metric},
          "status" => "active"
        })
        |> Repo.insert()
        |> case do
          {:ok, goal} -> {:ok, {:created, goal.id}}
          {:error, changeset} -> {:error, {:goal, changeset.errors}}
        end
    end
  end

  defp runtime_report(%Agent{kind: "external"}), do: %{kind: :external}

  defp runtime_report(%Agent{} = agent) do
    case runtime(agent) do
      %AgentRuntime{} = runtime ->
        names = safe_tool_names(runtime)

        %{
          kind: if(runtime.managed_by == "install", do: :native, else: :federated),
          harness: runtime.harness,
          missing_tools: Enum.reject(@required_tools, &(&1 in names))
        }

      nil ->
        %{kind: :no_runtime}
    end
  end

  defp runtime(%Agent{runtime_id: id}) when is_binary(id), do: Federation.get_runtime(id)
  defp runtime(_agent), do: nil

  defp safe_tool_names(runtime) do
    Tools.tool_names(runtime)
  rescue
    _ -> []
  end

  # ── tool grants ──

  # The bundles and permissions `required_tools/0` need on this agent's
  # runtime that its profile does not carry. With `apply?` they are added
  # (`granted`), else reported (`grants_needed`). An external agent or one
  # with no runtime has nothing to grant.
  defp grant_tools(%Agent{kind: "external"}, _apply?), do: %{}

  defp grant_tools(%Agent{} = agent, apply?) do
    with %AgentRuntime{} = runtime <- runtime(agent),
         %RuntimeProfile{} = profile <- RuntimeProfiles.get(runtime) do
      needed = grants_needed(runtime, profile)

      cond do
        needed == %{bundles: [], permissions: []} ->
          %{grants_needed: needed}

        apply? ->
          case apply_grants(runtime, profile, needed) do
            :ok -> %{granted: needed}
            {:error, reason} -> %{grants_needed: needed, grant_error: inspect(reason)}
          end

        true ->
          %{grants_needed: needed}
      end
    else
      _ -> %{}
    end
  end

  defp grants_needed(runtime, profile) do
    bundles = RuntimeProfiles.tool_profile(runtime, profile)
    restriction = RuntimeProfiles.restrictions(runtime, profile)
    by_name = Map.new(ToolSurface.tool_definitions(), &{&1.name, &1.bundle})

    missing_bundles =
      @required_tools
      |> Enum.map(&Map.get(by_name, &1))
      |> Enum.reject(&(is_nil(&1) or &1 in bundles))
      |> Enum.uniq()

    missing_permissions =
      case restriction do
        nil ->
          []

        restriction ->
          @required_tools
          |> Enum.map(&ToolPermissions.for_tool/1)
          |> Enum.reject(&(is_nil(&1) or &1 in @never_grant or Map.has_key?(restriction, &1)))
          |> Enum.uniq()
      end

    %{bundles: Enum.sort(missing_bundles), permissions: Enum.sort(missing_permissions)}
  end

  defp apply_grants(runtime, profile, %{bundles: bundles, permissions: permissions}) do
    with {:ok, _} <- maybe_add_bundles(runtime, profile, bundles),
         {:ok, _} <- maybe_add_permissions(runtime, profile, permissions) do
      :ok
    end
  end

  defp maybe_add_bundles(_runtime, _profile, []), do: {:ok, :unchanged}

  defp maybe_add_bundles(runtime, profile, bundles) do
    RuntimeProfiles.set_tool_profile(
      runtime,
      RuntimeProfiles.tool_profile(runtime, profile) ++ bundles
    )
  end

  defp maybe_add_permissions(_runtime, _profile, []), do: {:ok, :unchanged}

  defp maybe_add_permissions(runtime, _profile, permissions) do
    # Re-read: the bundle write above replaced the profile row.
    current = RuntimeProfiles.restrictions(runtime) || %{}
    RuntimeProfiles.restrict(runtime, Map.merge(current, Map.new(permissions, &{&1, "all"})))
  end

  defp warnings(_agent, %{kind: :external}), do: [@external_warning]

  defp warnings(_agent, %{kind: :no_runtime}) do
    [
      "the agent has no runtime yet: create a Claude Code runtime for it, then re-run " <>
        "provision/1 to grant and check its tools"
    ]
  end

  defp warnings(_agent, %{missing_tools: missing} = runtime) do
    tools =
      if missing == [],
        do: [],
        else: [
          "the runtime is missing designer tools: #{Enum.join(missing, ", ")}; " <>
            missing_hint(runtime)
        ]

    tools ++ grant_error(runtime)
  end

  defp missing_hint(%{grants_needed: %{bundles: b, permissions: p}}) when b != [] or p != [],
    do:
      "grant bundles [#{Enum.join(b, ", ")}] and permissions [#{Enum.join(p, ", ")}] " <>
        "(re-run provision/1 without apply_grants: false)"

  defp missing_hint(_runtime),
    do:
      "the bundles and restrict-grants are in place, so the runtime's owner lacks the " <>
        "permission; use an owner who holds it"

  defp grant_error(%{grant_error: reason}), do: ["applying tool grants failed: #{reason}"]
  defp grant_error(_runtime), do: []
end
