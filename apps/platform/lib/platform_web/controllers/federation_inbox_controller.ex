defmodule PlatformWeb.FederationInboxController do
  @moduledoc """
  `POST /federation/v1/inbox`: one signed peer envelope per request (task
  01a0d90f stage 3, ADR 0054 section 2).

  Runs behind the `:peer_envelope` pipeline, so by the time `create/2` runs
  `PlatformWeb.Plugs.VerifyPeerEnvelope` has read the capped body and
  `conn.assigns.peer_envelope` holds a verified envelope. The handler is
  `Platform.Federation.Peers.Inbound.handle/1`.

  The response carries only a result or reason atom. It never echoes the
  request.
  """

  use PlatformWeb, :controller

  alias Platform.Federation.Peers.Config
  alias Platform.Federation.Peers.Inbound

  def create(conn, _params) do
    with true <- Config.enabled?(),
         %{} = verified <- conn.assigns[:peer_envelope] do
      case Inbound.handle(verified) do
        {:ok, result} ->
          json(conn, %{ok: true, result: to_string(result)})

        # Stage 5: the answer names a LOCAL id the peer needs (the replica
        # space for `space.share`, the stored message for a relay type).
        # Never request bytes.
        {:ok, result, data} when is_map(data) ->
          json(conn, %{ok: true, result: to_string(result), data: data})

        {:error, reason} ->
          conn
          |> put_status(status_for(reason))
          |> json(%{error: to_string(reason)})
      end
    else
      _ ->
        conn
        |> put_status(:not_found)
        |> json(%{errors: %{detail: "Not Found"}})
    end
  end

  defp status_for(:proposal_rate_limited), do: 429
  defp status_for(:unsupported_type), do: 400
  defp status_for(:invalid_proposal), do: 400
  defp status_for(:invalid_key), do: 400
  defp status_for(:descriptor_unavailable), do: 422
  defp status_for(:descriptor_mismatch), do: 422
  defp status_for(:peer_not_active), do: 403
  defp status_for(:rotation_needs_current_kid), do: 403
  defp status_for(:unknown_peer), do: 403
  defp status_for(:invalid_payload), do: 400
  defp status_for(:unknown_shared_space), do: 404
  defp status_for(:wrong_space_role), do: 403
  defp status_for(:share_limit_reached), do: 429
  defp status_for(:ingest_failed), do: 503
  defp status_for(_conflict), do: 409
end
