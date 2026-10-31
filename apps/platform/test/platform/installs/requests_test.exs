defmodule Platform.Installs.RequestsTest do
  @moduledoc """
  Task 01a18f0c stage 1: install requests. A request IS an `installs` row
  with status `requested`, one open per email (database-enforced), and the
  spend gate `RequestSettings.auto_provision_requests` (default off) decides
  whether a request provisions without an operator click.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import Platform.InstallsFixtures

  alias Platform.Installs
  alias Platform.Installs.DigitalOcean
  alias Platform.Installs.Fake
  alias Platform.Installs.Install
  alias Platform.Installs.RequestSettings
  alias Platform.Installs.Runner
  alias Platform.Repo
  alias Platform.VaultFixtures

  @request %{
    "name" => "Pat Baker",
    "email" => "owner@acme.test",
    "business" => "Acme Bakery",
    "note" => "two locations, one oven"
  }

  defp rows, do: Repo.all(from(i in Install, order_by: [asc: i.inserted_at]))
  # Not query-logged: the log test captures around it.
  defp requested_row!(email),
    do: Repo.one!(from(i in Install, where: i.owner_email == ^email), log: false)

  defp posts, do: Map.get(Fake.calls(), "POST /v2/droplets", 0)

  # A DigitalOcean stub that reports every request it receives.
  defp counting_stub do
    test = self()
    Req.Test.set_req_test_to_shared(%{})
    on_exit(fn -> Req.Test.set_req_test_to_private(%{}) end)
    DigitalOcean.clear_sizes_cache()
    on_exit(&DigitalOcean.clear_sizes_cache/0)

    Req.Test.stub(DigitalOcean, fn conn ->
      send(test, {:provider_call, conn.method, conn.request_path})
      Req.Test.json(Plug.Conn.put_status(conn, 500), %{"id" => "stub"})
    end)
  end

  describe "request/1" do
    test "creates one requested row holding name, lowercased email, business and note" do
      assert {:ok, :created} =
               Installs.request(Map.put(@request, "email", "  Owner@Acme.TEST "))

      assert [row] = rows()
      assert row.status == "requested"
      assert row.owner_email == "owner@acme.test"
      assert row.requester_name == "Pat Baker"
      assert row.business_name == "Acme Bakery"
      assert row.request_note == "two locations, one oven"
      assert row.requested_at
      assert row.slug =~ ~r/^acme-bakery-[a-z2-9]{4}$/

      for field <- [
            :region,
            :size,
            :domain_mode,
            :primary_host,
            :ssh_public_key,
            :status_token_hash
          ] do
        assert Map.fetch!(row, field) == nil, field
      end

      assert row.handover_sealed == nil
    end

    test "the same email twice, in any case or padding, is one row and :duplicate" do
      assert {:ok, :created} = Installs.request(Map.put(@request, "email", " Owner@Acme.TEST "))
      assert {:ok, :duplicate} = Installs.request(@request)
      assert {:ok, :duplicate} = Installs.request(Map.put(@request, "note", "other words"))
      assert length(rows()) == 1
    end

    test "an email with a live install is :duplicate too" do
      use_fake_backend()
      {_install, _} = create_install!(%{"owner_email" => "owner@acme.test"})
      assert {:ok, :duplicate} = Installs.request(@request)
      assert Repo.aggregate(from(i in Install, where: i.status == "requested"), :count) == 0
    end

    test "concurrent requests for one email leave exactly one row" do
      results =
        1..4
        |> Enum.map(fn _ -> Task.async(fn -> Installs.request(@request) end) end)
        |> Enum.map(&Task.await/1)

      assert Enum.count(results, &(&1 == {:ok, :created})) == 1
      assert Enum.all?(results, &(&1 in [{:ok, :created}, {:ok, :duplicate}]))
      assert length(rows()) == 1
    end

    test "the database itself refuses a second open request for one email" do
      assert {:ok, :created} = Installs.request(@request)

      changeset =
        Install.request_changeset(%Install{}, %{
          slug: "other-slug-abcd",
          business_name: "Other",
          owner_email: "OWNER@acme.test",
          requested_at: DateTime.utc_now(),
          status: "requested"
        })

      assert {:error, %Ecto.Changeset{errors: errors}} = Repo.insert(changeset)
      assert {_, opts} = errors[:owner_email]
      assert opts[:constraint_name] == "installs_one_open_request_per_email"
    end

    test "a filled honeypot writes nothing" do
      assert {:ok, :ignored} =
               Installs.request(Map.put(@request, "website", "http://spam.example"))

      assert rows() == []
    end

    test "a hostile business name is normalised to a valid one of at most 80 characters" do
      business = "Acme \"$Bakery\" `x`\t" <> String.duplicate("y", 100)
      assert {:ok, :created} = Installs.request(Map.put(@request, "business", business))

      assert [row] = rows()
      assert Installs.valid_business_name?(row.business_name)
      assert String.length(row.business_name) <= 80
      assert String.starts_with?(row.business_name, "Acme Bakery x y")
      refute String.contains?(row.business_name, ["\"", "$", "`"])
    end

    test "invalid input is refused by field and writes nothing" do
      cases = [
        {%{"email" => "not-an-email"}, :email},
        {%{"email" => nil}, :email},
        {%{"name" => ""}, :name},
        {%{"name" => String.duplicate("n", 121)}, :name},
        {%{"name" => "Pat\u0007"}, :name},
        {%{"note" => String.duplicate("n", 1001)}, :note},
        {%{"business" => "\"$`"}, :business_name},
        {%{"business" => nil}, :business_name}
      ]

      for {change, field} <- cases do
        assert {:error, {:invalid, ^field}} = Installs.request(Map.merge(@request, change))
      end

      assert rows() == []
      assert {:ok, :created} = Installs.request(Map.delete(@request, "note"))
    end
  end

  describe "the spend gate" do
    test "is off by default, and then a request makes no provider call at all" do
      counting_stub()
      refute RequestSettings.get().auto_provision_requests

      assert {:ok, :created} = Installs.request(@request)

      refute_received {:provider_call, _, _}
      assert [%Install{status: "requested"}] = rows()
    end

    test "switched on through RequestSettings, a request is queued and its run starts" do
      use_fake_backend(start_runs: true)
      assert {:ok, _} = RequestSettings.update(admin!(), %{auto_provision_requests: true})

      assert {:ok, :created} = Installs.request(@request)

      row = requested_row!("owner@acme.test")
      assert row.status in ~w(queued provisioning ready)
      assert row.requested_at

      ready = wait_until(fn -> (i = Installs.get(row.id)) && i.status == "ready" && i end)
      assert ready.primary_host == "#{row.slug}.installs.example.test"
      assert posts() == 1
    end

    test "past the in-flight cap a request waits for an operator even when on" do
      use_fake_backend(auto_provision_max_in_flight: 1)
      {_install, _} = create_install!(%{"owner_email" => "first@acme.test"})
      assert {:ok, _} = RequestSettings.update(admin!(), %{auto_provision_requests: true})

      log = capture_log(fn -> assert {:ok, :created} = Installs.request(@request) end)

      assert requested_row!("owner@acme.test").status == "requested"
      assert log =~ "auto-provision cap reached"
    end

    test "RequestSettings.update/2 refuses a non-admin" do
      assert {:error, :unauthorized} =
               RequestSettings.update(VaultFixtures.non_admin!(), %{
                 auto_provision_requests: true
               })

      assert {:error, :unauthorized} =
               RequestSettings.update(nil, %{auto_provision_requests: true})

      refute RequestSettings.get().auto_provision_requests
    end
  end

  describe "provision_request/2" do
    setup do
      use_fake_backend()
      {:ok, :created} = Installs.request(@request)
      %{row: requested_row!("owner@acme.test")}
    end

    test "refuses a non-admin, and the internal :system_auto actor from outside", %{row: row} do
      assert {:error, :unauthorized} =
               Installs.provision_request(VaultFixtures.non_admin!(), row.id)

      assert {:error, :unauthorized} = Installs.provision_request(nil, row.id)
      assert {:error, :unauthorized} = Installs.provision_request(:system_auto, row.id)
      assert Installs.get(row.id).status == "requested"
    end

    test "fills the defaults, queues the row and discards the token", %{row: row} do
      defaults = Installs.defaults()
      assert {:ok, install} = Installs.provision_request(admin!(), row.id)

      assert install.id == row.id
      assert install.status == "queued"
      assert install.region == hd(defaults.regions)
      assert install.size == defaults.default_size
      assert install.size == "s-2vcpu-4gb"
      assert install.domain_mode == "ours"
      assert install.primary_host == "#{row.slug}.installs.example.test"
      assert install.ssh_public_key =~ ~r/^ssh-ed25519 /
      assert is_binary(install.status_token_hash)
      assert {:ok, _sealed} = Installs.unseal(Installs.get(row.id))
      assert Enum.map(install.steps, & &1["key"]) == ~w(reserve install connect final)

      # The requester's details survive; it is still recognisably a request.
      assert install.requester_name == "Pat Baker"
      assert install.requested_at == row.requested_at

      assert Runner.run(install.id) == :ready
      assert posts() == 1
    end

    test "refuses a row that is not requested", %{row: row} do
      assert {:ok, _} = Installs.provision_request(admin!(), row.id)
      assert {:error, :not_requested} = Installs.provision_request(admin!(), row.id)

      {install, _} = create_install!(%{"owner_email" => "other@acme.test"})
      assert {:error, :not_requested} = Installs.provision_request(admin!(), install.id)
      assert {:error, :not_found} = Installs.provision_request(admin!(), Ecto.UUID.generate())
    end

    test "with no DNS zone it refuses and the row stays requested", %{row: row} do
      put_installs_env(dns_zone: nil)
      assert {:error, :dns_zone_missing} = Installs.provision_request(admin!(), row.id)
      assert Installs.get(row.id).status == "requested"
    end
  end

  describe "list_requests/1, dismiss_request/2 and the other entry points" do
    setup do
      use_fake_backend()
      :ok
    end

    test "requests are listed oldest first, apart from installs" do
      {install, _} = create_install!(%{"owner_email" => "install@acme.test"})
      {:ok, :created} = Installs.request(Map.put(@request, "email", "a@acme.test"))
      {:ok, :created} = Installs.request(Map.put(@request, "email", "b@acme.test"))

      assert {:error, :unauthorized} = Installs.list_requests(VaultFixtures.non_admin!())
      assert {:ok, requests} = Installs.list_requests(admin!())
      assert Enum.map(requests, & &1.owner_email) == ["a@acme.test", "b@acme.test"]

      assert {:ok, installs} = Installs.list(admin!())
      assert Enum.map(installs, & &1.id) == [install.id]
    end

    test "dismiss hard-deletes a requested row, admin only" do
      {:ok, :created} = Installs.request(@request)
      row = requested_row!("owner@acme.test")

      assert {:error, :unauthorized} =
               Installs.dismiss_request(VaultFixtures.non_admin!(), row.id)

      assert :ok = Installs.dismiss_request(admin!(), row.id)
      assert Installs.get(row.id) == nil
      assert {:error, :not_requested} = Installs.dismiss_request(admin!(), row.id)
      assert {:error, :not_requested} = Installs.dismiss_request(admin!(), "nope")

      {install, _} = create_install!()
      assert {:error, :not_requested} = Installs.dismiss_request(admin!(), install.id)
      assert Installs.get(install.id)

      # Dismissed, the email may ask again.
      assert {:ok, :created} = Installs.request(@request)
    end

    test "resume_all/0, expire_handovers/1 and teardown/1 leave requested rows alone" do
      {:ok, :created} = Installs.request(@request)
      row = requested_row!("owner@acme.test")
      old = DateTime.add(DateTime.utc_now(), -30 * 24 * 60 * 60, :second)

      Repo.update_all(from(i in Install, where: i.id == ^row.id),
        set: [inserted_at: old, requested_at: old]
      )

      assert Installs.expire_handovers() == 0
      assert :ok = Installs.resume_all()
      assert Runner.whereis(row.id) == nil
      assert {:error, :not_provisioned} = Installs.teardown(row.id)

      row = Installs.get(row.id)
      assert row.status == "requested"
      assert row.handover_expired_at == nil
      assert Fake.calls() == %{}
    end

    test "only a requested row may lack the provision fields" do
      {:ok, :created} = Installs.request(@request)
      row = requested_row!("owner@acme.test")

      assert_raise Postgrex.Error, ~r/installs_provisioned_fields_check/, fn ->
        Repo.update_all(from(i in Install, where: i.id == ^row.id), set: [status: "queued"])
      end
    end
  end

  test "neither the requester's email, name nor note reaches the log, at any level" do
    use_fake_backend()
    previous = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous) end)

    email = "secret-person-#{System.unique_integer([:positive])}@acme.test"
    note = "private note #{System.unique_integer([:positive])}"
    name = "Requester #{System.unique_integer([:positive])}"

    log =
      capture_log([level: :debug], fn ->
        {:ok, :created} =
          Installs.request(%{@request | "email" => email, "note" => note, "name" => name})

        row = requested_row!(email)
        {:ok, _} = Installs.provision_request(admin!(), row.id)
        {:ok, _} = Installs.list_requests(admin!())
      end)

    assert log =~ "[installs] request"
    refute log =~ email
    refute log =~ note
    refute log =~ name
  end
end
