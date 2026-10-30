defmodule Platform.Installs.InstallsAuthzTest do
  @moduledoc """
  Task 01a10315 stage 2: who may create an install, what the status token
  opens, the create-time validation and the experiment-surface defaults.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.InstallsFixtures

  alias Platform.Installs
  alias Platform.Installs.Install
  alias Platform.Repo
  alias Platform.VaultFixtures

  @attrs %{
    "business_name" => "Acme Bakery",
    "owner_email" => "owner@acme-bakery.example.test",
    "region" => "nyc3"
  }

  defp count, do: Repo.aggregate(from(i in Install), :count)

  describe "create/2" do
    test "a non-root-admin actor is refused and nothing is written" do
      before = count()
      assert {:error, :unauthorized} = Installs.create(VaultFixtures.non_admin!(), @attrs)
      assert {:error, :unauthorized} = Installs.create(nil, @attrs)
      assert count() == before
    end

    test "a root admin gets the install and its token once; only the hash is stored" do
      assert {:ok, %{install: install, status_token: token}} =
               Installs.create(admin!(), @attrs)

      assert byte_size(token) >= 43
      assert install.status == "queued"
      assert install.size == "s-2vcpu-4gb"
      assert install.domain_mode == "ours"
      assert install.slug =~ ~r/^acme-bakery-[a-z2-9]{4}$/
      assert install.primary_host == "#{install.slug}.installs.example.test"
      assert install.ssh_public_key =~ ~r/^ssh-ed25519 [A-Za-z0-9+\/=]+ burrow-install$/

      %{rows: [[hash]]} =
        Repo.query!("SELECT status_token_hash FROM installs WHERE id = $1", [
          Ecto.UUID.dump!(install.id)
        ])

      assert hash == :crypto.hash(:sha256, token)
      refute inspect(install) =~ "status_token_hash"
      refute inspect(install) =~ "handover_sealed"
    end

    test "validates every field" do
      admin = admin!()

      cases = [
        {%{"business_name" => ""}, {:invalid, :business_name}},
        {%{"business_name" => "Acme $HOME"}, {:invalid, :business_name}},
        {%{"business_name" => String.duplicate("x", 81)}, {:invalid, :business_name}},
        {%{"business_name" => " Acme"}, {:invalid, :business_name}},
        {%{"owner_email" => "not-an-email"}, {:invalid, :owner_email}},
        {%{"region" => "lon1"}, {:invalid, :region}},
        {%{"size" => "s-1vcpu-1gb"}, {:invalid, :size}},
        {%{"domain_mode" => "theirs"}, {:invalid, :domain_mode}},
        {%{"domain_mode" => "customer"}, {:invalid, :primary_host}},
        {%{"domain_mode" => "customer", "primary_host" => "203.0.113.4"},
         {:invalid, :primary_host}},
        {%{"domain_mode" => "customer", "primary_host" => "localhost"}, {:invalid, :primary_host}}
      ]

      for {change, error} <- cases do
        assert {:error, ^error} = Installs.create(admin, Map.merge(@attrs, change))
      end

      assert {:ok, _} =
               Installs.create(
                 admin,
                 Map.merge(@attrs, %{"size" => "s-4vcpu-8gb", "region" => "sfo3"})
               )
    end

    test "a subdomain of ours needs SUITE_INSTALLS_DNS_ZONE; a customer domain does not" do
      put_installs_env(dns_zone: nil)
      assert {:error, :dns_zone_missing} = Installs.create(admin!(), @attrs)

      assert {:ok, %{install: install}} =
               Installs.create(
                 admin!(),
                 Map.merge(@attrs, %{
                   "domain_mode" => "customer",
                   "primary_host" => "acme.example.test"
                 })
               )

      assert install.primary_host == "acme.example.test"
    end

    test "a slug is always a valid install name" do
      for name <- ["Bäckerei & Söhne", "123 Main St", "!!!", "A", "O'Brien (UK) Ltd."] do
        slug = Installs.new_slug(name)
        assert slug =~ ~r/^[a-z][a-z0-9-]{0,62}$/, slug
        refute String.contains?(slug, "--")
      end
    end
  end

  describe "get_by_token/2" do
    test "the right token opens the install; a wrong or malformed one gives nil" do
      {install, token} = create_install!()

      assert Installs.get_by_token(token, rate_key: "authz-1").id == install.id
      assert Installs.get_by_token(token <> "x", rate_key: "authz-1") == nil
      assert Installs.get_by_token("", rate_key: "authz-1") == nil
      assert Installs.get_by_token(nil, rate_key: "authz-1") == nil
      assert Installs.get_by_token(String.duplicate("a", 500), rate_key: "authz-1") == nil
    end

    test "lookups are rate-limited per key, and the limit answers nil too" do
      {install, token} = create_install!()
      put_installs_env(token_lookups_per_minute: 3)
      key = "authz-rate-#{System.unique_integer([:positive])}"

      for _ <- 1..3, do: assert(Installs.get_by_token(token, rate_key: key).id == install.id)
      assert Installs.get_by_token(token, rate_key: key) == nil
      # Another caller's bucket is unaffected.
      assert Installs.get_by_token(token, rate_key: key <> "-other").id == install.id
    end
  end

  test "defaults/0 is the configured experiment surface" do
    assert Installs.defaults() == %{
             default_size: "s-2vcpu-4gb",
             sizes: ["s-2vcpu-4gb", "s-4vcpu-8gb"],
             regions: ~w(nyc1 nyc2 nyc3 sfo2 sfo3 atl1 ric1)
           }

    put_installs_env(default_size: "s-4vcpu-8gb", regions: ["sfo3", "lon1"])
    assert %{default_size: "s-4vcpu-8gb", regions: ["sfo3"]} = Installs.defaults()
  end

  test "list/1 is root-admin only" do
    {install, _} = create_install!()
    assert {:ok, installs} = Installs.list(admin!())
    assert install.id in Enum.map(installs, & &1.id)
    assert {:error, :unauthorized} = Installs.list(VaultFixtures.non_admin!())
  end
end
