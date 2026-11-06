defmodule PlatformWeb.Plugs.FeedbackBrokerGate do
  @moduledoc """
  Gate for the feedback broker routes (task 01a1a6a5 stage 3). Mirrors
  `PlatformWeb.Plugs.PushRelayAuth`, minus authentication: installs hold no
  broker credential, so every request is treated as hostile.

    * broker mode off (`Platform.Feedback.BrokerServer.enabled?/0` false) ->
      404 `{"error": "not_found"}`, so a normal install exposes nothing here;
    * more than `BrokerServer.rate_per_hour/0` requests from one client IP in
      the current hour -> 429 `{"error": "rate_limited"}` with `retry-after`.

  The IP is `conn.remote_ip`, which `PlatformWeb.Plugs.RewriteRemoteIp` (in
  the endpoint, before the router) has already set from `X-Forwarded-For`
  when `TRUST_PROXY_HEADERS` is on. Behind Cloudflare and Caddy that flag
  must be on, or every request shares the proxy's bucket.
  """

  import Plug.Conn

  alias Platform.Feedback.BrokerRateLimit
  alias Platform.Feedback.BrokerServer

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      not BrokerServer.enabled?() ->
        refuse(conn, 404, "not_found")

      BrokerRateLimit.check(conn.remote_ip, BrokerServer.rate_per_hour()) != :ok ->
        conn
        |> put_resp_header(
          "retry-after",
          Integer.to_string(BrokerRateLimit.retry_after_seconds())
        )
        |> refuse(429, "rate_limited")

      true ->
        conn
    end
  end

  defp refuse(conn, status, error) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: error}))
    |> halt()
  end
end
