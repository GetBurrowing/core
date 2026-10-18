defmodule Platform.Experiments.Surfaces.InsightSynthesis do
  @moduledoc """
  The `memory.insight_synthesis` surface: how a dreaming run synthesises
  insights. Task `01a13867-3213-7001-a128-6b4c6b34283f`, stage 1, on the
  experimentation layer of ADR-0052.

  ## Subject, target, path

  Subject `"dreaming_run"`, id = `Platform.Memory.Insights.run_id/2` (a
  deterministic id per workspace and journal date), so the dispatch that
  resolves the arm and the ingest that reads it agree on the subject. One
  target, `"memory.dreaming"`. Path `:dispatch`: the payload is consumed
  inside the dreaming dispatch render and at ingest, with no draft between.

  ## Payload

    * `directive`: a string (at most 4000 chars) appended to the dreaming
      prompt as an `## Experiment directive (memory.insight_synthesis)`
      block, or nil for none. A blank string normalises to nil.
    * `min_confidence`: `"high" | "medium" | "low"`, the least confidence
      at which an ingested insight is marked `disseminable`.

  The control is `%{"directive" => nil, "min_confidence" => "high"}`:
  no directive block, and only high-confidence insights disseminable.
  Nothing is seeded, so with no experiment every run gets the control.

  ## Metric

  `insight_acceptance_rate` (`Platform.Experiments.Metrics.InsightAcceptanceRate`),
  computed from the signals `Platform.Memory.Insights` records per outcome.

  ## Model is NOT an arm

  Dreaming runs on whichever agent holds the `memory.dreaming`
  responsibility and no read point here chooses that agent's model;
  varying it means reassigning the responsibility, not an experiment arm.

  ## Scoping

  No `subject_attributes/1`: a dreaming run carries no project or org, so
  an org- or project-scoped experiment on this surface never assigns. Run
  it install-wide.
  """

  @behaviour Platform.Experiments.Surface

  @target "memory.dreaming"
  @confidences ~w(high medium low)
  @keys ~w(directive min_confidence)
  @max_directive 4000
  @control %{"directive" => nil, "min_confidence" => "high"}

  @impl true
  def key, do: "memory.insight_synthesis"

  @impl true
  def subject_type, do: "dreaming_run"

  @impl true
  def path, do: :dispatch

  @impl true
  def targets, do: [@target]

  @doc "The one target this surface is resolved at."
  @spec target() :: String.t()
  def target, do: @target

  @doc "The control payload."
  @spec control() :: map()
  def control, do: @control

  @impl true
  def payload_schema do
    %{
      "type" => "object",
      "required" => ["min_confidence"],
      "properties" => %{
        "directive" => %{
          "type" => ["string", "null"],
          "maxLength" => @max_directive,
          "description" =>
            "Text appended to the dreaming prompt as an experiment directive. Null for none (control)."
        },
        "min_confidence" => %{
          "type" => "string",
          "enum" => @confidences,
          "description" => "Least confidence at which an insight is disseminable. Control: high."
        }
      }
    }
  end

  @impl true
  def validate_payload(payload) when is_map(payload) do
    payload = Map.new(payload, fn {k, v} -> {to_string(k), v} end)
    unknown = payload |> Map.keys() |> Enum.reject(&(&1 in @keys)) |> Enum.sort()
    directive = normalise_directive(Map.get(payload, "directive"))
    min_confidence = Map.get(payload, "min_confidence")

    errors =
      [
        unknown != [] && "unknown keys: #{Enum.join(unknown, ", ")}",
        min_confidence not in @confidences &&
          "min_confidence must be one of: #{Enum.join(@confidences, ", ")}",
        directive == :invalid && "directive must be a string or null",
        (is_binary(directive) and String.length(directive) > @max_directive) &&
          "directive must be at most #{@max_directive} chars"
      ]
      |> Enum.filter(&is_binary/1)

    case errors do
      [] -> {:ok, %{"directive" => directive, "min_confidence" => min_confidence}}
      errors -> {:error, errors}
    end
  end

  def validate_payload(_payload), do: {:error, ["payload must be an object"]}

  defp normalise_directive(nil), do: nil

  defp normalise_directive(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalise_directive(_other), do: :invalid

  @impl true
  def control_payload(_target, _opts \\ []), do: {:ok, @control}

  @impl true
  def render_directive(%{"directive" => text}) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def render_directive(_payload), do: nil
end
