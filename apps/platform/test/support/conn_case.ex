defmodule PlatformWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use PlatformWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Repo

  using do
    quote do
      # The default endpoint for testing
      @endpoint PlatformWeb.Endpoint

      use PlatformWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import PlatformWeb.ConnCase
    end
  end

  setup tags do
    :ok = Sandbox.checkout(Repo)

    unless tags[:async] do
      Sandbox.mode(Repo, {:shared, self()})
    end

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  POST a GitHub webhook payload with a real `X-Hub-Signature-256` over the
  real raw request body.

  `Plug.Test` encodes a map body as `multipart/mixed; boundary=plug_conn_test`
  with the literal body `"--plug_conn_test--"`, so `conn.assigns[:raw_body]`
  never holds the JSON GitHub actually signs. Encoding the payload ourselves
  and sending it as `application/json` routes the request through
  `Plug.Parsers` -> `PlatformWeb.Plugs.CacheBodyReader`, which is what makes
  `raw_body` real and the HMAC meaningful.

  Options:

    * `:secret` — sign with this secret instead of the app-level
      `:github_webhook_secret` (used to exercise the mismatch path).
    * `:signature` — send this exact header value verbatim (used to exercise
      malformed headers and body-tamper cases). Pass `nil` to send no
      signature header at all.
    * `:body` — send these exact bytes instead of `Jason.encode!(payload)`.
      The signature is still computed over `payload`, which is how a
      body-tamper test is expressed.
  """
  def signed_github_post(conn, path, payload, opts \\ []) do
    signed_body = Keyword.get_lazy(opts, :signed_body, fn -> Jason.encode!(payload) end)
    body = Keyword.get(opts, :body, signed_body)
    secret = Keyword.get(opts, :secret) || Application.get_env(:platform, :github_webhook_secret)

    signature =
      case Keyword.fetch(opts, :signature) do
        {:ok, value} -> value
        :error -> "sha256=" <> github_hmac(signed_body, secret)
      end

    conn
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> maybe_put_signature(signature)
    |> Phoenix.ConnTest.dispatch(PlatformWeb.Endpoint, :post, path, body)
  end

  @doc """
  POST a GitHub webhook payload as real JSON bytes with NO signature header.
  """
  def unsigned_github_post(conn, path, payload) do
    signed_github_post(conn, path, payload, signature: nil)
  end

  @doc """
  Lowercase hex HMAC-SHA256 of `body` under `secret` — the digest half of a
  GitHub `X-Hub-Signature-256` header.
  """
  def github_hmac(body, secret) do
    :hmac |> :crypto.mac(:sha256, secret, body) |> Base.encode16(case: :lower)
  end

  defp maybe_put_signature(conn, nil), do: conn

  defp maybe_put_signature(conn, signature),
    do: Plug.Conn.put_req_header(conn, "x-hub-signature-256", signature)
end
