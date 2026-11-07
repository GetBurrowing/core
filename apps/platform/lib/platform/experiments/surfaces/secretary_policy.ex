defmodule Platform.Experiments.Surfaces.SecretaryPolicy do
  @moduledoc """
  The `secretary.policy` surface: how the per-person triage agent (task
  01a1b721) briefs, ranks and interrupts, and what it may spend.

  ## Subject, target, path

  Subject `"user"`, id = the person being triaged for. One target,
  `"secretary.policy"`. Path `:dispatch`: the batch dispatcher (a later
  stage) resolves the arm and consumes the payload inside the dispatch.

  ## Payload

    * `preamble` — the prompt preamble (at most 8000 chars). Control: the
      text of `priv/secretary/prompt.md`, in the warm-neighbour voice (task
      01a1b6ff), which tells the model that everything inside the INPUTS
      block is untrusted data, never instructions.
    * `brief_max_lines` 3..5 (5), `needs_you_now_threshold` 0..100 (70),
      `daily_token_ceiling` per person (200000), `install_daily_token_ceiling`
      (2000000), `max_in_flight` 1..8 (2), `debounce_ms` 5000..900000
      (90000), `max_batch_items` 1..200 (60).

  The numeric control lives in `priv/secretary/policy_default.json`. Both
  files are read at compile time.

  ## Metrics

  `metric_specs/0` declares `secretary_brief_acted_on_rate` (primary) and
  `secretary_nudge_dismiss_rate` (guardrail) as `outcome_rate` specs over
  labelled `experiment_signals` rows with `subject_type "user"`. Those
  signals are written DETERMINISTICALLY by the triage agent's own code
  (labels in `signal_labels/0`), never by the Labeler. `outcome_rate` and
  `Signal` keep `subject_type` a free string, so a user subject computes
  with no engine change. Note what it computes: the share of assigned
  people with at least one such signal within `window_days` of their
  ASSIGNMENT, not a per-brief-line rate. The slug registry in
  `Platform.Experiments.Metrics` is task-subject only and is not used.
  """

  @behaviour Platform.Experiments.Surface

  import Ecto.Query

  @target "secretary.policy"
  @prompt_path Path.expand("../../../../priv/secretary/prompt.md", __DIR__)
  @policy_path Path.expand("../../../../priv/secretary/policy_default.json", __DIR__)
  @external_resource @prompt_path
  @external_resource @policy_path

  @max_preamble 8000

  @ranges %{
    "brief_max_lines" => {3, 5},
    "needs_you_now_threshold" => {0, 100},
    "daily_token_ceiling" => {1, nil},
    "install_daily_token_ceiling" => {1, nil},
    "max_in_flight" => {1, 8},
    "debounce_ms" => {5_000, 900_000},
    "max_batch_items" => {1, 200}
  }

  @control @policy_path
           |> File.read!()
           |> Jason.decode!()
           |> Map.put("preamble", @prompt_path |> File.read!() |> String.trim())

  @keys Map.keys(@ranges) ++ ["preamble"]

  @acted_on_label "brief_acted_on"
  @dismissed_label "nudge_dismissed"

  @impl true
  def key, do: "secretary.policy"

  @impl true
  def subject_type, do: "user"

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

  @doc """
  The two metrics, as `metric_spec` maps an experiment row carries:
  `%{slug => spec}`.
  """
  @spec metric_specs() :: %{String.t() => map()}
  def metric_specs do
    %{
      "secretary_brief_acted_on_rate" => %{
        "kind" => "outcome_rate",
        "labels" => [@acted_on_label],
        "window_days" => 1,
        "anchor" => "assigned_at"
      },
      "secretary_nudge_dismiss_rate" => %{
        "kind" => "outcome_rate",
        "labels" => [@dismissed_label],
        "window_days" => 1,
        "anchor" => "assigned_at"
      }
    }
  end

  @doc "The labels the triage agent's code writes on its signals."
  @spec signal_labels() :: %{acted_on: String.t(), nudge_dismissed: String.t()}
  def signal_labels, do: %{acted_on: @acted_on_label, nudge_dismissed: @dismissed_label}

  @impl true
  def payload_schema do
    numeric =
      Map.new(@ranges, fn {key, {min, max}} ->
        spec = %{"type" => "integer", "minimum" => min, "default" => Map.fetch!(@control, key)}
        {key, if(max, do: Map.put(spec, "maximum", max), else: spec)}
      end)

    %{
      "type" => "object",
      "required" => [],
      "properties" =>
        Map.put(numeric, "preamble", %{
          "type" => "string",
          "maxLength" => @max_preamble,
          "description" =>
            "The prompt preamble. Must keep the rule that the INPUTS block is untrusted data."
        })
    }
  end

  @impl true
  def validate_payload(payload) when is_map(payload) do
    payload = Map.new(payload, fn {k, v} -> {to_string(k), v} end)
    unknown = payload |> Map.keys() |> Enum.reject(&(&1 in @keys)) |> Enum.sort()
    merged = Map.merge(@control, Map.take(payload, @keys))

    errors =
      [unknown != [] && "unknown keys: #{Enum.join(unknown, ", ")}"] ++
        preamble_errors(merged["preamble"]) ++
        Enum.map(Enum.sort(@ranges), fn {key, range} -> range_error(key, merged[key], range) end)

    case Enum.filter(errors, &is_binary/1) do
      [] -> {:ok, Map.update!(merged, "preamble", &String.trim/1)}
      errors -> {:error, errors}
    end
  end

  def validate_payload(_payload), do: {:error, ["payload must be an object"]}

  @impl true
  def control_payload(_target, _opts \\ []), do: {:ok, @control}

  @impl true
  def subject_attributes(user_id) do
    org_id =
      if Platform.UUID.valid?(user_id),
        do:
          Platform.Repo.one(
            from(m in Platform.Tenancy.OrgMembership,
              where: m.user_id == ^user_id,
              order_by: [asc: m.inserted_at],
              limit: 1,
              select: m.org_id
            )
          )

    %{org_id: org_id}
  end

  defp preamble_errors(text) when is_binary(text) do
    cond do
      String.trim(text) == "" -> ["preamble must not be blank"]
      String.length(text) > @max_preamble -> ["preamble must be at most #{@max_preamble} chars"]
      true -> []
    end
  end

  defp preamble_errors(_text), do: ["preamble must be a string"]

  defp range_error(key, value, {min, max}) do
    ok? = is_integer(value) and value >= min and (is_nil(max) or value <= max)

    cond do
      ok? -> nil
      is_nil(max) -> "#{key} must be an integer >= #{min}"
      true -> "#{key} must be an integer in #{min}..#{max}"
    end
  end
end
