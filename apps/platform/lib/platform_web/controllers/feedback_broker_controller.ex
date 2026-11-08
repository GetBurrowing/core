defmodule PlatformWeb.FeedbackBrokerController do
  @moduledoc """
  The feedback broker's endpoints (task 01a1a6a5 stage 3), behind
  `PlatformWeb.Plugs.FeedbackBrokerGate` (404 when broker mode is off, 429
  past the per-IP budget). Both are unauthenticated.

    * `POST /api/feedback-broker/v1/issues`, body
      `{repository, fingerprint, installation, submission}`:
      201 `{repository, issue_number}` when created, 200 with the same keys
      for a duplicate.
    * `GET /api/feedback-broker/v1/issues/:fingerprint`: 200
      `{repository, issue_number, shipped}` or 404 `{"error": "not_found"}`.
      `shipped` (task 01a1b678 stage 4) is true once the issue closed as
      completed.
    * `POST /api/feedback-broker/v1/usage` (task 01a1b678 stage 2), body
      `{sharing_install_id, window, counts}`: 202 `{"accepted": n}`, or 422
      `{"error": "invalid_usage"}`. See `Platform.Sharing.UsageReceiver`.

  Errors are `{"error": <bounded code>}` only: 422 for validation codes, 429
  for `rate_limited`, 503 for retryable publisher states, 502 for a refused
  or misconfigured publisher. NOTHING from the request, its headers, GitHub's
  response or an exception is ever echoed. Routes are mounted with
  `log: false`, because Phoenix's request log prints parameters.
  """
  use PlatformWeb, :controller

  alias Platform.Feedback.BrokerServer
  alias Platform.Sharing.UsageReceiver

  @retryable ~w(publisher_unavailable publisher_rate_limited in_flight feedback_disabled)a
  @refused ~w(publisher_not_configured publisher_rejected publisher_bad_response unauthorized)a

  def create(conn, _params) do
    case BrokerServer.create(conn.body_params, conn.remote_ip) do
      {:ok, status, %{repository: repo, issue_number: number}} ->
        conn
        |> put_status(if(status == "created", do: 201, else: 200))
        |> json(%{repository: repo, issue_number: number})

      {:error, code} ->
        refuse(conn, code)
    end
  end

  def show(conn, %{"fingerprint" => fingerprint}) do
    case BrokerServer.find(fingerprint) do
      {:ok, %{repository: repo, issue_number: number} = found} ->
        json(conn, %{
          repository: repo,
          issue_number: number,
          shipped: Map.get(found, :shipped, false)
        })

      {:ok, nil} ->
        refuse(conn, :not_found)

      {:error, code} ->
        refuse(conn, code)
    end
  end

  def usage(conn, _params) do
    case UsageReceiver.record(conn.body_params) do
      {:ok, written} -> conn |> put_status(202) |> json(%{accepted: written})
      {:error, code} -> refuse(conn, code)
    end
  end

  defp refuse(conn, code) do
    conn |> put_status(status_for(code)) |> json(%{error: bounded(code)})
  end

  defp status_for(:not_found), do: 404
  defp status_for(:rate_limited), do: 429
  defp status_for(code) when code in @retryable, do: 503
  defp status_for(code) when code in @refused, do: 502
  defp status_for(_code), do: 422

  # The code is an atom produced server-side; it is still reduced to a safe
  # charset and length before it is written into a response.
  defp bounded(code) when is_atom(code),
    do: code |> Atom.to_string() |> String.replace(~r/[^a-z0-9_]/, "") |> String.slice(0, 48)

  defp bounded(_code), do: "invalid_arguments"
end
