defmodule Platform.Responsibilities.Responsibility do
  @moduledoc """
  Schema for the `responsibilities` table — the declarative registry of
  feature responsibilities the platform fulfills automatically (ADR-0041 M1).

  A responsibility pins together:

    * `key` — the canonical `<feature>.<verb>` identifier (e.g.
      `meetings.summarize`). Enforced by both the changeset and a DB
      check constraint.
    * `feature` — the high-level feature surface the responsibility belongs
      to (e.g. `meetings`). Mirrors the prefix of `key`.
    * `trigger_kind` + `trigger_config` — how the responsibility is invoked.
      One of `cron | event_topic | chat_pattern | webhook`. The shape of
      `trigger_config` is kind-specific and validated below.
    * `scope` — at what nesting level the responsibility runs. One of
      `global | per_org | per_project | per_space | per_meeting`.
    * `context_provided` — declarative list of context fragment names the
      router will fetch and hand to the provider.
    * `output_contract` — JSONB blob describing the expected output shape.
    * `default_prompt_template` — slug of the default prompt template the
      router should use when no per-org override exists.
    * `cost_profile` — coarse latency/cost hint used by the router to pick a
      provider tier. One of `high_freq_low_cost | low_freq_capable`.
    * `enabled` — operator kill-switch. Defaults to `true`. The M6 router
      pre-filters on this column; `Platform.Responsibilities.upsert_by_key/1`
      deliberately omits `enabled` from its replace-set so operator toggles
      survive boot-time re-registration.
    * `metadata` — free-form provider-specific extras (jsonb). Not
      interpreted by the platform.

  Only the changeset and accessors live here — the Provider behaviour and
  Registry GenServer land in later stages of M1.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @trigger_kinds ~w(cron event_topic chat_pattern webhook)
  @scopes ~w(global per_org per_project per_space per_meeting)
  @cost_profiles ~w(high_freq_low_cost low_freq_capable)

  @key_regex ~r/^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$/

  schema "responsibilities" do
    field(:key, :string)
    field(:feature, :string)
    field(:trigger_kind, :string)
    field(:trigger_config, :map, default: %{})
    field(:scope, :string)
    field(:context_provided, {:array, :string}, default: [])
    field(:output_contract, :map, default: %{})
    field(:default_prompt_template, :string)
    field(:cost_profile, :string)
    field(:enabled, :boolean, default: true)
    field(:metadata, :map, default: %{})

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Returns the list of valid `trigger_kind` values."
  def trigger_kinds, do: @trigger_kinds

  @doc "Returns the list of valid `scope` values."
  def scopes, do: @scopes

  @doc "Returns the list of valid `cost_profile` values."
  def cost_profiles, do: @cost_profiles

  @cast_fields ~w(key feature trigger_kind trigger_config scope context_provided
                  output_contract default_prompt_template cost_profile enabled
                  metadata)a
  @required_fields ~w(key feature trigger_kind trigger_config scope
                      cost_profile)a

  @doc """
  Changeset for inserting or updating a responsibility.

  Validates:

    * required fields are present;
    * `key` matches `^[a-z][a-z0-9_]*\\.[a-z][a-z0-9_]*$`;
    * `trigger_kind`, `scope`, and `cost_profile` belong to their enums;
    * `trigger_config` is a map (not a list / scalar);
    * `trigger_config` carries the kind-specific payload (cron expression,
      compilable regex, event topic, or webhook path);
    * `key` is globally unique.
  """
  def changeset(responsibility, attrs) do
    responsibility
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> validate_format(:key, @key_regex,
      message: "must match <feature>.<verb> (e.g. meetings.summarize)"
    )
    |> validate_inclusion(:trigger_kind, @trigger_kinds)
    |> validate_inclusion(:scope, @scopes)
    |> validate_inclusion(:cost_profile, @cost_profiles)
    |> validate_trigger_config()
    |> unique_constraint(:key)
  end

  # ── trigger_config validation ──────────────────────────────────────────────

  defp validate_trigger_config(changeset) do
    case fetch_field(changeset, :trigger_config) do
      {_, value} when not is_map(value) ->
        add_error(changeset, :trigger_config, "must be a map")

      {_, config} when is_map(config) ->
        kind = get_field(changeset, :trigger_kind)
        validate_trigger_config_for_kind(changeset, kind, config)

      :error ->
        changeset
    end
  end

  defp validate_trigger_config_for_kind(changeset, "cron", config) do
    case Map.get(config, "expression") || Map.get(config, :expression) do
      nil ->
        add_error(changeset, :trigger_config, ~s(missing required key "expression"))

      expression when is_binary(expression) ->
        if valid_cron_expression?(expression) do
          changeset
        else
          add_error(changeset, :trigger_config, "\"expression\" is not a valid cron string")
        end

      _ ->
        add_error(changeset, :trigger_config, "\"expression\" must be a string")
    end
  end

  defp validate_trigger_config_for_kind(changeset, "chat_pattern", config) do
    case Map.get(config, "regex") || Map.get(config, :regex) do
      nil ->
        add_error(changeset, :trigger_config, ~s(missing required key "regex"))

      regex when is_binary(regex) ->
        case Regex.compile(regex) do
          {:ok, _} ->
            changeset

          {:error, _} ->
            add_error(changeset, :trigger_config, "\"regex\" is not a compilable regex")
        end

      _ ->
        add_error(changeset, :trigger_config, "\"regex\" must be a string")
    end
  end

  defp validate_trigger_config_for_kind(changeset, "event_topic", config) do
    case Map.get(config, "topic") || Map.get(config, :topic) do
      nil ->
        add_error(changeset, :trigger_config, ~s(missing required key "topic"))

      topic when is_binary(topic) and byte_size(topic) > 0 ->
        changeset

      _ ->
        add_error(changeset, :trigger_config, "\"topic\" must be a non-empty string")
    end
  end

  defp validate_trigger_config_for_kind(changeset, "webhook", config) do
    case Map.get(config, "path") || Map.get(config, :path) do
      nil ->
        add_error(changeset, :trigger_config, ~s(missing required key "path"))

      path when is_binary(path) and byte_size(path) > 0 ->
        changeset

      _ ->
        add_error(changeset, :trigger_config, "\"path\" must be a non-empty string")
    end
  end

  # Unknown / nil kind — the inclusion validator already surfaced an error;
  # silently pass to avoid double-counting.
  defp validate_trigger_config_for_kind(changeset, _other, _config), do: changeset

  # ── cron validation ────────────────────────────────────────────────────────

  # Lightweight cron grammar: 5 whitespace-separated fields (minute, hour,
  # day-of-month, month, day-of-week). Each field is `*`, a number, a range
  # `N-M`, a step `*/N` or `N-M/S`, or a comma-separated list of any of the
  # above. We don't validate field ranges (e.g. minute 0-59) because the
  # router does that at execution time — the changeset just needs to reject
  # garbage like "every monday at noon".
  defp valid_cron_expression?(expression) when is_binary(expression) do
    fields = String.split(String.trim(expression), ~r/\s+/, trim: true)

    length(fields) == 5 and Enum.all?(fields, &valid_cron_field?/1)
  end

  defp valid_cron_field?(field) do
    field
    |> String.split(",", trim: true)
    |> Enum.all?(&valid_cron_atom?/1)
  end

  # An "atom" is one comma-separated component: `*`, `N`, `N-M`, `*/S`, or
  # `N-M/S`. Numbers must be non-negative integers.
  defp valid_cron_atom?("*"), do: true

  defp valid_cron_atom?(atom) do
    case String.split(atom, "/", parts: 2) do
      [base, step] -> valid_cron_base?(base) and valid_cron_int?(step)
      [base] -> valid_cron_base?(base)
    end
  end

  defp valid_cron_base?("*"), do: true

  defp valid_cron_base?(base) do
    case String.split(base, "-", parts: 2) do
      [lo, hi] -> valid_cron_int?(lo) and valid_cron_int?(hi)
      [single] -> valid_cron_int?(single)
    end
  end

  defp valid_cron_int?(str) do
    case Integer.parse(str) do
      {n, ""} when n >= 0 -> true
      _ -> false
    end
  end
end
