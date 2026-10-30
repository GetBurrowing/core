defmodule Platform.Installs.DigitalOceanTest do
  @moduledoc """
  Task 01a10315 stage 2: request shapes of the DigitalOcean API v2 client,
  against `Req.Test` stubs only (config/test.exs), plus the token guard.
  """
  use ExUnit.Case, async: false

  alias Platform.Installs.DigitalOcean

  @token "dop_v1_test_fake_token"

  setup do
    DigitalOcean.clear_sizes_cache()
    test_pid = self()

    record = fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      conn = Plug.Conn.fetch_query_params(conn)
      body = if raw == "", do: nil, else: Jason.decode!(raw)

      send(
        test_pid,
        {:req, conn.method, conn.request_path, conn.query_params, body,
         Plug.Conn.get_req_header(conn, "authorization")}
      )

      conn
    end

    %{record: record}
  end

  defp stub(fun), do: Req.Test.stub(DigitalOcean, fun)

  describe "droplets" do
    test "create_droplet POSTs user_data, the image, both tags and the fixed flags", ctx do
      stub(fn conn ->
        conn = ctx.record.(conn)
        Req.Test.json(Plug.Conn.put_status(conn, 202), %{"droplet" => %{"id" => 42}})
      end)

      assert {:ok, %{"id" => 42}} =
               DigitalOcean.create_droplet(%{
                 install_id: "abc",
                 name: "acme-x2k4",
                 region: "nyc3",
                 size: "s-2vcpu-4gb",
                 user_data: "#cloud-config\n"
               })

      assert_received {:req, "POST", "/v2/droplets", _, body, ["Bearer " <> @token]}

      assert body == %{
               "name" => "acme-x2k4",
               "region" => "nyc3",
               "size" => "s-2vcpu-4gb",
               "image" => "ubuntu-24-04-x64",
               "user_data" => "#cloud-config\n",
               "tags" => ["burrow-install", "burrow-install-abc"],
               "monitoring" => true,
               "ipv6" => false
             }
    end

    test "a region outside the US list is refused before any request", ctx do
      stub(fn conn -> ctx.record.(conn) |> Req.Test.json(%{}) end)

      for region <- ["lon1", "fra1", "sgp1", "NYC3", ""] do
        assert {:error, :region_not_allowed} =
                 DigitalOcean.create_droplet(%{
                   install_id: "abc",
                   name: "x",
                   region: region,
                   size: "s-2vcpu-4gb",
                   user_data: ""
                 })
      end

      refute_received {:req, _, _, _, _, _}
      assert DigitalOcean.regions() == ~w(nyc1 nyc2 nyc3 sfo2 sfo3 atl1 ric1)
    end

    test "find_droplets_by_tag and delete_droplets_by_tag pass tag_name", ctx do
      stub(fn conn ->
        conn = ctx.record.(conn)

        case conn.method do
          "GET" -> Req.Test.json(conn, %{"droplets" => [%{"id" => 1}]})
          "DELETE" -> Plug.Conn.send_resp(conn, 204, "")
        end
      end)

      assert {:ok, [%{"id" => 1}]} = DigitalOcean.find_droplets_by_tag("burrow-install-abc")
      assert_received {:req, "GET", "/v2/droplets", %{"tag_name" => "burrow-install-abc"}, _, _}

      assert :ok = DigitalOcean.delete_droplets_by_tag("burrow-install-abc")
      assert_received {:req, "DELETE", "/v2/droplets", %{"tag_name" => "burrow-install-abc"}, _, _}
    end

    test "public_ipv4 picks the public v4 address" do
      droplet = %{
        "networks" => %{
          "v4" => [
            %{"type" => "private", "ip_address" => "10.0.0.2"},
            %{"type" => "public", "ip_address" => "203.0.113.9"}
          ]
        }
      }

      assert DigitalOcean.public_ipv4(droplet) == "203.0.113.9"
      assert DigitalOcean.public_ipv4(%{"networks" => %{"v4" => []}}) == nil
    end

    test "a 403 is :forbidden and other statuses are {:http, status}" do
      stub(fn conn ->
        conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{"id" => "forbidden"})
      end)

      assert {:error, :forbidden} = DigitalOcean.get_droplet(1)

      stub(fn conn -> conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{}) end)
      assert {:error, {:http, 500}} = DigitalOcean.get_droplet(1)
    end
  end

  describe "firewall" do
    test "an existing firewall is found by name and nothing is created", ctx do
      stub(fn conn ->
        conn = ctx.record.(conn)

        Req.Test.json(conn, %{
          "firewalls" => [
            %{"id" => "fw-other", "name" => "burrow-install-zzz"},
            %{"id" => "fw-1", "name" => "burrow-install-abc"}
          ]
        })
      end)

      assert {:ok, "fw-1"} = DigitalOcean.ensure_firewall("abc")
      assert_received {:req, "GET", "/v2/firewalls", _, _, _}
      refute_received {:req, "POST", _, _, _, _}
    end

    test "a missing firewall is created: 22/80/443 in from anywhere, all out, by tag", ctx do
      stub(fn conn ->
        conn = ctx.record.(conn)

        case conn.method do
          "GET" -> Req.Test.json(conn, %{"firewalls" => []})
          "POST" -> Req.Test.json(conn, %{"firewall" => %{"id" => "fw-new"}})
        end
      end)

      assert {:ok, "fw-new"} = DigitalOcean.ensure_firewall("abc")
      assert_received {:req, "POST", "/v2/firewalls", _, body, _}
      assert body["name"] == "burrow-install-abc"
      assert body["tags"] == ["burrow-install-abc"]
      assert Enum.map(body["inbound_rules"], & &1["ports"]) == ["22", "80", "443"]

      for rule <- body["inbound_rules"] do
        assert rule["protocol"] == "tcp"
        assert rule["sources"]["addresses"] == ["0.0.0.0/0", "::/0"]
      end

      assert Enum.map(body["outbound_rules"], & &1["protocol"]) == ["tcp", "udp", "icmp"]
    end
  end

  describe "DNS" do
    test "ensure_a_record creates, updates or leaves the record", ctx do
      :persistent_term.put({__MODULE__, :records}, [])

      stub(fn conn ->
        conn = ctx.record.(conn)

        case conn.method do
          "GET" ->
            Req.Test.json(conn, %{
              "domain_records" => :persistent_term.get({__MODULE__, :records})
            })

          _ ->
            Req.Test.json(conn, %{"domain_record" => %{"id" => 7}})
        end
      end)

      assert :ok = DigitalOcean.ensure_a_record("installs.example.test", "acme", "203.0.113.5")

      assert_received {:req, "GET", "/v2/domains/installs.example.test/records",
                       %{"type" => "A", "name" => "acme.installs.example.test"}, _, _}

      assert_received {:req, "POST", "/v2/domains/installs.example.test/records", _, body, _}
      assert body == %{"type" => "A", "name" => "acme", "data" => "203.0.113.5", "ttl" => 300}

      :persistent_term.put({__MODULE__, :records}, [%{"id" => 7, "data" => "203.0.113.5"}])
      assert :ok = DigitalOcean.ensure_a_record("installs.example.test", "acme", "203.0.113.5")
      refute_received {:req, method, _, _, _, _} when method in ["POST", "PUT"]

      assert :ok = DigitalOcean.ensure_a_record("installs.example.test", "acme", "203.0.113.6")
      assert_received {:req, "PUT", "/v2/domains/installs.example.test/records/7", _, put, _}
      assert put["data"] == "203.0.113.6"
    after
      :persistent_term.erase({__MODULE__, :records})
    end
  end

  describe "sizes" do
    test "are cached per node", ctx do
      stub(fn conn ->
        ctx.record.(conn)
        |> Req.Test.json(%{"sizes" => [%{"slug" => "s-2vcpu-4gb", "price_monthly" => 24}]})
      end)

      assert {:ok, %{"s-2vcpu-4gb" => 24}} = DigitalOcean.sizes()
      assert {:ok, %{"s-2vcpu-4gb" => 24}} = DigitalOcean.sizes()
      assert_received {:req, "GET", "/v2/sizes", _, _, _}
      refute_received {:req, "GET", "/v2/sizes", _, _, _}
    end
  end

  describe "token guard" do
    test "only a binary starting dop_v1_ is a token" do
      assert {:ok, "dop_v1_abc"} = DigitalOcean.guard_token({:ok, "dop_v1_abc"})
      # A Vault decrypt path has answered {:ok, :error} (backlog task 01a13c96).
      assert {:error, :do_token_unusable} = DigitalOcean.guard_token({:ok, :error})
      assert {:error, :do_token_unusable} = DigitalOcean.guard_token({:ok, "dop_v1_"})
      assert {:error, :do_token_unusable} = DigitalOcean.guard_token({:ok, "ghp_abc"})
      assert {:error, :do_token_unusable} = DigitalOcean.guard_token({:ok, nil})
      assert {:error, :do_token_unusable} = DigitalOcean.guard_token(:error)
      assert {:error, :not_found} = DigitalOcean.guard_token({:error, :not_found})
    end

    test "an unusable token makes no request at all", ctx do
      previous = Application.get_env(:platform, DigitalOcean)

      Application.put_env(
        :platform,
        DigitalOcean,
        Keyword.put(previous, :token_source, {:static, :error})
      )

      on_exit(fn -> Application.put_env(:platform, DigitalOcean, previous) end)
      stub(fn conn -> ctx.record.(conn) |> Req.Test.json(%{}) end)

      assert {:error, :do_token_unusable} = DigitalOcean.find_droplets_by_tag("x")
      refute_received {:req, _, _, _, _, _}
    end
  end
end
