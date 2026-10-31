defmodule Platform.Installs.ProviderHardeningTest do
  @moduledoc """
  Task 01a10315 stage 6, the three defects the real-droplet review found,
  against dev stub mode's fake DigitalOcean:

    * root's key is registered as an account SSH key and named in the droplet
      create (`ssh_keys`), so the provider does not expire root's password;
      teardown deletes it, and a second teardown deletes nothing;
    * a size the region does not offer: DigitalOcean's 422 at reserve is a
      plain-words failure (the fake answers 422 for nyc3, as DO did);
    * a server that never finishes installing fails in plain words, and Retry
      restarts it (`POST /v2/droplets/:id/actions` reboot).

  Mutants these name:

    * drop `ssh_keys` from the create → "the droplet create names root's key";
    * skip `delete_ssh_key/1` in teardown → "teardown deletes the account key";
    * create a key without looking it up first → "registered once, across a
      resumed run";
    * drop the 422 clause of `describe_error/2` → the 422 test reads the
      generic copy instead;
    * drop `maybe_reboot/1` from `retry/2` → the retry test sees no reboot.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.InstallsFixtures

  alias Platform.Installs
  alias Platform.Installs.DigitalOcean
  alias Platform.Installs.Fake
  alias Platform.Installs.Install
  alias Platform.Installs.Runner
  alias Platform.Repo

  defmodule StuckProbe do
    @moduledoc "A server whose stack never answers; everything else as the fake."
    @behaviour Platform.Installs.Probe

    @impl true
    def http_up(_install), do: {:wait, :stack_not_up}

    @impl true
    def dns_ready(install, hosts), do: Fake.dns_ready(install, hosts)

    @impl true
    def https_health(install), do: Fake.https_health(install)
  end

  defp count(key), do: Map.get(Fake.calls(), key, 0)
  defp step(install, key), do: Enum.find(install.steps, &(&1["key"] == key))

  setup do
    DigitalOcean.clear_sizes_cache()
    on_exit(&DigitalOcean.clear_sizes_cache/0)
    :ok
  end

  describe "root's SSH key" do
    setup do
      use_fake_backend()
      :ok
    end

    test "the droplet create names root's key, registered as an account key" do
      {install, _} = create_install!()
      assert Runner.run(install.id) == :ready

      install = Installs.get(install.id)
      assert [key] = Fake.all(:ssh_key)
      assert key["name"] == "burrow-install-#{install.id}"
      assert key["public_key"] == install.ssh_public_key
      assert install.ssh_key_id == key["id"]

      assert [droplet] = Fake.all(:droplet)
      assert droplet["ssh_keys"] == [key["id"]]
    end

    test "registered once, across a resumed run (looked up by name first)" do
      {install, _} = create_install!()
      {:ok, id} = DigitalOcean.ensure_ssh_key(install.id, install.ssh_public_key)
      # Positive control: a second ensure finds it rather than POSTing again.
      assert {:ok, ^id} = DigitalOcean.ensure_ssh_key(install.id, install.ssh_public_key)
      assert count("POST /v2/account/keys") == 1

      assert Runner.run(install.id) == :ready
      assert count("POST /v2/account/keys") == 1
      assert [%{"ssh_keys" => [^id]}] = Fake.all(:droplet)
    end

    test "teardown deletes the account key; a second teardown deletes nothing" do
      {install, _} = create_install!()
      assert Runner.run(install.id) == :ready
      assert [_] = Fake.all(:ssh_key)

      assert :ok = Installs.teardown(install.slug)
      assert Fake.all(:ssh_key) == []
      assert Installs.get(install.id).ssh_key_id == nil
      assert count("DELETE /v2/account/keys/:id") == 1

      assert :ok = Installs.teardown(install.slug)
      assert count("DELETE /v2/account/keys/:id") == 1
    end

    test "deleting a key that is already gone is :ok (idempotent)" do
      {install, _} = create_install!()
      assert :ok = DigitalOcean.delete_ssh_key(install.id)
      {:ok, _} = DigitalOcean.ensure_ssh_key(install.id, install.ssh_public_key)
      assert :ok = DigitalOcean.delete_ssh_key(install.id)
      assert :ok = DigitalOcean.delete_ssh_key(install.id)
      assert Fake.all(:ssh_key) == []
    end
  end

  describe "a size the region does not offer" do
    setup do
      use_fake_backend()
      :ok
    end

    test "a 422 at reserve is plain words, and creates nothing" do
      {install, _} = create_install!()
      # As if the provider stopped offering the size after the form was filled.
      Repo.update_all(from(i in Install, where: i.id == ^install.id), set: [region: "nyc3"])

      assert Runner.run(install.id) == :failed
      error = step(Installs.get(install.id), "reserve")["error"]

      assert error ==
               "That server size isn't available in this region right now. Pick another region."

      assert count("POST /v2/droplets 422") == 1
      assert Fake.all(:droplet) == []
    end

    test "regions_for/1 lists only the regions offering the size" do
      assert Installs.regions_for("s-2vcpu-4gb") == ~w(nyc1 sfo2 sfo3)
      refute "nyc3" in Installs.regions_for("s-4vcpu-8gb")
    end
  end

  describe "a server that never finishes installing" do
    test "fails in plain words, and Retry restarts it before trying again" do
      use_fake_backend(probe: StuckProbe, step_timeouts_ms: %{"install" => 30})
      {install, token} = create_install!()

      assert Runner.run(install.id) == :failed
      failed = Installs.get(install.id)

      assert step(failed, "install")["error"] ==
               "Your server didn't finish installing in time. Retry restarts it and tries again."

      assert count("POST /v2/droplets/:id/actions reboot") == 0
      put_installs_env(start_runs: false)
      assert {:ok, _} = Installs.retry(failed, token)
      assert count("POST /v2/droplets/:id/actions reboot") == 1
    end

    test "a retry after a failure elsewhere does not reboot" do
      use_fake_backend()
      {install, token} = create_install!()
      Repo.update_all(from(i in Install, where: i.id == ^install.id), set: [region: "nyc3"])
      assert Runner.run(install.id) == :failed

      put_installs_env(start_runs: false)
      assert {:ok, _} = Installs.retry(Installs.get(install.id), token)
      assert count("POST /v2/droplets/:id/actions reboot") == 0
    end
  end
end
