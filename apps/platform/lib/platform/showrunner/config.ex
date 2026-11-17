defmodule Platform.Showrunner.Config do
  @moduledoc """
  The showrunner's per-install configuration, held in each `showrunner.*`
  responsibility row's `trigger_config` (task 01a1eaf6 stage 3).

  Nothing here is in code. A space, a project and the person decisions go to
  are data an operator writes:

    * `"expression"` — the cron the Router runs (each key declares a default);
    * `"space_id"` — the show's chat space: its episode canvases, its messages
      and its `space/<id>/journal/` memory;
    * `"project_id"` — optional, the project the show's work is filed under;
    * `"escalate_user_id"` — the person who gets ONE inbox row per human
      decision (topic pick, cold open, guest yes/no);
    * `"host_roles"` — the hosts, by role ("host", "co-host"), never by id.
      Talking points are keyed by these.

  Recording logistics (task 01a1eaf6 stage 4, `showrunner.recording_prep`):

    * `"host_user_ids"` — whose calendars the recording is proposed on;
      unset means the escalate user's alone;
    * `"record_weekday"` (1 = Monday .. 7 = Sunday, default 4),
      `"record_time"` (`"HH:MM"`, default `"19:00"`) and
      `"record_time_zone"` (IANA, default `"Etc/UTC"`) — the default slot;
    * `"record_minutes"` (default 60) — how long the slot holds;
    * `"window_hours"` (default 4) — how far past the default slot a clash
      may move the recording, in 30-minute steps.

  `to_trigger/2` is the `Platform.Responsibilities.GoalCadence`-style write:
  it merges the operator's attrs into the row's current config and stamps
  `"operator_set" => true`, the marker that makes
  `Platform.Responsibilities.upsert_by_key/1` keep the config across the
  boot-time re-registration instead of reverting it to the declared default.
  `configure/3` is the admin-gated write that persists it and reloads the
  Router's cron bucket.
  """

  alias Platform.Responsibilities
  alias Platform.Responsibilities.Cron
  alias Platform.Responsibilities.Responsibility
  alias Platform.Tenancy

  @id_keys ~w(space_id project_id escalate_user_id)
  @default_host_roles ["host", "co-host"]
  @recording_defaults %{
    weekday: 4,
    time: "19:00",
    time_zone: "Etc/UTC",
    minutes: 60,
    window_hours: 4
  }
  @changed_topic "responsibilities:changed"

  @type t :: %{
          expression: String.t() | nil,
          space_id: String.t() | nil,
          project_id: String.t() | nil,
          escalate_user_id: String.t() | nil,
          host_roles: [String.t()],
          host_user_ids: [String.t()],
          recording: %{
            weekday: 1..7,
            time: String.t(),
            time_zone: String.t(),
            minutes: pos_integer(),
            window_hours: pos_integer()
          }
        }

  @doc "The host roles used when the row names none."
  @spec default_host_roles() :: [String.t()]
  def default_host_roles, do: @default_host_roles

  @doc "Reads a row's config. An invalid id reads as nil; never raises."
  @spec read(Responsibility.t() | map() | nil) :: t()
  def read(%Responsibility{trigger_config: config}), do: read(config)

  def read(config) when is_map(config) do
    %{
      expression: string(fetch(config, "expression")),
      space_id: uuid(fetch(config, "space_id")),
      project_id: uuid(fetch(config, "project_id")),
      escalate_user_id: uuid(fetch(config, "escalate_user_id")),
      host_roles: host_roles(fetch(config, "host_roles")) || @default_host_roles,
      host_user_ids: user_ids(fetch(config, "host_user_ids")) || [],
      recording: %{
        weekday: weekday(fetch(config, "record_weekday")) || @recording_defaults.weekday,
        time: clock(fetch(config, "record_time")) || @recording_defaults.time,
        time_zone: zone(fetch(config, "record_time_zone")) || @recording_defaults.time_zone,
        minutes: positive(fetch(config, "record_minutes"), 1..240) || @recording_defaults.minutes,
        window_hours:
          positive(fetch(config, "window_hours"), 1..48) || @recording_defaults.window_hours
      }
    }
  end

  def read(_config), do: read(%{})

  @doc """
  Merges `attrs` (string or atom keys among `expression`, `space_id`,
  `project_id`, `escalate_user_id`, `host_roles`, `host_user_ids`,
  `record_weekday`, `record_time`, `record_time_zone`, `record_minutes`,
  `window_hours`) into `current_config` and
  stamps `"operator_set" => true`. A nil value clears that key. Refuses an
  unparseable expression, a malformed id and a blank host role.
  """
  @spec to_trigger(map(), map()) :: {:ok, map()} | {:error, term()}
  def to_trigger(current_config, attrs) when is_map(current_config) and is_map(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    Enum.reduce_while(attrs, {:ok, current_config}, fn {key, value}, {:ok, acc} ->
      case put(acc, key, value) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, config} -> {:ok, Map.put(config, "operator_set", true)}
      error -> error
    end
  end

  def to_trigger(_current_config, _attrs), do: {:error, :attrs_must_be_a_map}

  @doc """
  Admin write of `key`'s config: `Platform.Tenancy.root_admin?/1` or
  `{:error, :forbidden}`. Persists the merged config and broadcasts the cron
  reload, as `Platform.Responsibilities.set_cron_cadence/4` does.
  """
  @spec configure(term(), String.t(), map()) :: {:ok, Responsibility.t()} | {:error, term()}
  def configure(actor, key, attrs) when is_binary(key) and is_map(attrs) do
    with true <- Tenancy.root_admin?(actor) || {:error, :forbidden},
         %Responsibility{} = row <- Responsibilities.get_by_key(key) || {:error, :not_found},
         {:ok, config} <- to_trigger(row.trigger_config || %{}, attrs),
         {:ok, updated} <- Responsibilities.update_responsibility(row, %{trigger_config: config}) do
      Phoenix.PubSub.broadcast(
        Platform.PubSub,
        @changed_topic,
        {:responsibilities_changed, :cron}
      )

      {:ok, updated}
    end
  end

  defp put(acc, "expression", nil), do: {:ok, Map.delete(acc, "expression")}

  defp put(acc, "expression", expression) when is_binary(expression) do
    case Cron.parse(expression) do
      {:ok, _} -> {:ok, Map.put(acc, "expression", String.trim(expression))}
      {:error, _} -> {:error, {:bad_expression, expression}}
    end
  end

  defp put(acc, key, nil) when key in @id_keys, do: {:ok, Map.delete(acc, key)}

  defp put(acc, key, value) when key in @id_keys do
    case uuid(value) do
      nil -> {:error, {:bad_id, key}}
      id -> {:ok, Map.put(acc, key, id)}
    end
  end

  defp put(acc, "host_roles", nil), do: {:ok, Map.delete(acc, "host_roles")}

  defp put(acc, "host_roles", roles) do
    case host_roles(roles) do
      nil -> {:error, :bad_host_roles}
      roles -> {:ok, Map.put(acc, "host_roles", roles)}
    end
  end

  defp put(acc, "host_user_ids", nil), do: {:ok, Map.delete(acc, "host_user_ids")}

  defp put(acc, "host_user_ids", ids) do
    case user_ids(ids) do
      nil -> {:error, {:bad_id, "host_user_ids"}}
      ids -> {:ok, Map.put(acc, "host_user_ids", ids)}
    end
  end

  defp put(acc, key, nil)
       when key in ~w(record_weekday record_time record_time_zone record_minutes window_hours),
       do: {:ok, Map.delete(acc, key)}

  defp put(acc, "record_weekday", value), do: put_valid(acc, "record_weekday", weekday(value))
  defp put(acc, "record_time", value), do: put_valid(acc, "record_time", clock(value))
  defp put(acc, "record_time_zone", value), do: put_valid(acc, "record_time_zone", zone(value))

  defp put(acc, "record_minutes", value),
    do: put_valid(acc, "record_minutes", positive(value, 1..240))

  defp put(acc, "window_hours", value),
    do: put_valid(acc, "window_hours", positive(value, 1..48))

  defp put(_acc, key, _value), do: {:error, {:unknown_key, key}}

  defp put_valid(_acc, key, nil), do: {:error, {:bad_value, key}}
  defp put_valid(acc, key, value), do: {:ok, Map.put(acc, key, value)}

  defp user_ids([_ | _] = ids) do
    valid = Enum.map(ids, &uuid/1)
    if Enum.all?(valid, &is_binary/1), do: Enum.uniq(valid), else: nil
  end

  defp user_ids(_), do: nil

  defp weekday(n) when is_integer(n) and n in 1..7, do: n
  defp weekday(_), do: nil

  defp clock(value) when is_binary(value) do
    case Time.from_iso8601(String.trim(value) <> ":00") do
      {:ok, _} -> String.trim(value)
      _ -> nil
    end
  end

  defp clock(_), do: nil

  defp zone(value) when is_binary(value) and value != "" do
    case DateTime.now(value) do
      {:ok, _} -> value
      _ -> nil
    end
  end

  defp zone(_), do: nil

  defp positive(n, range) when is_integer(n), do: if(n in range, do: n, else: nil)
  defp positive(_n, _range), do: nil

  defp fetch(config, key) do
    case Map.fetch(config, key) do
      {:ok, value} -> value
      :error -> Map.get(config, String.to_existing_atom(key))
    end
  rescue
    ArgumentError -> nil
  end

  defp string(value) when is_binary(value) and value != "", do: value
  defp string(_), do: nil

  defp uuid(value) when is_binary(value) do
    if Platform.UUID.valid?(value), do: value, else: nil
  end

  defp uuid(_), do: nil

  defp host_roles([_ | _] = roles) do
    trimmed = Enum.map(roles, &(is_binary(&1) && String.trim(&1)))
    if Enum.all?(trimmed, &(is_binary(&1) and &1 != "")), do: Enum.uniq(trimmed), else: nil
  end

  defp host_roles(_), do: nil
end
