defmodule Platform.Terminal.Audit do
  @moduledoc """
  The audit trail of a terminal session: who opened it, who was refused, mode
  changes, close. Each event is one `audit_events` row.

  Metadata keys are an allowlist (`allowed_keys/0`). No frame, key, folder or
  payload can reach a row because there is no key to carry one.
  """

  alias Platform.Audit

  @allowed_keys ~w(actor_id runtime_id mode reason opened_at closed_at)a
  @max_runtime_id_bytes 128

  def allowed_keys, do: @allowed_keys

  @doc "Record one event. Returns `:ok` or `:error`; never raises."
  def record(action, actor_id, runtime_id, meta)
      when action in ~w(opened refused mode_changed closed) do
    metadata =
      meta
      |> Map.put(:actor_id, actor_id)
      |> Map.put(:runtime_id, bounded(runtime_id))
      |> Map.take(@allowed_keys)

    attrs = %{
      event_type: "terminal.session." <> action,
      actor_type: "user",
      actor_id: actor_id,
      resource_type: "terminal_session",
      resource_id: bounded(runtime_id),
      action: action,
      metadata: metadata
    }

    case Audit.record(attrs) do
      {:ok, _} -> :ok
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp bounded(id) when is_binary(id) and byte_size(id) <= @max_runtime_id_bytes, do: id
  defp bounded(_), do: "invalid"
end
