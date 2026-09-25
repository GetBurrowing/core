defmodule PlatformWeb.FederationWellKnownControllerTest do
  @moduledoc """
  Task 01a0d90f stage 2 (ADR 0054 section 1): `GET /.well-known/suite-federation`
  answers 404 while federation is off and the public descriptor while it is
  on. Both states are exercised in this one module, through the real router.
  """

  # async: false — flips the global :peer_federation_enabled app env.
  use PlatformWeb.ConnCase, async: false

  alias Platform.Federation.Peers.InstallIdentity
  alias Platform.Vault

  @path "/.well-known/suite-federation"

  setup do
    original = Application.fetch_env(:platform, :peer_federation_enabled)
    base_original = Application.fetch_env(:platform, :peer_federation_base_url)

    on_exit(fn ->
      restore(:peer_federation_enabled, original)
      restore(:peer_federation_base_url, base_original)
    end)

    :ok
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:platform, key, value)
  defp restore(key, :error), do: Application.delete_env(:platform, key)

  defp set_enabled(value), do: Application.put_env(:platform, :peer_federation_enabled, value)

  test "flag off: 404, and no identity is created", %{conn: conn} do
    set_enabled(false)

    conn = get(conn, @path)

    assert conn.status == 404
    assert json_response(conn, 404) == %{"errors" => %{"detail" => "Not Found"}}
    assert InstallIdentity.current() == nil
  end

  test "flag on: 200 with the descriptor", %{conn: conn} do
    set_enabled(true)
    Application.put_env(:platform, :peer_federation_base_url, "https://peer-a.example.test/")

    body = conn |> get(@path) |> json_response(200)

    %{install_id: install_id, kid: kid, public_key: pub} = InstallIdentity.current()

    assert body["protocol"] == "suite-federation/1"
    assert body["install_id"] == install_id
    assert body["base_url"] == "https://peer-a.example.test"
    assert body["inbox"] == "https://peer-a.example.test/federation/v1/inbox"
    assert body["display_name"] == "peer-a.example.test"

    assert [%{"kid" => ^kid, "alg" => "ed25519", "public_key" => b64}] = body["keys"]
    assert Base.url_decode64!(b64, padding: false) == pub

    {:ok, priv} = Vault.get(InstallIdentity.vault_slug(kid), accessor: {:system, nil})
    refute Base.url_decode64!(b64, padding: false) == priv
  end

  test "flag off then on in the same module flips 404 to 200", %{conn: conn} do
    set_enabled(false)
    assert conn |> get(@path) |> Map.fetch!(:status) == 404

    set_enabled(true)
    assert build_conn() |> get(@path) |> Map.fetch!(:status) == 200
  end

  test "the flag reads PEER_FEDERATION_ENABLED as exactly \"true\"" do
    Application.delete_env(:platform, :peer_federation_enabled)
    original = System.get_env("PEER_FEDERATION_ENABLED")

    on_exit(fn ->
      if original,
        do: System.put_env("PEER_FEDERATION_ENABLED", original),
        else: System.delete_env("PEER_FEDERATION_ENABLED")
    end)

    for value <- ["1", "TRUE", "yes", "true ", ""] do
      System.put_env("PEER_FEDERATION_ENABLED", value)
      refute Platform.Federation.Peers.Config.enabled?(), "#{inspect(value)} enabled federation"
    end

    System.put_env("PEER_FEDERATION_ENABLED", "true")
    assert Platform.Federation.Peers.Config.enabled?()
  end

  test "host-agnostic: answers on a chat-prefixed host too", %{conn: conn} do
    set_enabled(true)

    assert %{conn | host: "chat.example.test"} |> get(@path) |> Map.fetch!(:status) == 200
  end
end
