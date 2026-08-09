defmodule Platform.Lifecycle.PipelineConfig do
  @moduledoc """
  Validation and reading of a per-project lifecycle hook pipeline
  (ADR-0046 Amendment 1, task 019fe1b6 stage 2).

  Pure functions over a plain map decoded from jsonb. No process, no
  Ecto schema, and — deliberately — nothing that runs a step. The
  pipeline runner is a later member of this stack.

  ## Shape

      %{
        "planning.entered" => [
          %{"step" => "notify", "await" => false, "can_divert" => false}
        ]
      }

  Keys are **strings throughout**, because this round-trips through the
  `Platform.Tasks.Project` jsonb `config` column. Atom keys are not
  accepted: a map that validated as atoms would stop validating the
  moment it made a round trip through the database, which is the worst
  possible time to find out.

  A webhook step carries an additional `"url"`.

  ## `await` and `can_divert` are per-step data, and are REQUIRED

  Both keys must be present on every step and must be actual booleans.
  A missing key is an error. A truthy string like `"true"` is an error.

  ADR-0046 Amendment 1 decision 3 settles that these are declared per
  step and never inferred from position. The rationale is worth
  restating where the code lives: if divert authority came from being
  first in the pipeline, then someone inserting a notify at the top of
  a pipeline six months from now would silently demote a gate to
  advisory. No error, no failing test, no visible change — the gate
  would still be dispatched and its verdict would simply stop being
  able to stop anything.

  Defaulting a missing `can_divert` to `false` reintroduces exactly that
  silence by another door: a step author who forgot the key gets a gate
  that never gates, and nothing tells them. That is why the keys are
  required rather than defaulted.

  ## Security: a step name is data, never code

  `validate/2` resolves a step name through `StepRegistry` **by name
  only**. See the comment at the resolution site in `validate_step_name/3`.
  The registry is an allowlist, not an existence check: a module that
  exists and is loaded in the VM is still rejected unless it was
  registered. There is no module lookup, no `String.to_existing_atom/1`,
  and no `Code.ensure_loaded?/1` admission path.

  Webhook destinations are checked against
  `StepRegistry.webhook_host_allowed?/1`, which closes the same hole on
  the network side — otherwise a pipeline is an SSRF primitive driven
  by agent-authored configuration.

  ## Org defaults are deferred

  This module implements the **per-project half only**. That needs no
  migration: `Platform.Tasks.Project` already carries a jsonb `config`
  column.

  Org-level defaults are deliberately not implemented. ADR-0046
  Amendment 1 records the blocking question as unresolved: orgs are
  hierarchical (`parent_org_id`), and when a child org and its parent
  both define a pipeline for the same edge, the amendment does not say
  whether the child inherits, replaces, or whether org-tier inheritance
  is disallowed outright. Each answer implies a different migration.

  When org defaults do land, decision 8 records the intended semantics:
  a project's configuration **replaces** the org's for that edge,
  wholesale — no merge, no inheritance chain, no `locked` flag. That is
  recorded here as intent, not as behaviour: nothing in this module
  merges or inherits anything.

  ## Error contract

  `validate/2` returns `:ok` or `{:error, reason_binary}`, mirroring
  `Platform.Tasks.DeployStageBuilder.validate_strategy/1` — which
  `Platform.Tasks.Project.validate_deploy_strategy/1` consumes by
  piping the reason into `add_error/3`. Keeping the shapes identical is
  what lets the changeset wiring look the same.

  Every rule produces its **own distinct message**. A shared
  "invalid pipeline" would make the failures indistinguishable to a
  caller and to a test, which is the same discrimination-loss failure
  this ADR is written against.
  """

  alias Platform.Lifecycle.StepRegistry

  # ADR-0046 Amendment 1 decision 6: ticket creation is agent-paced and
  # bursty, so this edge accepts effects and notifies only. A gate here
  # lets one agent's hook block another agent from filing a ticket.
  @no_gate_edges ["backlog.created"]

  @doc """
  Validate a decoded pipeline map.

  `registry` is the `StepRegistry` server to resolve step names
  against; it defaults to the boot singleton. Tests pass a per-case
  instance.
  """
  @spec validate(term(), GenServer.server()) :: :ok | {:error, String.t()}
  def validate(pipeline, registry \\ StepRegistry)

  def validate(pipeline, registry) when is_map(pipeline) do
    Enum.reduce_while(pipeline, :ok, fn {edge, steps}, :ok ->
      case validate_edge(edge, steps, registry) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  def validate(_pipeline, _registry) do
    {:error, "pipeline must be a map of edge name => list of steps"}
  end

  @doc """
  The ordered step list configured for one edge.

  Returns `[]` when the edge is absent or its value is not a list.
  Reading is not validation — call `validate/2` before persisting.
  """
  @spec steps_for(term(), term()) :: [map()]
  def steps_for(pipeline, edge) when is_map(pipeline) and is_binary(edge) do
    case Map.get(pipeline, edge) do
      steps when is_list(steps) -> steps
      _other -> []
    end
  end

  def steps_for(_pipeline, _edge), do: []

  # ── edge-level ────────────────────────────────────────────────────────────

  defp validate_edge(edge, _steps, _registry) when not is_binary(edge) do
    {:error, "edge name must be a string, got: #{inspect(edge)}"}
  end

  defp validate_edge(edge, steps, registry) when is_list(steps) do
    steps
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {step, index}, :ok ->
      case validate_step(step, edge, index, registry) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_edge(edge, steps, _registry) do
    {:error, "edge #{inspect(edge)}: steps must be a list, got: #{inspect(steps)}"}
  end

  # ── step-level ────────────────────────────────────────────────────────────

  defp validate_step(step, edge, index, registry) when is_map(step) do
    with :ok <- validate_step_name(step, at(edge, index), registry),
         :ok <- validate_flag(step, "await", at(edge, index)),
         :ok <- validate_flag(step, "can_divert", at(edge, index)),
         :ok <- validate_no_gate_edge(step, edge, at(edge, index)) do
      validate_webhook_url(step, at(edge, index))
    end
  end

  defp validate_step(step, edge, index, _registry) do
    {:error, "#{at(edge, index)}: step must be a map, got: #{inspect(step)}"}
  end

  defp validate_step_name(step, where, registry) do
    case Map.get(step, "step") do
      name when is_binary(name) ->
        # SECURITY — do NOT "helpfully" add a module-lookup fallback here.
        #
        # A step name arrives from project configuration, which is
        # agent-authored. It is resolved through the registry allowlist
        # BY NAME ONLY. Never `String.to_existing_atom/1` it, never
        # `Code.ensure_loaded?/1` it as an admission test, never
        # `apply/3` anything derived from it. Any of those turns an
        # ordinary-looking config field into arbitrary code execution.
        # A module that exists is still not allowed — existing and
        # being allowlisted are different facts.
        case StepRegistry.fetch(name, registry) do
          {:ok, _entry} -> :ok
          {:error, :unknown_step} -> unknown_step_error(name, where)
        end

      nil ->
        {:error, "#{where}: step is missing the required \"step\" key"}

      other ->
        {:error, "#{where}: \"step\" must be a string name, got: #{inspect(other)}"}
    end
  end

  # Rule 1 and rule 2 share a resolution path but not a message: a
  # module-shaped name is a different mistake from a typo'd step name,
  # and a caller (or a test) must be able to tell them apart.
  defp unknown_step_error(name, where) do
    if module_shaped?(name) do
      {:error,
       "#{where}: #{inspect(name)} names a module, but step names are not modules. " <>
         "Steps resolve only through the Platform.Lifecycle.StepRegistry allowlist; " <>
         "a module that exists and is loaded is still not permitted"}
    else
      {:error,
       "#{where}: unknown step #{inspect(name)}. " <>
         "Step names must be registered in Platform.Lifecycle.StepRegistry"}
    end
  end

  defp module_shaped?(name) do
    String.starts_with?(name, "Elixir.") or
      match?(<<c::utf8, _::binary>> when c in ?A..?Z, name)
  end

  defp validate_flag(step, key, where) do
    case Map.fetch(step, key) do
      {:ok, value} when is_boolean(value) ->
        :ok

      {:ok, value} ->
        {:error,
         "#{where}: #{inspect(key)} must be a boolean, got: #{inspect(value)}. " <>
           "Truthy strings and numbers are rejected, not coerced"}

      :error ->
        {:error,
         "#{where}: #{inspect(key)} is required on every step. " <>
           "It is not defaulted — a missing #{inspect(key)} is a mistake worth an error, " <>
           "because a silently defaulted one is invisible"}
    end
  end

  defp validate_no_gate_edge(step, edge, where) when edge in @no_gate_edges do
    if Map.get(step, "await") == true or Map.get(step, "can_divert") == true do
      {:error,
       "#{where}: the #{inspect(edge)} edge accepts effects and notifies only. " <>
         "\"await\" and \"can_divert\" must both be false there (ADR-0046 Amendment 1 decision 6)"}
    else
      :ok
    end
  end

  defp validate_no_gate_edge(_step, _edge, _where), do: :ok

  defp validate_webhook_url(step, where) do
    case Map.fetch(step, "url") do
      :error ->
        :ok

      {:ok, url} when is_binary(url) ->
        case URI.parse(url) do
          %URI{host: host} when is_binary(host) and host != "" ->
            if StepRegistry.webhook_host_allowed?(host) do
              :ok
            else
              {:error,
               "#{where}: webhook host #{inspect(host)} is not allowlisted. " <>
                 "Hosts are configured at runtime via :lifecycle_allowed_webhook_hosts"}
            end

          _no_host ->
            {:error,
             "#{where}: webhook #{inspect(url)} has no parseable host. " <>
               "A webhook url must be absolute, with a scheme and a host"}
        end

      {:ok, url} ->
        {:error, "#{where}: \"url\" must be a string, got: #{inspect(url)}"}
    end
  end

  defp at(edge, index), do: "edge #{inspect(edge)} step #{index}"
end
