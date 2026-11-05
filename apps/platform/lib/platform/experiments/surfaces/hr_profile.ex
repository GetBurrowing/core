defmodule Platform.Experiments.Surfaces.HrProfile do
  @moduledoc """
  The `hr.profile` surface: how the HR responsibility curates people
  profiles. Task 01a1aa47 stage 4, on the experimentation layer of ADR-0052.

  ## Subject, target, path

  Subject `"workspace"`, id = the workspace the fire is scoped to, or the nil
  UUID for an org-wide fire. One target, `"hr.profile"`. Path `:dispatch`:
  `Platform.Responsibilities.Handlers.Hr.gather_context/2` resolves the arm
  and consumes the payload inside the dispatch, with no draft between.

  ## Payload

    * `directive`: a string (at most 4000 chars) rendered into the HR prompt
      as its `experiment_directive`, or nil for none. Blank normalises to nil.
    * `staleness_days`: integer in 1..90, the daily sweep's lookback and the
      staleness cutoff. Control: 30.
    * `fuzzy_threshold`: float in 0.70..0.99, the `Platform.People.Identity`
      threshold the sweep resolves names with. Control: 0.84.

  The control is `%{"directive" => nil, "staleness_days" => 30,
  "fuzzy_threshold" => 0.84}`. Nothing is seeded, so with no experiment every
  fire gets the control. Mirrors `Platform.Experiments.Surfaces.InsightSynthesis`.
  """

  @behaviour Platform.Experiments.Surface

  @target "hr.profile"
  @keys ~w(directive staleness_days fuzzy_threshold)
  @max_directive 4000
  @control %{"directive" => nil, "staleness_days" => 30, "fuzzy_threshold" => 0.84}

  @impl true
  def key, do: "hr.profile"

  @impl true
  def subject_type, do: "workspace"

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
      "required" => [],
      "properties" => %{
        "directive" => %{
          "type" => ["string", "null"],
          "maxLength" => @max_directive,
          "description" =>
            "Text rendered into the HR prompt as an experiment directive. Null for none (control)."
        },
        "staleness_days" => %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => 90,
          "description" =>
            "Lookback and staleness cutoff for the daily sweep, in days. Control: 30."
        },
        "fuzzy_threshold" => %{
          "type" => "number",
          "minimum" => 0.70,
          "maximum" => 0.99,
          "description" => "Name-resolution similarity threshold. Control: 0.84."
        }
      }
    }
  end

  @impl true
  def validate_payload(payload) when is_map(payload) do
    payload = Map.new(payload, fn {k, v} -> {to_string(k), v} end)
    unknown = payload |> Map.keys() |> Enum.reject(&(&1 in @keys)) |> Enum.sort()
    directive = normalise_directive(Map.get(payload, "directive"))
    staleness_days = Map.get(payload, "staleness_days", @control["staleness_days"])
    threshold = Map.get(payload, "fuzzy_threshold", @control["fuzzy_threshold"])

    errors =
      [
        unknown != [] && "unknown keys: #{Enum.join(unknown, ", ")}",
        directive == :invalid && "directive must be a string or null",
        (is_binary(directive) and String.length(directive) > @max_directive) &&
          "directive must be at most #{@max_directive} chars",
        not valid_days?(staleness_days) && "staleness_days must be an integer in 1..90",
        not valid_threshold?(threshold) && "fuzzy_threshold must be a number in 0.70..0.99"
      ]
      |> Enum.filter(&is_binary/1)

    case errors do
      [] ->
        {:ok,
         %{
           "directive" => directive,
           "staleness_days" => staleness_days,
           "fuzzy_threshold" => threshold / 1
         }}

      errors ->
        {:error, errors}
    end
  end

  def validate_payload(_payload), do: {:error, ["payload must be an object"]}

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

  defp valid_days?(days), do: is_integer(days) and days >= 1 and days <= 90

  defp valid_threshold?(value), do: is_number(value) and value >= 0.70 and value <= 0.99

  defp normalise_directive(nil), do: nil

  defp normalise_directive(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalise_directive(_other), do: :invalid
end
