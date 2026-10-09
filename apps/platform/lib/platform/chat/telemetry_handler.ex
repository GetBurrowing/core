defmodule Platform.Chat.TelemetryHandler do
  @moduledoc """
  Bridges Chat `:telemetry` events to the audit event store.

  Attach once in `Application.start/2` (after `Platform.Audit.TelemetryHandler.attach/0`):

      Platform.Chat.TelemetryHandler.attach()

  ## Handled events

    | Telemetry event                           | Audit event type             |
    |-------------------------------------------|------------------------------|
    | `[:platform, :chat, :space_created]`      | `"chat.space.created"`       |
    | `[:platform, :chat, :message_posted]`     | `"chat.message.posted"`      |
    | `[:platform, :chat, :message_edited]`     | `"chat.message.edited"`      |
    | `[:platform, :chat, :message_deleted]`    | `"chat.message.deleted"`     |
    | `[:platform, :chat, :participant_added]`  | `"chat.participant.added"`   |
    | `[:platform, :chat, :participant_removed]`| `"chat.participant.removed"` |
    | `[:platform, :chat, :reaction_added]`     | `"chat.reaction.added"`      |
    | `[:platform, :chat, :reaction_removed]`   | `"chat.reaction.removed"`    |
    | `[:platform, :chat, :pin_added]`          | `"chat.pin.added"`           |
    | `[:platform, :chat, :pin_removed]`        | `"chat.pin.removed"`         |
    | `[:platform, :chat, :canvas_created]`     | `"chat.canvas.created"`      |
    | `[:platform, :chat, :canvas_updated]`     | `"chat.canvas.updated"`      |
    | `[:platform, :chat, :attention_routed]`   | `"chat.attention.routed"`    |
    | `[:platform, :chat, :channel_reassigned]` | `"chat.channel.reassigned"`  |

  Note the shape of the audit `event_type`: this handler drops the `platform`
  segment and splits the action atom on its first underscore, so
  `[:platform, :chat, :channel_reassigned]` persists as
  `"chat.channel.reassigned"`. `Platform.Audit.TelemetryHandler` joins every
  segment verbatim instead (`"platform.chat.space_archived"`). The two event
  lists are disjoint on purpose: registering one event in both would write two
  audit rows for a single emit.

  Which handler a chat event belongs to is a live seam. The `chat_spaces`
  LIFECYCLE events (archive, delete, purge) sit on the audit handler, so a
  query for `"platform.chat.*"` will not see `channel_reassigned` even though
  it mutates the same table. Reassignment is registered here because it is a
  sidebar-shape event rather than a lifecycle one, and because this is the
  handler the stage specified. Moving the whole family onto one handler is
  worth doing, and is bigger than one event.
  """

  require Logger

  @handler_id "platform-chat-telemetry"

  @chat_events [
    [:platform, :chat, :space_created],
    [:platform, :chat, :message_posted],
    [:platform, :chat, :message_edited],
    [:platform, :chat, :message_deleted],
    [:platform, :chat, :participant_added],
    [:platform, :chat, :participant_removed],
    [:platform, :chat, :reaction_added],
    [:platform, :chat, :reaction_removed],
    [:platform, :chat, :pin_added],
    [:platform, :chat, :pin_removed],
    [:platform, :chat, :canvas_created],
    [:platform, :chat, :canvas_updated],
    [:platform, :chat, :attention_routed],
    # Task 019fd76a stage 3: a root-org admin moving a channel between orgs via
    # `Platform.Chat.Sidebar.reassign_channel/3`. Metadata carries the space
    # id, the acting user, and both org ids (`from_org_id` / `to_org_id`,
    # each omitted when it is nil). This is the only durable record of the
    # move: the write itself is an in-place `chat_spaces.org_id` update with
    # no history. Section rename, recolour and reorder have the same gap and
    # are deliberately NOT covered here (separate follow-up).
    [:platform, :chat, :channel_reassigned]
  ]

  @doc """
  Attach the handler to all registered chat telemetry events.

  Idempotent — a duplicate attach is a no-op (see
  `Platform.Audit.TelemetryHandler.attach/0` for the reasoning).
  """
  @spec attach() :: :ok
  def attach do
    case :telemetry.attach_many(@handler_id, @chat_events, &__MODULE__.handle_event/4, %{}) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc "Detach the handler (useful in tests)."
  def detach do
    :telemetry.detach(@handler_id)
  end

  @doc "Returns the list of telemetry events this handler is attached to."
  def events, do: @chat_events

  @doc false
  def handle_event(event_name, measurements, metadata, _config) do
    attrs = build_attrs(event_name, measurements, metadata)

    case Platform.Audit.record(attrs) do
      {:ok, _event} ->
        :ok

      {:error, changeset} ->
        Logger.warning(
          "Chat audit persist failed: #{inspect(changeset.errors)}",
          event: inspect(event_name)
        )
    end
  rescue
    error ->
      # Telemetry detaches handlers that raise — never let that happen.
      Logger.error(
        "Chat audit handler crashed: #{Exception.format(:error, error, __STACKTRACE__)}",
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
      resource_type: Map.get(metadata, :resource_type, "chat"),
      resource_id: resource_id_from(metadata),
      action: Map.get(metadata, :action, "execute") |> to_string(),
      metadata: build_metadata(measurements, metadata),
      session_id: Map.get(metadata, :session_id),
      ip_address: Map.get(metadata, :ip_address)
    }
  end

  # Try to extract a meaningful resource_id from the metadata map.
  defp resource_id_from(%{canvas_id: id}), do: to_string(id)
  defp resource_id_from(%{space_id: id}), do: to_string(id)
  defp resource_id_from(%{message_id: id}), do: to_string(id)
  defp resource_id_from(%{resource_id: id}), do: to_string(id)
  defp resource_id_from(_), do: nil

  # Maps [:platform, :chat, :space_created] → "chat.space.created"
  # Maps [:platform, :chat, :participant_added] → "chat.participant.added"
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
  # :chat → ["chat"]
  # :space_created → ["space", "created"]
  # :participant_added → ["participant", "added"]
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
