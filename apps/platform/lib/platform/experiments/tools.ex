defmodule Platform.Experiments.Tools do
  @moduledoc """
  The behaviour behind the `experiments` MCP bundle (task 01a0d415 stage 2,
  the experimentation-layer ADR-0052). `Platform.Federation.ToolSurface` routes
  every `experiment_*` tool name here with one prefix clause; the
  definitions are in `Platform.Federation.ExperimentTools`. Every argument
  check, org check and error envelope lives in this module, not in
  `tool_surface.ex`.

  ## Reachability

  The bundle is not a default grant. A runtime without `experiments` in its
  `allowed_bundles` is refused by `Platform.Federation.ToolAuthorization`
  before `execute/3` runs — so the Scientist's runtime needs the grant, or
  every tool here is refused. `ToolSurface.execute/3` itself is `@doc false`
  and does not re-check bundles; the transports do.

  ## Tenancy

  Mirrors `mail_draft_create`'s org check (`authorize_org_filter/2` in
  `ToolSurface`): an agent whose `metadata["org_id"]` pins it to a TENANT org
  may only write experiments and goals in that org, and may read its own
  org's rows plus install-wide ones (org_id null). Only a root-equivalent
  caller (no pin, or pinned to the root org) may create an install-wide
  experiment. A sibling org's experiment answers not-found, so existence is
  not disclosed.

  ## What an agent can and cannot do here

  Every write goes through the context and the guardrails
  (`Platform.Experiments.Guardrails`): create is born `draft` (status is
  never read from args), start runs the locked guardrail check, promote is
  refused unless the org allows it. There is no approval tool (a human
  approves in the UI), no delete, no un-exclude, and no send.
  """

  import Ecto.Query

  require Logger

  alias Platform.Agents.Agent
  alias Platform.Experiments
  alias Platform.Experiments.Assignments
  alias Platform.Experiments.Experiment
  alias Platform.Experiments.Goal
  alias Platform.Experiments.Guardrails
  alias Platform.Experiments.Promotion
  alias Platform.Experiments.Results
  alias Platform.Experiments.Signals
  alias Platform.Experiments.Surfaces
  alias Platform.Experiments.Variant
  alias Platform.Federation.ExperimentTools
  alias Platform.Repo
  alias Platform.Tenancy.Org

  @prompt_surface "dispatch.prompt"
  @default_limit 50
  @max_limit 200
  @max_feedback 4000
  @max_reason 500

  @doc "Executes one `experiment_*` tool. See the moduledoc."
  @spec execute(String.t(), map(), map()) :: {:ok, map()} | {:error, map()}
  def execute(tool, args, context) when is_map(args) do
    caller = caller(context)
    run(tool, args, caller)
  rescue
    error ->
      Logger.error("[Experiments.Tools] #{tool} raised: #{Exception.message(error)}")
      err(tool, :internal_error, "internal error", false, "Report this; do not retry blindly.")
  end

  def execute(tool, _args, _context),
    do: err(tool, :invalid_arguments, "arguments must be an object", true, "Pass a JSON object.")

  # ── dispatch ────────────────────────────────────────────────────────────

  defp run("experiment_surface_list", _args, _caller) do
    {:ok,
     %{
       surfaces:
         Enum.map(Surfaces.list(), fn surface ->
           %{
             key: surface.key(),
             subject_type: surface.subject_type(),
             path: to_string(surface.path()),
             payload_schema: surface.payload_schema(),
             targets: surface_targets(surface)
           }
         end)
     }}
  end

  defp run("experiment_list", args, caller) do
    with {:ok, limit} <- limit(args),
         {:ok, query} <- list_filters(from(e in Experiment), args) do
      experiments =
        query
        |> visible(caller)
        |> order_by([e], desc: e.inserted_at, desc: e.id)
        |> limit(^limit)
        |> Repo.all()

      {:ok,
       %{
         count: length(experiments),
         limit: limit,
         experiments: Enum.map(experiments, &serialize/1)
       }}
    end
  end

  defp run("experiment_get", args, caller) do
    with {:ok, experiment} <- fetch_visible("experiment_get", args, caller) do
      variants =
        experiment
        |> Experiments.list_variants()
        |> Enum.map(&serialize_variant(experiment, &1))

      {:ok, %{experiment: experiment |> serialize() |> Map.put(:variants, variants)}}
    end
  end

  defp run("experiment_create", args, caller) do
    tool = "experiment_create"

    with {:ok, surface} <- registered_surface(tool, Map.get(args, "surface_key")),
         {:ok, name} <- required_string(tool, args, "name"),
         {:ok, target} <- required_string(tool, args, "surface_target"),
         :ok <- known_target(tool, surface, target),
         {:ok, org_id, project_id} <- tenancy(tool, args),
         :ok <- authorize_write(tool, caller, org_id),
         probe = %Experiment{surface_key: surface.key(), org_id: org_id, project_id: project_id},
         :ok <- guard(tool, Guardrails.check(:create, probe, actor(caller))) do
      attrs =
        args
        |> Map.take(ExperimentTools.arg_keys())
        |> Map.merge(%{
          "surface_key" => surface.key(),
          "surface_target" => target,
          "name" => name,
          "slug" => Map.get(args, "slug") || slug_for(name),
          "org_id" => org_id,
          "project_id" => project_id,
          "proposed_by_agent_id" => caller.agent && caller.agent.id
        })

      case Experiments.create_experiment(attrs) do
        {:ok, experiment} -> {:ok, %{experiment: serialize(experiment)}}
        {:error, changeset} -> changeset_err(tool, changeset)
      end
    end
  end

  defp run("experiment_variant_add", args, caller) do
    tool = "experiment_variant_add"

    with {:ok, experiment} <- fetch_writable(tool, args, caller),
         :ok <- require_status(tool, experiment, ["draft"]),
         {:ok, slug} <- required_string(tool, args, "slug"),
         :ok <- not_control(tool, slug),
         {:ok, surface} <- registered_surface(tool, experiment.surface_key),
         {:ok, payload} <- validate_payload(tool, surface, Map.get(args, "payload")) do
      attrs =
        %{
          "slug" => slug,
          "payload" => payload,
          "weight" => Map.get(args, "weight", 1)
        }
        |> maybe_put_content(experiment, payload)

      case Experiments.add_variant(experiment, attrs) do
        {:ok, variant} -> {:ok, %{variant: serialize_variant(experiment, variant)}}
        {:error, changeset} -> changeset_err(tool, changeset)
      end
    end
  end

  defp run("experiment_start", args, caller) do
    tool = "experiment_start"

    with {:ok, experiment} <- fetch_writable(tool, args, caller) do
      case Experiments.start(experiment, actor(caller)) do
        {:ok, :pending_human_approval} ->
          {:ok,
           %{
             result: "pending_human_approval",
             experiment: serialize(Repo.get!(Experiment, experiment.id))
           }}

        {:ok, %Experiment{} = running} ->
          {:ok, %{result: "running", experiment: serialize(running)}}

        {:error, reason} ->
          start_err(tool, reason)
      end
    end
  end

  defp run("experiment_stop", args, caller) do
    tool = "experiment_stop"

    with {:ok, experiment} <- fetch_writable(tool, args, caller),
         :ok <- require_status(tool, experiment, ["running", "draft"]),
         {:ok, feedback} <- optional_text(tool, args, "feedback", @max_feedback) do
      case Experiments.stop(experiment, %{stop_feedback: feedback}) do
        {:ok, stopped} -> {:ok, %{experiment: serialize(stopped)}}
        {:error, changeset} -> changeset_err(tool, changeset)
      end
    end
  end

  defp run("experiment_conclude", args, caller) do
    tool = "experiment_conclude"

    with {:ok, experiment} <- fetch_writable(tool, args, caller),
         :ok <- require_status(tool, experiment, ["running"]) do
      case Experiments.conclude(experiment) do
        {:ok, concluded} -> {:ok, %{experiment: serialize(concluded)}}
        {:error, changeset} -> changeset_err(tool, changeset)
      end
    end
  end

  defp run("experiment_results", args, caller) do
    with {:ok, experiment} <- fetch_visible("experiment_results", args, caller) do
      {:ok,
       %{
         experiment_id: experiment.id,
         rows: experiment |> Results.rows() |> Enum.map(&serialize_row/1)
       }}
    end
  end

  defp run("experiment_signals_list", args, caller) do
    with {:ok, experiment} <- fetch_visible("experiment_signals_list", args, caller) do
      opts =
        case Map.get(args, "status") do
          status when is_binary(status) and status != "" -> [status: status]
          _ -> []
        end

      signals =
        experiment
        |> Signals.list(opts)
        |> Enum.map(fn signal ->
          # These five fields ONLY. The source row (an inbound mail) is never
          # read or returned: the Scientist acts on labels, not content.
          %{
            label: signal.label,
            subject_id: signal.subject_id,
            confidence: signal.confidence,
            reason: signal.reason,
            status: signal.status
          }
        end)

      {:ok, %{count: length(signals), signals: signals}}
    end
  end

  defp run("experiment_exclude", args, caller) do
    tool = "experiment_exclude"

    with {:ok, experiment} <- fetch_writable(tool, args, caller),
         {:ok, subject_id} <- required_uuid(tool, args, "subject_id"),
         {:ok, reason} <- required_string(tool, args, "reason"),
         :ok <- max_length(tool, "reason", reason, @max_reason) do
      subject_type = Map.get(args, "subject_type") || "task"

      case Assignments.exclude(experiment, {subject_type, subject_id}, reason) do
        {:ok, assignment} ->
          {:ok,
           %{
             assignment: %{
               subject_type: assignment.subject_type,
               subject_id: assignment.subject_id,
               variant_slug: assignment.variant_slug,
               excluded_reason: assignment.excluded_reason
             }
           }}

        {:error, :not_assigned} ->
          err(
            tool,
            :not_assigned,
            "that subject was never assigned to this experiment",
            false,
            "Only an assigned subject can be excluded."
          )

        {:error, changeset} ->
          changeset_err(tool, changeset)
      end
    end
  end

  defp run("experiment_goal_set", args, caller) do
    tool = "experiment_goal_set"

    case Map.get(args, "goal_id") do
      id when is_binary(id) and id != "" -> update_goal(tool, id, args, caller)
      _ -> create_goal(tool, args, caller)
    end
  end

  defp run("experiment_goal_list", args, caller) do
    query =
      from(g in Goal, order_by: [desc: g.inserted_at, desc: g.id], limit: @max_limit)
      |> maybe_where_status(Map.get(args, "status"))

    with {:ok, query} <- maybe_where_org(query, Map.get(args, "org_id")) do
      goals = query |> visible(caller) |> Repo.all() |> Enum.map(&serialize_goal/1)
      {:ok, %{count: length(goals), goals: goals}}
    end
  end

  defp run("experiment_promote", args, caller) do
    tool = "experiment_promote"

    with {:ok, experiment} <- fetch_writable(tool, args, caller),
         {:ok, variant_slug} <- required_string(tool, args, "variant"),
         :ok <- guard(tool, Guardrails.check(:promote, experiment, actor(caller))) do
      row = Enum.find(Results.rows(experiment), &(&1.variant_slug == variant_slug))

      opts = [
        variant: variant_slug,
        trigger: :agent,
        actor_type: "agent",
        actor_id: caller.agent && caller.agent.id,
        effect: row && row.value,
        n: row && row.n
      ]

      case Promotion.promote(experiment, opts) do
        {:ok, %{default: default}} ->
          {:ok,
           %{
             promoted: true,
             surface_key: default.surface_key,
             surface_target: default.surface_target,
             seq: default.seq
           }}

        {:ok, %{template: template}} ->
          {:ok, %{promoted: true, surface_key: @prompt_surface, template_slug: template.slug}}

        {:error, reason} ->
          promote_err(tool, reason)
      end
    end
  end

  defp run(tool, _args, _caller) do
    err(
      tool,
      :unknown_tool,
      "unknown experiments tool",
      false,
      "Available: " <> Enum.map_join(ExperimentTools.definitions(), ", ", & &1.name)
    )
  end

  # ── goals ───────────────────────────────────────────────────────────────

  defp create_goal(tool, args, caller) do
    with {:ok, statement} <- required_string(tool, args, "statement"),
         {:ok, org_id, project_id} <- tenancy(tool, args),
         :ok <- authorize_write(tool, caller, org_id) do
      %Goal{}
      |> Goal.changeset(%{
        "statement" => statement,
        "metric_spec" => Map.get(args, "metric_spec") || %{},
        "status" => Map.get(args, "status") || "active",
        "org_id" => org_id,
        "project_id" => project_id
      })
      |> Repo.insert()
      |> case do
        {:ok, goal} -> {:ok, %{goal: serialize_goal(goal)}}
        {:error, changeset} -> changeset_err(tool, changeset)
      end
    end
  end

  defp update_goal(tool, id, args, caller) do
    goal = if Platform.UUID.valid?(id), do: Repo.get(Goal, id)

    with %Goal{} <- goal,
         :ok <- authorize_write(tool, caller, goal.org_id) do
      attrs = Map.take(args, ["statement", "metric_spec", "status"])

      goal
      |> Goal.changeset(attrs)
      |> Repo.update()
      |> case do
        {:ok, goal} -> {:ok, %{goal: serialize_goal(goal)}}
        {:error, changeset} -> changeset_err(tool, changeset)
      end
    else
      nil -> not_found(tool, "goal")
      {:error, %{code: :unauthorized}} -> not_found(tool, "goal")
      {:error, _} = error -> error
    end
  end

  # ── caller, tenancy and access ──────────────────────────────────────────

  defp caller(context) do
    agent = load_agent(context)
    %{agent: agent, home: home_org(agent)}
  end

  defp load_agent(context) when is_map(context) do
    case Map.get(context, :agent) do
      %Agent{} = agent ->
        agent

      _ ->
        case Map.get(context, :agent_id) do
          id when is_binary(id) -> if Platform.UUID.valid?(id), do: Repo.get(Agent, id)
          _ -> nil
        end
    end
  end

  defp load_agent(_context), do: nil

  @doc """
  The tenancy home of an agent: `:root` or `{:tenant, org_id}`.

  Same resolution as `ToolSurface.agent_home_org/1`: no pin, or a pin to
  the root org, is root-equivalent. Public so the Scientist's context
  (`Handlers.ExperimentsScientist.gather_context/1`) applies the SAME check
  as these tools rather than a second one that could drift from it.
  """
  @spec home_org(Agent.t() | nil) :: :root | {:tenant, Ecto.UUID.t()}
  def home_org(%Agent{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, "org_id") || Map.get(metadata, :org_id) do
      org_id when is_binary(org_id) and org_id != "" ->
        case Platform.UUID.valid?(org_id) && Repo.get(Org, org_id) do
          %Org{parent_org_id: nil} -> :root
          %Org{} -> {:tenant, org_id}
          _ -> :root
        end

      _ ->
        :root
    end
  end

  def home_org(_agent), do: :root

  defp actor(%{agent: %Agent{} = agent}), do: agent
  defp actor(_caller), do: :agent

  defp authorize_write(_tool, %{home: :root}, _org_id), do: :ok
  defp authorize_write(_tool, %{home: {:tenant, org_id}}, org_id), do: :ok

  defp authorize_write(tool, %{home: {:tenant, _home}}, nil) do
    err(
      tool,
      :unauthorized,
      "unauthorized: only an unpinned runtime may write install-wide (org_id null) rows",
      false,
      "Pass your own org_id, or a project_id in your org."
    )
  end

  defp authorize_write(tool, %{home: {:tenant, _home}}, org_id) do
    err(
      tool,
      :unauthorized,
      "unauthorized: not a member of org #{org_id}",
      false,
      "Tenant-pinned agents may only write in their own org."
    )
  end

  defp visible(query, %{home: :root}), do: query

  defp visible(query, %{home: {:tenant, org_id}}),
    do: where(query, [r], is_nil(r.org_id) or r.org_id == ^org_id)

  defp can_read?(%{home: :root}, _org_id), do: true
  defp can_read?(%{home: {:tenant, _}}, nil), do: true
  defp can_read?(%{home: {:tenant, org_id}}, org_id), do: true
  defp can_read?(_caller, _org_id), do: false

  defp fetch_visible(tool, args, caller) do
    with {:ok, experiment} <- fetch(tool, args) do
      if can_read?(caller, experiment.org_id),
        do: {:ok, experiment},
        else: not_found(tool, "experiment")
    end
  end

  defp fetch_writable(tool, args, caller) do
    with {:ok, experiment} <- fetch_visible(tool, args, caller),
         :ok <- authorize_write(tool, caller, experiment.org_id) do
      {:ok, experiment}
    end
  end

  defp fetch(tool, args) do
    with {:ok, id} <- required_uuid(tool, args, "experiment_id") do
      case Repo.get(Experiment, id) do
        nil -> not_found(tool, "experiment")
        experiment -> {:ok, experiment}
      end
    end
  end

  # org_id / project_id from args. The org is derived from the project when
  # absent; a mismatch is refused here so the tenancy check below judges the
  # org the row will actually carry.
  defp tenancy(tool, args) do
    with {:ok, org_id} <- optional_uuid(tool, args, "org_id"),
         {:ok, project_id} <- optional_uuid(tool, args, "project_id") do
      case project_id && Repo.get(Platform.Tasks.Project, project_id) do
        nil when is_binary(project_id) ->
          not_found(tool, "project")

        nil ->
          {:ok, org_id, nil}

        %{org_id: project_org} when is_nil(org_id) or org_id == project_org ->
          {:ok, project_org, project_id}

        _mismatch ->
          err(
            tool,
            :invalid_arguments,
            "project does not belong to org",
            true,
            "Omit org_id; it is derived from project_id."
          )
      end
    end
  end

  # ── validation helpers ──────────────────────────────────────────────────

  defp registered_surface(tool, key) do
    case Surfaces.get(key) do
      nil ->
        err(
          tool,
          :unknown_surface,
          "unknown surface #{inspect(key)}",
          true,
          "Call experiment_surface_list; known: " <>
            Enum.map_join(Surfaces.list(), ", ", & &1.key())
        )

      surface ->
        {:ok, surface}
    end
  end

  # nil = the surface declares no fixed target set (e.g. `dispatch.prompt`,
  # whose target is any template slug).
  defp surface_targets(surface) do
    if function_exported?(surface, :targets, 0), do: surface.targets(), else: nil
  end

  defp known_target(tool, surface, target) do
    case surface_targets(surface) do
      nil ->
        :ok

      targets ->
        if target in targets do
          :ok
        else
          err(
            tool,
            :unknown_surface_target,
            "#{surface.key()} is resolved only at #{Enum.join(targets, ", ")}; " <>
              "#{inspect(target)} would never assign a subject",
            true,
            "Use surface_target #{Enum.map_join(targets, " or ", &inspect/1)}."
          )
        end
    end
  end

  defp validate_payload(tool, surface, payload) when is_map(payload) do
    case surface.validate_payload(payload) do
      {:ok, normalized} ->
        {:ok, normalized}

      {:error, reasons} ->
        {:error,
         %{
           error: "#{tool}: payload does not match #{surface.key()}",
           code: :invalid_payload,
           errors: reasons,
           recoverable: true,
           suggestion: "Shape the payload to the surface's payload_schema."
         }}
    end
  end

  defp validate_payload(tool, _surface, _payload),
    do: err(tool, :invalid_payload, "`payload` must be an object", true, "Pass an object.")

  # The prompt surface's blob also lives in `content`, which the prompt read
  # point and `Promotion` read.
  defp maybe_put_content(attrs, %Experiment{surface_key: @prompt_surface}, %{"content" => c}),
    do: Map.put(attrs, "content", c)

  defp maybe_put_content(attrs, _experiment, _payload), do: attrs

  defp not_control(tool, "control") do
    err(
      tool,
      :reserved_slug,
      "the slug \"control\" is reserved",
      true,
      "The control arm is captured at experiment_start; pick another slug."
    )
  end

  defp not_control(_tool, _slug), do: :ok

  defp require_status(tool, %Experiment{status: status}, allowed) do
    if status in allowed do
      :ok
    else
      err(
        tool,
        :invalid_status,
        "experiment is #{status}; this needs #{Enum.join(allowed, " or ")}",
        false,
        "Read experiment_get for its current status."
      )
    end
  end

  defp required_string(tool, args, key) do
    case Map.get(args, key) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: missing(tool, key), else: {:ok, value}

      _ ->
        missing(tool, key)
    end
  end

  defp required_uuid(tool, args, key) do
    with {:ok, value} <- required_string(tool, args, key) do
      if Platform.UUID.valid?(value), do: {:ok, value}, else: bad_uuid(tool, key)
    end
  end

  defp optional_uuid(tool, args, key) do
    case Map.get(args, key) do
      nil ->
        {:ok, nil}

      "" ->
        {:ok, nil}

      value when is_binary(value) ->
        if Platform.UUID.valid?(value), do: {:ok, value}, else: bad_uuid(tool, key)

      _ ->
        bad_uuid(tool, key)
    end
  end

  defp optional_text(tool, args, key, max) do
    case Map.get(args, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        with :ok <- max_length(tool, key, value, max) do
          {:ok, if(String.trim(value) == "", do: nil, else: value)}
        end

      _ ->
        err(tool, :invalid_arguments, "`#{key}` must be a string", true, "Pass a string.")
    end
  end

  defp max_length(tool, key, value, max) do
    if String.length(value) <= max,
      do: :ok,
      else:
        err(tool, :invalid_arguments, "`#{key}` is over #{max} characters", true, "Shorten it.")
  end

  defp limit(args) do
    case Map.get(args, "limit") do
      nil ->
        {:ok, @default_limit}

      n when is_integer(n) and n > 0 ->
        {:ok, min(n, @max_limit)}

      _ ->
        err(
          "experiment_list",
          :invalid_arguments,
          "`limit` must be a positive integer",
          true,
          "Pass an integer."
        )
    end
  end

  defp list_filters(query, args) do
    query = maybe_where_status(query, Map.get(args, "status"))

    with {:ok, query} <- maybe_where_org(query, Map.get(args, "org_id")),
         {:ok, project_id} <- optional_uuid("experiment_list", args, "project_id") do
      if project_id,
        do: {:ok, where(query, [e], e.project_id == ^project_id)},
        else: {:ok, query}
    end
  end

  defp maybe_where_status(query, status) when is_binary(status) and status != "",
    do: where(query, [r], r.status == ^status)

  defp maybe_where_status(query, _status), do: query

  defp maybe_where_org(query, org_id) when is_binary(org_id) and org_id != "" do
    if Platform.UUID.valid?(org_id),
      do: {:ok, where(query, [r], r.org_id == ^org_id)},
      else: bad_uuid("experiment_list", "org_id")
  end

  defp maybe_where_org(query, _org_id), do: {:ok, query}

  defp slug_for(name) do
    base =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 48)

    suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    if base == "", do: "exp-" <> suffix, else: base <> "-" <> suffix
  end

  # ── serialization ───────────────────────────────────────────────────────

  defp serialize(%Experiment{} = e) do
    %{
      id: e.id,
      slug: e.slug,
      name: e.name,
      hypothesis: e.hypothesis,
      status: e.status,
      approval_state: e.approval_state,
      surface_key: e.surface_key,
      surface_target: e.surface_target,
      org_id: e.org_id,
      project_id: e.project_id,
      goal_id: e.goal_id,
      metric_spec: e.metric_spec,
      primary_metric: e.primary_metric,
      assignment_policy: e.assignment_policy,
      signal_source: e.signal_source,
      observation_window_days: e.observation_window_days,
      stop_rule: e.stop_rule,
      proposed_by_agent_id: e.proposed_by_agent_id,
      stop_feedback: e.stop_feedback,
      stopped_by_user_id: e.stopped_by_user_id,
      stopped_at: e.stopped_at,
      inserted_at: e.inserted_at
    }
  end

  defp serialize_variant(experiment, %Variant{} = variant) do
    surface = Surfaces.get(experiment.surface_key)

    payload =
      if surface && function_exported?(surface, :variant_payload, 1),
        do: surface.variant_payload(variant),
        else: variant.payload

    %{slug: variant.slug, weight: variant.weight, payload: payload}
  end

  defp serialize_row(row) do
    %{
      variant_slug: row.variant_slug,
      # nil unless earned — `Results` refuses to carry a value otherwise.
      value: row.value,
      n: row.n,
      pending: Map.get(row, :pending, 0),
      excluded: row.excluded,
      subjects: row.subjects,
      min_subjects: row.min_subjects,
      reason: to_string(row.reason)
    }
  end

  defp serialize_goal(%Goal{} = goal) do
    %{
      id: goal.id,
      statement: goal.statement,
      metric_spec: goal.metric_spec,
      status: goal.status,
      org_id: goal.org_id,
      project_id: goal.project_id
    }
  end

  # ── error envelopes ─────────────────────────────────────────────────────

  defp error_value(value) when is_binary(value), do: value
  defp error_value(value) when is_atom(value) or is_number(value), do: to_string(value)
  defp error_value(value), do: inspect(value)

  defp err(tool, code, message, recoverable, suggestion) do
    {:error,
     %{
       error: "#{tool}: #{message}",
       code: code,
       recoverable: recoverable,
       suggestion: suggestion
     }}
  end

  defp missing(tool, key),
    do: err(tool, :"missing_#{key}", "`#{key}` is required", true, "Provide `#{key}`.")

  defp bad_uuid(tool, key),
    do: err(tool, :invalid_arguments, "`#{key}` must be a UUID", true, "Pass a UUID string.")

  defp not_found(tool, what),
    do: err(tool, :not_found, "#{what} not found", false, "Check the id.")

  defp guard(_tool, :ok), do: :ok
  defp guard(tool, {:error, %Guardrails.Refusal{} = refusal}), do: refusal_err(tool, refusal)

  defp refusal_err(tool, %Guardrails.Refusal{} = refusal) do
    {:error,
     %{
       error: "#{tool}: refused by guardrails (#{refusal.code})",
       code: refusal.code,
       refusal: %{
         code: refusal.code,
         limit: refusal.limit,
         current: refusal.current,
         surface: refusal.surface
       },
       recoverable: false,
       suggestion:
         "This is a guardrail, not a fault. Do not retry; stop another experiment, pick an allowed surface, or ask a person to change the guardrails."
     }}
  end

  defp start_err(tool, %Guardrails.Refusal{} = refusal), do: refusal_err(tool, refusal)

  defp start_err(tool, :not_draft),
    do: err(tool, :invalid_status, "only a draft can be started", false, "Read experiment_get.")

  defp start_err(tool, :unknown_surface),
    do:
      err(
        tool,
        :unknown_surface,
        "the experiment's surface is not registered",
        false,
        "Create a new experiment on a listed surface."
      )

  defp start_err(tool, %Ecto.Changeset{} = changeset), do: changeset_err(tool, changeset)

  defp start_err(tool, reason),
    do:
      err(
        tool,
        :start_failed,
        "could not capture the control: #{inspect(reason)}",
        false,
        "Check the surface_target exists."
      )

  defp promote_err(tool, %Promotion.Refusal{} = refusal) do
    {:error,
     %{
       error: "#{tool}: refused (#{refusal.reason})",
       code: refusal.reason,
       refusal:
         refusal
         |> Map.from_struct()
         |> Map.delete(:message),
       recoverable: false,
       suggestion: "Read experiment_results; do not retry until the refusal's condition changes."
     }}
  end

  defp promote_err(tool, :concurrent_promotion),
    do:
      err(
        tool,
        :concurrent_promotion,
        "another promotion landed first",
        false,
        "Re-read the current default before deciding again."
      )

  defp promote_err(tool, %Ecto.Changeset{} = changeset), do: changeset_err(tool, changeset)

  defp promote_err(tool, reason) when is_atom(reason),
    do: err(tool, reason, "promotion refused: #{reason}", false, "Read experiment_get.")

  defp promote_err(tool, reason),
    do:
      err(
        tool,
        :promotion_failed,
        "promotion failed: #{inspect(reason)}",
        false,
        "Read experiment_get."
      )

  defp changeset_err(tool, %Ecto.Changeset{} = changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
        Enum.reduce(opts, message, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", fn _ -> error_value(value) end)
        end)
      end)

    {:error,
     %{
       error: "#{tool}: invalid",
       code: :invalid,
       errors: errors,
       recoverable: true,
       suggestion: "Fix the listed fields and call again."
     }}
  end
end
