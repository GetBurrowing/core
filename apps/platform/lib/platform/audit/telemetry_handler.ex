defmodule Platform.Audit.TelemetryHandler do
  @moduledoc """
  Bridges `:telemetry` events to the audit event store.

  Attach once in `Application.start/2`:

      Platform.Audit.TelemetryHandler.attach()

  Any module can emit auditable events via standard telemetry:

      :telemetry.execute(
        [:platform, :auth, :login],
        %{system_time: System.system_time()},
        %{
          actor_id: user.id,
          actor_type: "user",
          action: "success",
          ip_address: "192.168.1.1"
        }
      )

  The handler converts the telemetry event into a persisted `Audit.Event`
  and broadcasts it to PubSub subscribers.
  """

  require Logger

  @handler_id "platform-audit-telemetry"

  @events [
    [:platform, :auth, :login],
    [:platform, :auth, :callback],
    [:platform, :auth, :logout],
    [:platform, :auth, :access_blocked]
  ]

  @doc "Attach the handler to all registered platform telemetry events."
  def attach do
    :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, %{})
  end

  @doc "Detach the handler (useful in tests)."
  def detach do
    :telemetry.detach(@handler_id)
  end

  @doc "Returns the list of telemetry events this handler is attached to."
  def events, do: @events

  @doc false
  def handle_event(event_name, measurements, metadata, _config) do
    attrs = build_attrs(event_name, measurements, metadata)

    case Platform.Audit.record(attrs) do
      {:ok, _event} ->
        :ok

      {:error, changeset} ->
        Logger.warning(
          "Audit persist failed: #{inspect(changeset.errors)}",
          event: inspect(event_name)
        )
    end
  rescue
    error ->
      # Telemetry detaches handlers that raise — never let that happen.
      Logger.error(
        "Audit handler crashed: #{Exception.format(:error, error, __STACKTRACE__)}",
        event: inspect(event_name)
      )
  end

  # -- Internals --

  defp build_attrs(event_name, measurements, metadata) do
    event_type = event_name |> Enum.map_join(".", &Atom.to_string/1)

    %{
      event_type: event_type,
      actor_id: Map.get(metadata, :actor_id),
      actor_type: Map.get(metadata, :actor_type, "system"),
      resource_type: Map.get(metadata, :resource_type),
      resource_id: Map.get(metadata, :resource_id),
      action: Map.get(metadata, :action, "execute") |> to_string(),
      metadata: build_metadata(measurements, metadata),
      session_id: Map.get(metadata, :session_id),
      ip_address: Map.get(metadata, :ip_address)
    }
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
