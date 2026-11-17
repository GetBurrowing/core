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
  @changed_topic "responsibilities:changed"

  @type t :: %{
          expression: String.t() | nil,
          space_id: String.t() | nil,
          project_id: String.t() | nil,
          escalate_user_id: String.t() | nil,
          host_roles: [String.t()]
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
      host_roles: host_roles(fetch(config, "host_roles")) || @default_host_roles
    }
  end

  def read(_config), do: read(%{})

  @doc """
  Merges `attrs` (string or atom keys among `expression`, `space_id`,
  `project_id`, `escalate_user_id`, `host_roles`) into `current_config` and
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

  defp put(_acc, key, _value), do: {:error, {:unknown_key, key}}

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
