defmodule Platform.Experiments.PolicySpec do
  @moduledoc """
  Builds the EXISTING policy modules from data. Task 01a0d415, the
  experimentation-layer ADR-0052.

  `experiments.assignment_policy` is a JSON map; this module turns it into the
  `{module, opts}` pair the policy library already understands. No policy is
  reimplemented here — the map only names one of
  `Platform.Experiments.Policies.*` and supplies its options, which is what
  makes ADR-0048 Decision 4's project/epic exclusion filter a data change
  rather than a code change.

  ## The map

      %{"type" => "random_buckets"}
      %{"type" => "epic_scoped", "epic_ids" => [uuid, ...]}
      %{"type" => "task_cohort", "cohort" => %{"epic_id" => [uuid, ...]}}
      %{"type" => "task_cohort", "cohort" => %{"agent_id" => [uuid, ...]}}
      %{"type" => "time_window", "from" => iso8601, "until" => iso8601}
      %{"type" => "composite", "policies" => [policy_map, ...]}

  Every level also accepts the shared `"exclude"` key,
  `%{"project_ids" => [...], "epic_ids" => [...]}`. A map with no `"type"`
  but other keys is `random_buckets` — so `%{"exclude" => ...}` alone is the
  exclusion lever over an otherwise-unchanged split.

  An EMPTY map is `:none`: no policy, and `Platform.Experiments.Assignments`
  uses today's weighted pick. That is the value every pre-existing
  experiment carries.

  ## Context is injected, never stored

  `:experiment_id` and `:variants` are supplied by the caller at build time
  and injected into every member's options (composite members included),
  because `RandomBuckets` performs no queries. Storing them in the map would
  let a stored policy name variants the experiment no longer has.

  ## Malformed is an error, never a silent default

  An unknown type, an unknown key, a non-list id list, or an unparseable
  timestamp is `{:error, reasons}`. `Platform.Experiments.Experiment`'s
  changeset calls `validate/1`, so a bad policy is refused when written, not
  discovered at assignment time.
  """

  alias Platform.Experiments.Policies.Composite
  alias Platform.Experiments.Policies.EpicScoped
  alias Platform.Experiments.Policies.RandomBuckets
  alias Platform.Experiments.Policies.TaskCohort
  alias Platform.Experiments.Policies.TimeWindow

  @types %{
    "random_buckets" => RandomBuckets,
    "task_cohort" => TaskCohort,
    "epic_scoped" => EpicScoped,
    "time_window" => TimeWindow,
    "composite" => Composite
  }

  # The attribute keys a cohort may name. Fixed, so a stored string never
  # becomes an atom.
  @cohort_keys %{
    "project_id" => :project_id,
    "org_id" => :org_id,
    "epic_id" => :epic_id,
    # Task 01a114a8 stage 4: the dispatched phase's assignee, supplied by
    # `HeartbeatScheduler.experiment_subject/2`. Enrolling agents in an
    # experiment is then a cohort map, i.e. data.
    "agent_id" => :agent_id
  }

  @type built :: {module(), keyword()}

  @doc "The policy type names a map may use."
  @spec types() :: [String.t()]
  def types, do: @types |> Map.keys() |> Enum.sort()

  @doc """
  Builds `{module, opts}` from a non-empty, valid policy map. Raises
  `ArgumentError` on an empty or invalid map; use `parse/2` to branch.
  """
  @spec build(map(), keyword()) :: built()
  def build(map, context \\ []) do
    case parse(map, context) do
      {:ok, built} -> built
      :none -> raise ArgumentError, "an empty policy map builds no policy; it means weighted pick"
      {:error, reasons} -> raise ArgumentError, "invalid policy: " <> Enum.join(reasons, "; ")
    end
  end

  @doc """
  `{:ok, {module, opts}}`, `:none` for an empty map, or `{:error, reasons}`.
  `context` is `[experiment_id: id, variants: variants]`.
  """
  @spec parse(map() | nil, keyword()) :: {:ok, built()} | :none | {:error, [String.t()]}
  def parse(nil, _context), do: :none
  def parse(map, _context) when is_map(map) and map_size(map) == 0, do: :none

  def parse(map, context) when is_map(map) do
    injected = Keyword.take(context, [:experiment_id, :variants])

    case do_parse(stringify(map), injected) do
      {:ok, built} -> {:ok, built}
      {:error, reasons} -> {:error, reasons}
    end
  end

  def parse(_other, _context), do: {:error, ["assignment_policy must be a map"]}

  @doc "`:ok` when `parse/2` would succeed or the map is empty."
  @spec validate(map() | nil) :: :ok | {:error, [String.t()]}
  def validate(map) do
    case parse(map, []) do
      {:error, reasons} -> {:error, reasons}
      _ -> :ok
    end
  end

  # `kind` is the metric_spec discriminator; a policy written with it has no
  # `type` and would otherwise default to random_buckets and be refused with
  # an error naming a policy the caller never asked for.
  defp do_parse(%{"kind" => kind} = map, _context) when not is_map_key(map, "type") do
    {:error,
     [
       "unknown policy key 'kind' (#{inspect(kind)}); assignment_policy uses 'type'. " <>
         "Known types: #{Enum.join(types(), ", ")}"
     ]}
  end

  defp do_parse(map, context) when is_map(map) do
    type = Map.get(map, "type", "random_buckets")

    with {:ok, module} <- fetch_type(type),
         {:ok, exclude} <- parse_exclude(Map.get(map, "exclude")),
         {:ok, own} <- parse_params(type, Map.drop(map, ["type", "exclude"]), context) do
      opts =
        context
        |> Keyword.merge(own)
        |> put_exclude(exclude)

      {:ok, {module, opts}}
    end
  end

  defp do_parse(_other, _context), do: {:error, ["every policy must be a map"]}

  defp fetch_type(type) do
    case Map.fetch(@types, type) do
      {:ok, module} ->
        {:ok, module}

      :error ->
        {:error, ["unknown policy type #{inspect(type)}; known: #{Enum.join(types(), ", ")}"]}
    end
  end

  defp put_exclude(opts, []), do: opts
  defp put_exclude(opts, exclude), do: Keyword.put(opts, :exclude, exclude)

  defp parse_exclude(nil), do: {:ok, []}

  defp parse_exclude(%{} = exclude) do
    exclude = stringify(exclude)

    case Map.keys(exclude) -- ["project_ids", "epic_ids"] do
      [] ->
        with {:ok, projects} <- id_list(exclude, "project_ids", "exclude.project_ids"),
             {:ok, epics} <- id_list(exclude, "epic_ids", "exclude.epic_ids") do
          {:ok, Enum.reject([project_ids: projects, epic_ids: epics], fn {_k, v} -> v == [] end)}
        end

      unknown ->
        {:error, ["unknown exclude keys: #{Enum.join(unknown, ", ")}"]}
    end
  end

  defp parse_exclude(_other), do: {:error, ["exclude must be a map"]}

  defp parse_params("random_buckets", params, _context), do: no_params("random_buckets", params)

  defp parse_params("epic_scoped", params, _context) do
    with :ok <- only_keys("epic_scoped", params, ["epic_ids"]),
         {:ok, [_ | _] = ids} <- id_list(params, "epic_ids", "epic_ids") do
      {:ok, [epic_ids: ids]}
    else
      {:ok, []} -> {:error, ["epic_scoped needs a non-empty epic_ids list"]}
      error -> error
    end
  end

  defp parse_params("task_cohort", params, _context) do
    with :ok <- only_keys("task_cohort", params, ["cohort"]),
         {:ok, cohort} <- parse_cohort(Map.get(params, "cohort")) do
      {:ok, [cohort: cohort]}
    end
  end

  defp parse_params("time_window", params, _context) do
    with :ok <- only_keys("time_window", params, ["from", "until"]),
         {:ok, from} <- datetime(params, "from"),
         {:ok, until} <- datetime(params, "until") do
      {:ok, Enum.reject([from: from, until: until], fn {_k, v} -> is_nil(v) end)}
    end
  end

  defp parse_params("composite", params, context) do
    with :ok <- only_keys("composite", params, ["policies"]) do
      case Map.get(params, "policies") do
        [_ | _] = members ->
          members
          |> Enum.map(&do_parse(if(is_map(&1), do: stringify(&1), else: &1), context))
          |> collect()
          |> case do
            {:ok, built} -> {:ok, [policies: built]}
            error -> error
          end

        _ ->
          {:error, ["composite needs a non-empty policies list"]}
      end
    end
  end

  defp collect(results) do
    case Enum.flat_map(results, fn
           {:error, reasons} -> reasons
           _ -> []
         end) do
      [] -> {:ok, Enum.map(results, fn {:ok, built} -> built end)}
      reasons -> {:error, reasons}
    end
  end

  defp no_params(_type, params) when map_size(params) == 0, do: {:ok, []}

  defp no_params(type, params),
    do: {:error, ["#{type} takes no parameters; got #{Enum.join(Map.keys(params), ", ")}"]}

  defp only_keys(type, params, allowed) do
    case Map.keys(params) -- allowed do
      [] -> :ok
      unknown -> {:error, ["unknown #{type} keys: #{Enum.join(unknown, ", ")}"]}
    end
  end

  defp parse_cohort(%{} = cohort) when map_size(cohort) > 0 do
    cohort
    |> stringify()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn {key, values}, {:ok, acc} ->
      case Map.fetch(@cohort_keys, key) do
        {:ok, atom} ->
          {:cont, {:ok, acc ++ [{atom, values}]}}

        :error ->
          {:halt,
           {:error,
            [
              "unknown cohort key #{inspect(key)}; known: #{Enum.join(Map.keys(@cohort_keys), ", ")}"
            ]}}
      end
    end)
  end

  defp parse_cohort(_other), do: {:error, ["task_cohort needs a non-empty cohort map"]}

  defp id_list(map, key, label) do
    case Map.get(map, key) do
      nil ->
        {:ok, []}

      ids when is_list(ids) ->
        if Enum.all?(ids, &is_binary/1),
          do: {:ok, ids},
          else: {:error, ["#{label} must be a list of strings"]}

      _ ->
        {:error, ["#{label} must be a list"]}
    end
  end

  defp datetime(map, key) do
    case Map.get(map, key) do
      nil ->
        {:ok, nil}

      %DateTime{} = at ->
        {:ok, at}

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, at, _offset} -> {:ok, at}
          _ -> {:error, ["time_window.#{key} is not an ISO 8601 datetime"]}
        end

      _ ->
        {:error, ["time_window.#{key} is not an ISO 8601 datetime"]}
    end
  end

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
end
