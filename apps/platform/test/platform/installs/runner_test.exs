defmodule Platform.Installs.RunnerTest do
  @moduledoc """
  Task 01a10315 stage 2: the restartable step machine, against dev stub
  mode's fake DigitalOcean (`Platform.InstallsFixtures.use_fake_backend/2`).
  The droplet count is read from the fake's own per-call counter.
  """
  use Platform.DataCase, async: false

  import Platform.InstallsFixtures

  alias Platform.Installs
  alias Platform.Installs.DigitalOcean
  alias Platform.Installs.Fake
  alias Platform.Installs.Runner

  defp posts, do: Map.get(Fake.calls(), "POST /v2/droplets", 0)
  defp step(install, key), do: Enum.find(install.steps, &(&1["key"] == key))

  describe "happy path" do
    setup do
      use_fake_backend()
      :ok
    end

    test "runs reserve, install, connect and final to ready" do
      {install, _token} = create_install!()
      Installs.subscribe(install.id)

      assert install.status == "queued"
      assert Enum.map(install.steps, & &1["state"]) == ~w(pending pending pending pending)

      assert Runner.run(install.id) == :ready

      install = Installs.get(install.id)
      assert install.status == "ready"
      assert install.ready_at
      assert Enum.map(install.steps, & &1["key"]) == ~w(reserve install connect final)

      for step <- install.steps do
        assert step["state"] == "done"
        assert step["started_at"] && step["finished_at"]
        assert step["error"] == nil
      end

      assert is_integer(install.droplet_id)
      assert install.droplet_ip =~ ~r/^203\.0\.113\.\d+$/
      assert "fw-" <> _ = install.firewall_id
      assert posts() == 1
      assert Map.get(Fake.calls(), "POST /v2/firewalls", 0) == 1

      # Ours mode: <slug>.<zone> and auth.<slug>.<zone> point at the droplet.
      names = Fake.all(:record) |> Enum.map(&{&1["name"], &1["data"]}) |> Enum.sort()
      assert names == [{"auth." <> install.slug, install.droplet_ip}, {install.slug, install.droplet_ip}]

      # The render's two kept values were sealed before the droplet existed.
      assert {:ok, sealed} = Installs.unseal(install)
      assert Map.keys(sealed) |> Enum.sort() == ~w(oidc_client_secret ssh_private_key static_api_key)

      assert_received {:install_updated, id} when id == install.id
    end

    test "a second run of a ready install does nothing" do
      {install, _} = create_install!()
      assert Runner.run(install.id) == :ready
      calls = Fake.calls()
      assert Runner.run(install.id) == :ready
      assert Fake.calls() == calls
    end
  end

  describe "crash after the droplet POST, before droplet_id is saved" do
    test "the resumed run finds the droplet by tag: exactly ONE POST /v2/droplets" do
      wrap = fn conn, fake ->
        conn = fake.(conn)

        if conn.method == "POST" and conn.request_path == "/v2/droplets" and
             :persistent_term.get({__MODULE__, :kill}, false) do
          :persistent_term.put({__MODULE__, :kill}, false)
          Process.exit(self(), :kill)
        end

        conn
      end

      :persistent_term.put({__MODULE__, :kill}, true)
      on_exit(fn -> :persistent_term.erase({__MODULE__, :kill}) end)
      use_fake_backend([], wrap)

      {install, _} = create_install!()

      {pid, ref} = spawn_monitor(fn -> Runner.run(install.id) end)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000

      crashed = Installs.get(install.id)
      assert crashed.droplet_id == nil, "the kill must land between the POST and the save"
      assert crashed.status == "provisioning"
      assert posts() == 1
      eventually(fn -> Runner.whereis(install.id) == nil end)

      # What resume_all/0 does at boot for a provisioning install.
      assert Runner.run(install.id) == :ready
      assert posts() == 1
      assert [_one] = Fake.all(:droplet)
      assert Installs.get(install.id).droplet_id == hd(Fake.all(:droplet))["id"]
    end
  end

  describe "failure and retry" do
    setup do
      use_fake_backend()
      :ok
    end

    test "an injected failure fails the step; retry/2 completes with still one droplet" do
      {install, token} = create_install!()
      Fake.inject_failure("install", 1)

      assert Runner.run(install.id) == :failed

      failed = Installs.get(install.id)
      assert failed.status == "failed"
      assert step(failed, "reserve")["state"] == "done"
      assert step(failed, "install")["state"] == "failed"
      assert step(failed, "install")["error"] == "Something went wrong on our side."
      assert step(failed, "connect")["state"] == "pending"

      assert {:error, :unauthorized} = Installs.retry(failed, "not-the-token")
      assert {:ok, queued} = Installs.retry(failed, token)
      assert queued.status == "queued"
      assert step(queued, "install")["state"] == "pending"
      assert step(queued, "install")["error"] == nil

      assert Runner.run(install.id) == :ready
      assert posts() == 1
      assert {:error, :not_failed} = Installs.retry(Installs.get(install.id), token)
    end

    test "a step past its deadline fails with plain words" do
      # The fake droplet stays "new" for a minute; reserve gives up after 30 ms.
      put_installs_env(fake_delay_ms: 60_000, step_timeouts_ms: %{"reserve" => 30})
      {install, _} = create_install!()

      assert Runner.run(install.id) == :failed
      assert step(Installs.get(install.id), "reserve")["error"] == "This step took longer than expected."
    end

    test "a refused droplet create fails reserve and names no infrastructure" do
      wrap = fn conn, fake ->
        if conn.method == "POST" and conn.request_path == "/v2/droplets",
          do: conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{"id" => "forbidden"}),
          else: fake.(conn)
      end

      use_fake_backend([], wrap)
      {install, _} = create_install!()

      assert Runner.run(install.id) == :failed
      error = step(Installs.get(install.id), "reserve")["error"]
      assert error == "Our hosting provider refused the request."
      refute error =~ ~r/droplet|firewall|cloud-init|DNS record/i
    end
  end

  describe "customer domain" do
    setup do
      use_fake_backend()
      :ok
    end

    test "waits in connect until both hosts resolve, then completes" do
      {install, _} =
        create_install!(%{"domain_mode" => "customer", "primary_host" => "Suite.Acme.example.test"})

      assert install.primary_host == "suite.acme.example.test"

      {pid, ref} = spawn_monitor(fn -> Runner.run(install.id) end)

      waiting =
        eventually(fn ->
          i = Installs.get(install.id)
          step(i, "connect")["state"] == "running" && i
        end)

      Process.sleep(50)
      assert Installs.get(install.id).status == "provisioning"
      assert step(Installs.get(install.id), "connect")["state"] == "running"
      assert step(waiting, "install")["state"] == "done"
      # No A record of ours for a customer's domain.
      assert Fake.all(:record) == []

      Fake.resolve_dns("suite.acme.example.test")
      Fake.resolve_dns("auth.suite.acme.example.test")

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
      assert Installs.get(install.id).status == "ready"
    end
  end

  describe "runs" do
    setup do
      use_fake_backend()
      :ok
    end

    test "one install never has two runs" do
      {install, _} = create_install!()
      put_installs_env(fake_delay_ms: 60_000)

      {pid, ref} = spawn_monitor(fn -> Runner.run(install.id) end)
      eventually(fn -> Runner.whereis(install.id) end)
      assert Runner.run(install.id) == :already_running

      Runner.stop(install.id)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000
      eventually(fn -> Runner.whereis(install.id) == nil end)
    end

    test "resume_all restarts provisioning installs and leaves ready ones" do
      put_installs_env(start_runs: true)
      {install, _} = create_install!()
      eventually(fn -> Installs.get(install.id).status == "ready" end)

      {stuck, _} = create_install!(%{"business_name" => "Second Shop"})
      eventually(fn -> Installs.get(stuck.id).status == "ready" end)
      # As if the node died mid-run, before droplet_id was saved.
      Installs.update!(Installs.get(stuck.id), %{
        status: "provisioning",
        steps: Runner.initial_steps(),
        droplet_id: nil
      })

      calls_before = posts()
      assert :ok = Installs.resume_all()
      eventually(fn -> Installs.get(stuck.id).status == "ready" end)
      # It found its droplet by tag: no new POST.
      assert posts() == calls_before
      assert Installs.get(install.id).status == "ready"
      tagged = Enum.filter(Fake.all(:droplet), &(DigitalOcean.install_tag(stuck.id) in &1["tags"]))
      assert [%{"id" => id}] = tagged
      assert Installs.get(stuck.id).droplet_id == id
    end
  end
end
