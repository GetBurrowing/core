defmodule Platform.Installs.TeardownTest do
  @moduledoc """
  Task 01a10315 stage 2: `Platform.Installs.teardown/1` is one command, it
  confirms the tag's droplet list is empty before answering `:ok`, and a
  second call is a no-op.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureIO
  import Platform.InstallsFixtures

  alias Platform.Installs
  alias Platform.Installs.DigitalOcean
  alias Platform.Installs.Fake
  alias Platform.Installs.Runner

  defp ready_install! do
    {install, _} = create_install!()
    assert Runner.run(install.id) == :ready
    Installs.get(install.id)
  end

  defp count(key), do: Map.get(Fake.calls(), key, 0)

  test "deletes droplet, firewall and both records; the tag list is empty; again is a no-op" do
    use_fake_backend()
    install = ready_install!()
    tag = DigitalOcean.install_tag(install.id)
    Installs.subscribe(install.id)

    assert [_] = Fake.all(:droplet)
    assert [_] = Fake.all(:firewall)
    assert length(Fake.all(:record)) == 2

    assert :ok = Installs.teardown(install.slug)

    assert Fake.all(:droplet) == []
    assert Fake.all(:firewall) == []
    assert Fake.all(:record) == []
    assert {:ok, []} = DigitalOcean.find_droplets_by_tag(tag)

    gone = Installs.get(install.id)
    assert gone.status == "destroyed"
    assert gone.handover_sealed == nil
    assert_received {:install_updated, _}

    deletes = count("DELETE /v2/droplets")
    assert deletes == 1
    assert :ok = Installs.teardown(install.slug)
    assert :ok = Installs.teardown(install.id)
    assert count("DELETE /v2/droplets") == deletes
  end

  test "droplets still listed after the delete is {:error, :droplets_remain}" do
    wrap = fn conn, fake ->
      if conn.method == "DELETE" and conn.request_path == "/v2/droplets",
        do: Plug.Conn.send_resp(conn, 204, ""),
        else: fake.(conn)
    end

    use_fake_backend([], wrap)
    install = ready_install!()

    assert {:error, :droplets_remain} = Installs.teardown(install.slug)
    assert Installs.get(install.id).status == "destroying"
    # It looked more than once before giving up.
    assert count("GET /v2/droplets") >= 2
  end

  test "an unknown install is :not_found" do
    use_fake_backend()
    assert {:error, :not_found} = Installs.teardown("no-such-install")
    assert {:error, :not_found} = Installs.teardown(Ecto.UUID.generate())
  end

  test "a customer-domain install deletes its CNAME targets of ours, nothing else" do
    use_fake_backend()

    {install, _} =
      create_install!(%{"domain_mode" => "customer", "primary_host" => "shop.example.test"})

    Fake.resolve_dns("shop.example.test")
    Fake.resolve_dns("auth.shop.example.test")
    assert Runner.run(install.id) == :ready
    assert length(Fake.all(:record)) == 2

    assert :ok = Installs.teardown(install.slug)
    assert Fake.all(:record) == []
    assert Fake.calls()["DELETE /v2/domains/:zone/records/:id"] == 2
  end

  test "a customer-domain install with no zone configured creates and deletes no record" do
    use_fake_backend()

    {install, _} =
      create_install!(%{"domain_mode" => "customer", "primary_host" => "shop.example.test"})

    put_installs_env(dns_zone: nil)
    Fake.resolve_dns("shop.example.test")
    Fake.resolve_dns("auth.shop.example.test")
    assert Runner.run(install.id) == :ready
    assert Fake.all(:record) == []

    assert :ok = Installs.teardown(install.slug)
    refute Map.has_key?(Fake.calls(), "GET /v2/domains/:zone/records")
  end

  test "teardown stops a running run first" do
    use_fake_backend(fake_delay_ms: 60_000)
    {install, _} = create_install!()
    {pid, ref} = spawn_monitor(fn -> Runner.run(install.id) end)
    wait_until(fn -> Installs.get(install.id).droplet_id end)

    assert :ok = Installs.teardown(install.slug)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000
    assert Installs.get(install.id).status == "destroyed"
  end

  describe "mix burrow.install.teardown" do
    test "tears down by slug, twice, and refuses bad usage" do
      use_fake_backend()
      install = ready_install!()

      out = capture_io(fn -> Mix.Tasks.Burrow.Install.Teardown.run([install.slug]) end)
      assert out =~ "torn down: #{install.slug}"
      # Again: a no-op that still succeeds.
      out = capture_io(fn -> Mix.Tasks.Burrow.Install.Teardown.run([install.slug]) end)
      assert out =~ "torn down: #{install.slug}"

      assert_raise Mix.Error, ~r/usage: mix burrow.install.teardown/, fn ->
        Mix.Tasks.Burrow.Install.Teardown.run([])
      end

      assert_raise Mix.Error, ~r/no install "nope"/, fn ->
        Mix.Tasks.Burrow.Install.Teardown.run(["nope"])
      end
    end
  end
end
