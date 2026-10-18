defmodule PlatformWeb.FederationWellKnownController do
  @moduledoc """
  `GET /.well-known/suite-federation` and `GET /.well-known/burrow-federation`
  (the latter added by task 01a14ba9 stage 1, same body): this install's public
  federation descriptor (task 01a0d90f stage 2, ADR 0054 section 1).

  Answers 404 unless `Platform.Federation.Peers.Config.enabled?/0`. The 404
  is the same body a route that does not exist would give, so an install with
  federation off does not advertise that the feature exists.

  The body is `Platform.Federation.Peers.InstallIdentity.descriptor/0`:
  install_id, display_name, base_url, inbox and PUBLIC keys only. The first
  request with the flag on creates the identity lazily.
  """

  use PlatformWeb, :controller

  alias Platform.Federation.Peers.Config
  alias Platform.Federation.Peers.InstallIdentity

  def show(conn, _params) do
    if Config.enabled?() do
      conn
      |> put_resp_header("cache-control", "no-cache")
      |> json(InstallIdentity.descriptor())
    else
      conn
      |> put_status(:not_found)
      |> json(%{errors: %{detail: "Not Found"}})
    end
  end
end
