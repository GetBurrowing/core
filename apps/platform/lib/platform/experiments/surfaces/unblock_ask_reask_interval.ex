defmodule Platform.Experiments.Surfaces.UnblockAskReaskInterval do
  @moduledoc """
  The `agents.unblock_ask.reask_interval` surface: how long the lead agent
  waits before asking the same person about the same unchanged blocker again
  (task 01a1b6de stage 4, on the experimentation layer of ADR-0052, modelled
  on `Platform.Experiments.Surfaces.UxFrictionDetection`).

  ## Subject, target, path

  Subject `"unblock_subject"`, id = the ask's subject (the stuck agent's id or
  the stuck person's user id), so arms compare subjects rather than one
  install-wide subject. One target, `"agents.unblock_ask.reask_interval"`.
  Path `:dispatch`: `Platform.Agents.UnblockAsks` resolves the arm inside the
  `agents.team_check` fire.

  ## Payload

    * `reask_after_hours`: integer in 1..720. The candidates are 24 and 72.

  The control is the configured default, read when the control is asked for
  (`Platform.Agents.TeamCheck.default_config/0`, which reads
  `config :platform, Platform.Agents.TeamCheck, reask_after_hours:`). Nothing
  is seeded, so with no experiment and no promoted default every ask gets
  the operator's or the configured interval.

  ## Metric

  `unblock_asks_resolved_per_sent`
  (`Platform.Experiments.Metrics.UnblockAsksResolvedPerSent`): asks resolved
  over asks sent (first asks plus re-asks), per variant.
  """

  @behaviour Platform.Experiments.Surface

  @target "agents.unblock_ask.reask_interval"
  @keys ~w(reask_after_hours)
  @min 1
  @max 720

  @impl true
  def key, do: "agents.unblock_ask.reask_interval"

  @impl true
  def subject_type, do: "unblock_subject"

  @impl true
  def path, do: :dispatch

  @impl true
  def targets, do: [@target]

  @doc "The one target this surface is resolved at."
  @spec target() :: String.t()
  def target, do: @target

  @doc "The control payload: the configured default interval."
  @spec control() :: map()
  def control,
    do: %{"reask_after_hours" => Platform.Agents.TeamCheck.default_config()["reask_after_hours"]}

  @doc "The metric slug this surface is judged on."
  @spec metric() :: String.t()
  def metric, do: "unblock_asks_resolved_per_sent"

  @impl true
  def payload_schema do
    %{
      "type" => "object",
      "required" => ["reask_after_hours"],
      "properties" => %{
        "reask_after_hours" => %{
          "type" => "integer",
          "minimum" => @min,
          "maximum" => @max,
          "description" =>
            "Hours before an unchanged blocker is asked about again. Candidates: 24, 72."
        }
      }
    }
  end

  @impl true
  def validate_payload(payload) when is_map(payload) do
    payload = Map.new(payload, fn {k, v} -> {to_string(k), v} end)
    unknown = payload |> Map.keys() |> Enum.reject(&(&1 in @keys)) |> Enum.sort()
    hours = Map.get(payload, "reask_after_hours")

    errors =
      [
        unknown != [] && "unknown keys: #{Enum.join(unknown, ", ")}",
        not (is_integer(hours) and hours >= @min and hours <= @max) &&
          "reask_after_hours must be an integer in #{@min}..#{@max}"
      ]
      |> Enum.filter(&is_binary/1)

    case errors do
      [] -> {:ok, %{"reask_after_hours" => hours}}
      errors -> {:error, errors}
    end
  end

  def validate_payload(_payload), do: {:error, ["payload must be an object"]}

  @impl true
  def control_payload(_target, _opts \\ []), do: {:ok, control()}
end
