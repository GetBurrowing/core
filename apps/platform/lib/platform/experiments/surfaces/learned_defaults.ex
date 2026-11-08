defmodule Platform.Experiments.Surfaces.LearnedDefaults do
  @moduledoc """
  The `habits.learned_defaults` surface: the trust-ladder thresholds and
  decay for a user's learned patterns. Task 01a1b6a1 stage 1, recorded in
  `0061-learned-defaults.md` § 6, on the experimentation layer of ADR-0052.

  ## Subject, target, path

  Subject `"user"`, id = the user whose suggestions are being computed. One
  target, `"chat.message_attention"`, the one consumer today. Path `:draft`:
  the payload decides what the picker pre-fills, which the user sees and
  confirms (or undoes) before anything else happens.

  ## Payload

    * `prefill_threshold`: number in 0..1, the confidence the top target must
      reach before it is pre-filled. Control: 0.6.
    * `min_signals`: integer in 1..50, how many times the top target must
      have been chosen or accepted (a raw count, not decayed) before a
      pre-fill. Control: 3.
    * `act_after_accepts`: integer in 1..50, accepted pre-fills before the
      ladder may act with undo. Control: 5.
    * `half_life_days`: integer in 1..365, the decay half-life of a signal's
      weight. Control: 30.

  Unknown keys are refused. A missing key takes the control's value. Nothing
  is seeded, so with no experiment every user gets the control.
  """

  @behaviour Platform.Experiments.Surface

  @target "chat.message_attention"
  @keys ~w(prefill_threshold min_signals act_after_accepts half_life_days)
  @control %{
    "prefill_threshold" => 0.6,
    "min_signals" => 3,
    "act_after_accepts" => 5,
    "half_life_days" => 30
  }

  @impl true
  def key, do: "habits.learned_defaults"

  @impl true
  def subject_type, do: "user"

  @impl true
  def path, do: :draft

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
      "additionalProperties" => false,
      "properties" => %{
        "prefill_threshold" => %{
          "type" => "number",
          "minimum" => 0,
          "maximum" => 1,
          "description" =>
            "Confidence the top target needs before it is pre-filled. Control: 0.6."
        },
        "min_signals" => %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => 50,
          "description" => "Decayed signal count needed before a pre-fill. Control: 3."
        },
        "act_after_accepts" => %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => 50,
          "description" => "Accepted pre-fills before acting with undo. Control: 5."
        },
        "half_life_days" => %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => 365,
          "description" => "Decay half-life of a signal's weight, in days. Control: 30."
        }
      }
    }
  end

  @impl true
  def validate_payload(payload) when is_map(payload) do
    payload = Map.new(payload, fn {k, v} -> {to_string(k), v} end)
    unknown = payload |> Map.keys() |> Enum.reject(&(&1 in @keys)) |> Enum.sort()
    merged = Map.merge(@control, Map.take(payload, @keys))

    errors =
      [
        unknown != [] && "unknown keys: #{Enum.join(unknown, ", ")}",
        not number_in?(merged["prefill_threshold"], 0, 1) &&
          "prefill_threshold must be a number in 0..1",
        not integer_in?(merged["min_signals"], 1, 50) &&
          "min_signals must be an integer in 1..50",
        not integer_in?(merged["act_after_accepts"], 1, 50) &&
          "act_after_accepts must be an integer in 1..50",
        not integer_in?(merged["half_life_days"], 1, 365) &&
          "half_life_days must be an integer in 1..365"
      ]
      |> Enum.filter(&is_binary/1)

    case errors do
      [] -> {:ok, Map.update!(merged, "prefill_threshold", &(&1 / 1))}
      errors -> {:error, errors}
    end
  end

  def validate_payload(_payload), do: {:error, ["payload must be an object"]}

  @impl true
  def control_payload(_target, _opts \\ []), do: {:ok, @control}

  defp number_in?(value, min, max), do: is_number(value) and value >= min and value <= max
  defp integer_in?(value, min, max), do: is_integer(value) and value >= min and value <= max
end
