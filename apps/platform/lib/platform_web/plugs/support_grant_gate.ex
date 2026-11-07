defmodule PlatformWeb.Plugs.SupportGrantGate do
  @moduledoc """
  Gate for `POST /api/support-access/v1/grants` (task 01a1b362 stage 1, ADR
  0059). Mirrors `PlatformWeb.Plugs.FeedbackBrokerGate`:

    * no vendor key configured (`SUPPORT_VENDOR_KEYS` unset) -> the same 404
      as a route that does not exist, and nothing is read;
    * a client IP over its hourly budget of failed-signature requests
      (`Platform.SupportAccess.JunkLimit`) -> 429, nothing read.

  The path is on `PlatformWeb.Plugs.RawBodyPaths`' skip-list, so the
  controller reads the raw body itself with a cap: the signature covers the
  exact bytes.
  """

  import Plug.Conn

  alias Platform.SupportAccess.Config
  alias Platform.SupportAccess.JunkLimit

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      not Config.configured?() ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(%{errors: %{detail: "Not Found"}}))
        |> halt()

      not JunkLimit.allowed?(conn.remote_ip, Config.junk_rate_per_hour()) ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(429, Jason.encode!(%{error: "rate_limited"}))
        |> halt()

      true ->
        conn
    end
  end
end
