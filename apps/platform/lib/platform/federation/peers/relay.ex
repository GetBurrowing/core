defmodule Platform.Federation.Peers.Relay do
  @moduledoc """
  What a `Platform.Federation.Peers.PeerConnection` sends for a shared-space
  message (task 01a0d90f stage 5, ADR 0054 section 3). Pure functions: the
  connection owns the queue, the subscriptions and the cursor.

  ## Which messages cross

  A message is relayed when it is in a shared space, top-level (no
  `thread_id`), not deleted, `content_type: "text"` with non-empty content,
  and NOT `metadata["source"] == "federation_inbound"`. That last rule is
  the loop guard: a message this install ingested from the peer is never
  sent back, and in v1 (one peer per space) it has nowhere else to go.

  ## Direction

  The owner sends `message.replicate`, the replica sends `message.submit`
  (owner-authoritative, ADR 0054). Every payload names the RECEIVER's space
  id (`remote_space_id` of our row), so the receiver resolves it against its
  own `(peer_id, local_space_id)` row.

  ## Payload

      %{"space_id" => <receiver's space id>, "message_id" => <our id>,
        "author" => %{"id" => <our participant id>, "name" => <display name>},
        "content" => <text, capped at 32 KB>, "sent_at" => <iso8601>}

  Only these fields leave the install. The author's user or agent id is
  never sent.
  """

  alias Platform.Chat.Message
  alias Platform.Federation.Peers.SharedSpace

  @content_cap_bytes 32 * 1024

  @doc "Maximum bytes of message content sent (32 KB)."
  def content_cap_bytes, do: @content_cap_bytes

  @doc "The envelope type a shared space's role sends."
  @spec type_for(String.t()) :: String.t()
  def type_for("owner"), do: "message.replicate"
  def type_for("replica"), do: "message.submit"

  @doc "True when `msg` should cross the relationship (see the moduledoc)."
  @spec relayable?(term()) :: boolean()
  def relayable?(%Message{metadata: %{"source" => "federation_inbound"}}), do: false

  def relayable?(%Message{
        thread_id: nil,
        deleted_at: nil,
        content_type: "text",
        content: content
      })
      when is_binary(content) and content != "",
      do: true

  def relayable?(_), do: false

  @doc """
  The queue item for `msg` in `shared`, or nil when it is not relayable.
  `shared` is a `%SharedSpace{}` or the connection's `%{id, role,
  remote_space_id}` entry.
  """
  @spec item_for(SharedSpace.t() | map(), Message.t()) :: map() | nil
  def item_for(shared, %Message{} = msg) do
    if relayable?(msg) do
      %{
        id: Platform.Types.UUIDv7.generate(),
        type: type_for(shared.role),
        payload: payload(shared, msg),
        relay: %{shared_id: shared.id, space_id: msg.space_id, message_id: msg.id}
      }
    end
  end

  @doc false
  def payload(shared, %Message{} = msg) do
    %{
      "space_id" => shared.remote_space_id,
      "message_id" => msg.id,
      "author" => %{
        "id" => msg.participant_id,
        "name" => msg.author_display_name || "Unknown"
      },
      "content" => cap(msg.content),
      "sent_at" => sent_at(msg.inserted_at)
    }
  end

  defp sent_at(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp sent_at(%NaiveDateTime{} = at), do: NaiveDateTime.to_iso8601(at)
  defp sent_at(_), do: nil

  defp cap(content) when byte_size(content) <= @content_cap_bytes, do: content
  defp cap(content), do: trim(binary_part(content, 0, @content_cap_bytes))

  defp trim(bin) do
    if String.valid?(bin) or bin == "",
      do: bin,
      else: trim(binary_part(bin, 0, byte_size(bin) - 1))
  end
end
