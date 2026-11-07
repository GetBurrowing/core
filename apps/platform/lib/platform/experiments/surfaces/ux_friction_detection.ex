defmodule Platform.Experiments.Surfaces.UxFrictionDetection do
  @moduledoc """
  The `ux.friction_detection` surface: how the UX friction watch
  (`ux.friction_watch`, which joins the designer bundle with its handler in stage 2) turns chat into findings. Task
  01a1af00 stage 1, on the experimentation layer of ADR-0052, modelled on
  `Platform.Experiments.Surfaces.HrProfile`.

  ## Subject, target, path

  Subject `"workspace"`, id = the workspace the fire is scoped to, or the nil
  UUID for an org-wide fire. One target, `"ux.friction_detection"`. Path
  `:dispatch`: the friction-watch handler resolves the arm and consumes the
  payload inside its dispatch. No `subject_attributes/1`, as for `hr.profile`:
  run experiments on this surface install-wide.

  ## Payload (every variant is data)

    * `directive`: a string (at most 4000 chars) rendered into the friction
      prompt as its `experiment_directive`, or nil for none. Blank normalises
      to nil. This is the friction-detection prompt variant.
    * `grouping_threshold`: float in 0.50..0.99, the similarity at or above
      which two friction signals join one group (one `group_key`, one
      finding). Control: 0.80.
    * `min_occurrences`: integer in 1..20, how many grouped signals a group
      needs before a finding is filed. Control: 3.

  The control is `%{"directive" => nil, "grouping_threshold" => 0.8,
  "min_occurrences" => 3}`. Nothing is seeded, so with no experiment every
  fire gets the control.

  ## Metric

  `ux_finding_keep_rate` (`Platform.Experiments.Metrics.UxFindingKeepRate`):
  the share of resolved findings a human keeps (answers) rather than
  dismisses, per variant.
  """

  @behaviour Platform.Experiments.Surface

  @target "ux.friction_detection"
  @keys ~w(directive grouping_threshold min_occurrences)
  @max_directive 4000
  @control %{"directive" => nil, "grouping_threshold" => 0.8, "min_occurrences" => 3}

  @impl true
  def key, do: "ux.friction_detection"

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

  @doc "The metric slug this surface is judged on."
  @spec metric() :: String.t()
  def metric, do: "ux_finding_keep_rate"

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
            "Text rendered into the friction-detection prompt as an experiment directive. " <>
              "Null for none (control)."
        },
        "grouping_threshold" => %{
          "type" => "number",
          "minimum" => 0.50,
          "maximum" => 0.99,
          "description" =>
            "Similarity at or above which two friction signals share a group. Control: 0.80."
        },
        "min_occurrences" => %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => 20,
          "description" => "Grouped signals needed before a finding is filed. Control: 3."
        }
      }
    }
  end

  @impl true
  def validate_payload(payload) when is_map(payload) do
    payload = Map.new(payload, fn {k, v} -> {to_string(k), v} end)
    unknown = payload |> Map.keys() |> Enum.reject(&(&1 in @keys)) |> Enum.sort()
    directive = normalise_directive(Map.get(payload, "directive"))
    threshold = Map.get(payload, "grouping_threshold", @control["grouping_threshold"])
    min_occurrences = Map.get(payload, "min_occurrences", @control["min_occurrences"])

    errors =
      [
        unknown != [] && "unknown keys: #{Enum.join(unknown, ", ")}",
        directive == :invalid && "directive must be a string or null",
        (is_binary(directive) and String.length(directive) > @max_directive) &&
          "directive must be at most #{@max_directive} chars",
        not valid_threshold?(threshold) && "grouping_threshold must be a number in 0.50..0.99",
        not valid_occurrences?(min_occurrences) &&
          "min_occurrences must be an integer in 1..20"
      ]
      |> Enum.filter(&is_binary/1)

    case errors do
      [] ->
        {:ok,
         %{
           "directive" => directive,
           "grouping_threshold" => threshold / 1,
           "min_occurrences" => min_occurrences
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

  defp valid_threshold?(value), do: is_number(value) and value >= 0.50 and value <= 0.99

  defp valid_occurrences?(n), do: is_integer(n) and n >= 1 and n <= 20

  defp normalise_directive(nil), do: nil

  defp normalise_directive(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalise_directive(_other), do: :invalid
end
