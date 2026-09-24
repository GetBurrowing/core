defmodule Platform.Experiments.Surfaces.PlannerStageBudget do
  @moduledoc """
  The `planner.stage_budget` surface: the most stages a planner may put in a
  task's plan. Task 01a0d415 stage 4, the experimentation-layer ADR-0052.

  Resolved at the planning dispatch (`dispatch.planning`, see
  `Platform.Orchestration.HeartbeatScheduler.append_experiment_directive/4`)
  on every planning render; only the experiment's scope (its `org_id` /
  `project_id` columns plus its `assignment_policy`) decides which tasks
  it reaches. An out-of-scope render is byte-identical to a render with no
  experiment at all.

  ## Target

  The only target is `"dispatch.planning"` (`targets/0`); `experiment_create`
  refuses any other.

  ## Payload

  `%{"max_stages" => integer 1..10}`. The control is `%{}`: no budget, and
  no directive block.
  """

  @behaviour Platform.Experiments.Surface

  alias Platform.Experiments.Surfaces.DispatchPrompt

  @target "dispatch.planning"

  @impl true
  def key, do: "planner.stage_budget"

  @impl true
  def subject_type, do: "task"

  @impl true
  def path, do: :dispatch

  @doc "The dispatch slugs this surface is resolved at."
  @impl true
  def targets, do: [@target]

  @impl true
  def payload_schema do
    %{
      "type" => "object",
      "required" => ["max_stages"],
      "properties" => %{
        "max_stages" => %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => 10,
          "description" => "The most stages the plan may contain. The control is {} (no budget)."
        }
      }
    }
  end

  @impl true
  def validate_payload(payload) when payload == %{}, do: {:ok, %{}}

  def validate_payload(payload) when is_map(payload) do
    n = Map.get(payload, "max_stages", Map.get(payload, :max_stages))
    unknown = Enum.reject(Map.keys(payload), &(to_string(&1) == "max_stages"))

    errors =
      if(is_integer(n) and n in 1..10,
        do: [],
        else: ["max_stages must be an integer in 1..10"]
      ) ++
        if(unknown == [],
          do: [],
          else: [
            "unknown keys: #{unknown |> Enum.map(&to_string/1) |> Enum.sort() |> Enum.join(", ")}"
          ]
        )

    case errors do
      [] -> {:ok, %{"max_stages" => n}}
      errors -> {:error, errors}
    end
  end

  def validate_payload(_payload), do: {:error, ["payload must be an object"]}

  @impl true
  def control_payload(_target, _opts \\ []), do: {:ok, %{}}

  @impl true
  def render_directive(%{"max_stages" => 1}),
    do: "Plan at most 1 stage. Fit the whole task into a single stage."

  def render_directive(%{"max_stages" => n}) when is_integer(n),
    do: "Plan at most #{n} stages. Merge work into fewer stages rather than exceed this."

  def render_directive(_payload), do: nil

  @impl true
  defdelegate subject_attributes(task_id), to: DispatchPrompt
end
