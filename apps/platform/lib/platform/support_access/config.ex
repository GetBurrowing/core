defmodule Platform.SupportAccess.Config do
  @moduledoc """
  Runtime configuration for vendor support access (task 01a1b362 stage 1,
  ADR 0059). Read from `config :platform, :support_access` at call time, which
  `config/runtime.exs` fills from the environment:

    * `SUPPORT_VENDOR_KEYS` -> `:vendor_keys`, the PUBLIC halves of the
      vendor's grant-signing keys as `kid:base64` pairs separated by commas or
      whitespace. More than one is allowed, for rotation. With none, the grant
      route answers 404 as if it did not exist.
    * `INSTALL_ID` -> `:install_id`, this install's id as the vendor knows it.
      A grant naming any other install is refused.
    * `SUPPORT_ACCESS_STATE_PATH` -> `:state_path`, the host state file.
    * `SUPPORT_SHELL_EVENTS_PATH` -> `:shell_events_path`, the host-written
      shell events JSONL.
    * `SUPPORT_VENDOR_NAME` -> `:vendor_name`, the display name only. Core
      never spells it.

  `SUPPORT_ACCESS_DEFAULT` is NOT read here: it is read once, by the
  migration that seeds the settings row.

  The limits (`:max_duration_s`, 4 h, and `:max_validity_s`, 300 s) are held
  in config so they are visible and testable, not in code paths.
  """

  @default_state_path "/var/lib/burrow-support/state.json"
  @default_events_path "/var/lib/burrow-support/events.jsonl"

  defp get(key, default), do: Keyword.get(all(), key, default)

  defp all, do: Application.get_env(:platform, :support_access, [])

  @doc "The configured vendor public keys as `%{kid => <<32 bytes>>}`."
  @spec vendor_keys() :: %{String.t() => binary()}
  def vendor_keys do
    case get(:vendor_keys, %{}) do
      keys when is_map(keys) -> keys
      raw when is_binary(raw) -> parse_keys(raw)
      _ -> %{}
    end
  end

  @doc "Whether any vendor key is configured. Without one the feature is absent."
  @spec configured?() :: boolean()
  def configured?, do: map_size(vendor_keys()) > 0

  @doc """
  Parses `SUPPORT_VENDOR_KEYS`. An entry that is not `kid:<32-byte key in
  base64 or base64url>` is dropped, so a typo removes one key instead of
  admitting a malformed one.
  """
  @spec parse_keys(String.t() | nil) :: %{String.t() => binary()}
  def parse_keys(nil), do: %{}

  def parse_keys(raw) when is_binary(raw) do
    raw
    |> String.split([",", " ", "\n", "\t"], trim: true)
    |> Enum.reduce(%{}, fn entry, acc ->
      with [kid, b64] when kid != "" <- String.split(entry, ":", parts: 2),
           {:ok, <<_::256>> = key} <- decode64(b64) do
        Map.put(acc, kid, key)
      else
        _ -> acc
      end
    end)
  end

  defp decode64(b64) do
    trimmed = String.trim_trailing(b64, "=")

    case Base.url_decode64(trimmed, padding: false) do
      {:ok, key} -> {:ok, key}
      :error -> Base.decode64(trimmed, padding: false)
    end
  end

  @doc "This install's id, or nil when `INSTALL_ID` is unset."
  @spec install_id() :: String.t() | nil
  def install_id do
    case get(:install_id, nil) do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  @doc "The repair SSH principal, `support-<INSTALL_ID>`, or nil."
  @spec principal() :: String.t() | nil
  def principal do
    case install_id() do
      nil -> nil
      id -> "support-" <> id
    end
  end

  @spec state_path() :: String.t()
  def state_path, do: get(:state_path, nil) || @default_state_path

  @spec shell_events_path() :: String.t()
  def shell_events_path, do: get(:shell_events_path, nil) || @default_events_path

  @doc "The vendor's display name, or nil. Display only."
  @spec vendor_name() :: String.t() | nil
  def vendor_name do
    case get(:vendor_name, nil) do
      name when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

  @doc "The longest session a grant may ask for, in seconds (4 h)."
  @spec max_duration_s() :: pos_integer()
  def max_duration_s, do: get(:max_duration_s, 14_400)

  @doc "The longest a signed grant request stays valid, in seconds."
  @spec max_validity_s() :: pos_integer()
  def max_validity_s, do: get(:max_validity_s, 300)

  @doc "Unsigned or badly signed requests allowed per client IP per hour."
  @spec junk_rate_per_hour() :: pos_integer()
  def junk_rate_per_hour, do: get(:junk_rate_per_hour, 30)

  @doc "Sign-in code lifetime, in seconds."
  @spec sign_in_code_ttl_s() :: pos_integer()
  def sign_in_code_ttl_s, do: get(:sign_in_code_ttl_s, 60)

  @doc "Sweeper tick, in milliseconds."
  @spec sweep_interval_ms() :: pos_integer()
  def sweep_interval_ms, do: get(:sweep_interval_ms, 60_000)
end
