defmodule PlatformWeb.Dev.FakeDigitalOceanTest do
  @moduledoc """
  Task 01a10315 stage 2: dev stub mode's fake DigitalOcean, driven through
  the real client and through its control endpoints.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Platform.InstallsFixtures

  alias Platform.Installs.DigitalOcean
  alias Platform.Installs.Fake
  alias PlatformWeb.Dev.FakeDigitalOcean

  setup do
    use_fake_backend()
    :ok
  end

  defp control(method, path, body \\ nil) do
    conn =
      conn(method, path, body && Jason.encode!(body))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> FakeDigitalOcean.call([])

    {conn.status, Jason.decode!(conn.resp_body)}
  end

  test "a droplet created by tag is listed, turns active with an IP, and is deleted by tag" do
    {:ok, droplet} =
      DigitalOcean.create_droplet(%{
        install_id: "abc",
        name: "acme",
        region: "nyc3",
        size: "s-2vcpu-4gb",
        user_data: "#cloud-config\n"
      })

    assert {:ok, [%{"id" => id}]} = DigitalOcean.find_droplets_by_tag("suite-install-abc")
    assert id == droplet["id"]
    assert {:ok, []} = DigitalOcean.find_droplets_by_tag("suite-install-other")

    {:ok, active} = DigitalOcean.get_droplet(id)
    assert active["status"] == "active"
    assert DigitalOcean.public_ipv4(active) =~ "203.0.113."

    assert :ok = DigitalOcean.delete_droplets_by_tag("suite-install-abc")
    assert {:ok, []} = DigitalOcean.find_droplets_by_tag("suite-install-abc")

    assert {200, calls} = control(:get, "/_calls")
    assert calls["POST /v2/droplets"] == 1
    assert calls["POST /v2/droplets tag:suite-install-abc"] == 1
    assert calls["DELETE /v2/droplets"] == 1
  end

  test "firewall, records and sizes round-trip" do
    assert {:ok, fw} = DigitalOcean.ensure_firewall("abc")
    assert {:ok, ^fw} = DigitalOcean.ensure_firewall("abc")
    assert :ok = DigitalOcean.ensure_a_record("fake.invalid", "acme", "203.0.113.2")
    assert :ok = DigitalOcean.ensure_a_record("fake.invalid", "acme", "203.0.113.3")
    assert [%{"data" => "203.0.113.3"}] = Fake.all(:record)
    assert :ok = DigitalOcean.delete_records("fake.invalid", ["acme"])
    assert Fake.all(:record) == []
    assert :ok = DigitalOcean.delete_firewall("abc")
    assert Fake.all(:firewall) == []
    DigitalOcean.clear_sizes_cache()
    assert {:ok, %{"s-2vcpu-4gb" => 24, "s-4vcpu-8gb" => 48}} = DigitalOcean.sizes()
  end

  test "_fail injects a step failure; a bad step is refused" do
    assert {200, %{"ok" => true}} = control(:post, "/_fail", %{"step" => "install", "times" => 2})
    assert Fake.take_failure("install")
    assert Fake.take_failure("install")
    refute Fake.take_failure("install")

    assert {422, _} = control(:post, "/_fail", %{"step" => "droplet"})
    assert {200, _} = control(:post, "/_fail", %{"step" => "reserve"})
    assert {:error, {:http, 500}} = DigitalOcean.get_droplet(1)
  end

  test "_dns and _reset" do
    assert {200, _} = control(:post, "/_dns", %{"host" => "shop.example.test"})
    DigitalOcean.ensure_firewall("abc")
    assert {200, _} = control(:post, "/_reset")
    assert Fake.calls() == %{}
    assert Fake.all(:firewall) == []
  end
end
