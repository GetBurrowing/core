defmodule Platform.Vault.TelemetryHandler do
  @moduledoc """
  Bridges Vault `:telemetry` events to the audit event store.

  Attach once in `Application.start/2` (after `Platform.Audit.TelemetryHandler.attach/0`):

      Platform.Vault.TelemetryHandler.attach()

  Any Vault operation can emit auditable events via standard telemetry:

      :telemetry.execute(
        [:platform, :vault, :credential_used],
        %{system_time: System.system_time()},
        %{
          actor_id: user.id,
          actor_type: "user",
          resource_id: credential.slug,
          action: "read"
        }
      )

  The handler converts each telemetry event into a persisted `Audit.Event`
  and (via `Platform.Audit.record/1`) broadcasts it to PubSub subscribers.

  ## Handled events

    - `[:platform, :vault, :credential_created]` → `"vault.credential.created"`
    - `[:platform, :vault, :credential_used]`    → `"vault.credential.used"`
    - `[:platform, :vault, :credential_rotated]` → `"vault.credential.rotated"`
    - `[:platform, :vault, :credential_revoked]` → `"vault.credential.revoked"`
    - `[:platform, :vault, :access_granted]`     → `"vault.access.granted"`
    - `[:platform, :vault, :access_denied]`      → `"vault.access.denied"`
    - `[:platform, :vault, :oauth_refreshed]`    → `"vault.oauth.refreshed"`
    - `[:platform, :vault, :oauth_refresh_failed]` → `"vault.oauth.refresh_failed"`
  """

  require Logger

  @handler_id "platform-vault-telemetry"

  @vault_events [
    [:platform, :vault, :credential_created],
    [:platform, :vault, :credential_used],
    [:platform, :vault, :credential_rotated],
    [:platform, :vault, :credential_revoked],
    [:platform, :vault, :access_granted],
    [:platform, :vault, :access_denied],
    [:platform, :vault, :oauth_refreshed],
    [:platform, :vault, :oauth_refresh_failed]
  ]

  @doc "Attach the handler to all registered vault telemetry events."
  def attach do
    :telemetry.attach_many(@handler_id, @vault_events, &__MODULE__.handle_event/4, %{})
  end

  @doc "Detach the handler (useful in tests)."
  def detach do
    :telemetry.detach(@handler_id)
  end

  @doc "Returns the list of telemetry events this handler is attached to."
  def events, do: @vault_events

  @doc false
  def handle_event(event_name, measurements, metadata, _config) do
    attrs = build_attrs(event_name, measurements, metadata)

    case Platform.Audit.record(attrs) do
      {:ok, _event} ->
        :ok

      {:error, changeset} ->
        Logger.warning(
          "Vault audit persist failed: #{inspect(changeset.errors)}",
          event: inspect(event_name)
        )
    end
  rescue
    error ->
      # Telemetry detaches handlers that raise — never let that happen.
      Logger.error(
        "Vault audit handler crashed: #{Exception.format(:error, error, __STACKTRACE__)}",
        event: inspect(event_name)
      )
  end

  # -- Internals --

  defp build_attrs(event_name, measurements, metadata) do
    event_type = event_name_to_string(event_name)

    %{
      event_type: event_type,
      actor_id: Map.get(metadata, :actor_id),
      actor_type: Map.get(metadata, :actor_type, "system"),
      resource_type: Map.get(metadata, :resource_type, "credential"),
      resource_id: Map.get(metadata, :resource_id),
      action: Map.get(metadata, :action, "execute") |> to_string(),
      metadata: build_metadata(measurements, metadata),
      session_id: Map.get(metadata, :session_id),
      ip_address: Map.get(metadata, :ip_address)
    }
  end

  # Maps [:platform, :vault, :credential_used] → "vault.credential.used"
  # Maps [:platform, :vault, :oauth_refresh_failed] → "vault.oauth.refresh_failed"
  #
  # Strategy: strip the leading :platform prefix, then for each remaining atom
  # replace the FIRST underscore with "." (so :credential_used → "credential.used"
  # but :oauth_refresh_failed → "oauth.refresh_failed").
  defp event_name_to_string([:platform | rest]) do
    rest
    |> Enum.flat_map(&atom_to_segments/1)
    |> Enum.join(".")
  end

  defp event_name_to_string(event_name) do
    event_name
    |> Enum.flat_map(&atom_to_segments/1)
    |> Enum.join(".")
  end

  # Converts an atom to one or two string segments by splitting on the first "_".
  # :vault → ["vault"]
  # :credential_used → ["credential", "used"]
  # :oauth_refresh_failed → ["oauth", "refresh_failed"]
  defp atom_to_segments(atom) do
    str = Atom.to_string(atom)

    case String.split(str, "_", parts: 2) do
      [only] -> [only]
      [head, tail] -> [head, tail]
    end
  end

  @top_level_keys ~w(actor_id actor_type resource_type resource_id action session_id ip_address)a

  defp build_metadata(measurements, metadata) do
    metadata
    |> Map.drop(@top_level_keys)
    |> Map.merge(measurements)
    |> ensure_json_safe()
  end

  defp ensure_json_safe(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), ensure_json_safe(v)}
      {k, v} -> {to_string(k), ensure_json_safe(v)}
    end)
  end

  defp ensure_json_safe(v) when is_atom(v), do: Atom.to_string(v)
  defp ensure_json_safe(v) when is_tuple(v), do: Tuple.to_list(v) |> Enum.map(&ensure_json_safe/1)
  defp ensure_json_safe(v) when is_list(v), do: Enum.map(v, &ensure_json_safe/1)
  defp ensure_json_safe(v) when is_pid(v), do: inspect(v)
  defp ensure_json_safe(v) when is_reference(v), do: inspect(v)
  defp ensure_json_safe(v) when is_function(v), do: inspect(v)
  defp ensure_json_safe(v), do: v
end
