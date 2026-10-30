defmodule PlatformWeb.Dev.FakeDigitalOcean do
  @moduledoc """
  A fake DigitalOcean API v2 for dev stub mode (`SUITE_INSTALLS_FAKE=1`, task
  01a10315 stage 2). Two ways in, one state (`Platform.Installs.Fake`):

    * `Platform.Installs.DigitalOcean` calls it in-process as its Req `plug:`;
    * the router mounts it at `/dev/fake-digitalocean` inside the dev-only
      block, so a person or a review script can read and steer it:
      `GET /dev/fake-digitalocean/_calls` (counts per `METHOD /path`, plus
      `POST /v2/droplets tag:<tag>` per install), `POST .../_fail` with
      `{"step": "reserve"|"install"|"connect"|"final", "times": 1}`,
      `POST .../_dns` with `{"host": "<host>"}` and `POST .../_reset`.

  Droplets turn `active` with a documentation-range IPv4 (203.0.113.0/24)
  `fake_delay_ms` after they are created. Deleting by tag removes them at once.
  """

  @behaviour Plug

  import Plug.Conn

  alias Platform.Installs.Fake

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn = fetch_query_params(conn)
    body = read_json(conn)
    route(conn, conn.method, conn.path_info, body)
  end

  # -- control ----------------------------------------------------------------

  defp route(conn, "GET", ["_calls"], _), do: json(conn, 200, Fake.calls())

  defp route(conn, "POST", ["_fail"], %{"step" => step} = body) do
    times = Map.get(body, "times", 1)

    if step in Fake.steps() and is_integer(times) and times > 0 do
      Fake.inject_failure(step, times)
      json(conn, 200, %{"ok" => true})
    else
      json(conn, 422, %{"error" => "step must be one of #{Enum.join(Fake.steps(), ", ")}"})
    end
  end

  defp route(conn, "POST", ["_dns"], %{"host" => host}) when is_binary(host) do
    Fake.resolve_dns(host)
    json(conn, 200, %{"ok" => true})
  end

  defp route(conn, "POST", ["_reset"], _) do
    Fake.reset()
    json(conn, 200, %{"ok" => true})
  end

  # -- droplets ---------------------------------------------------------------

  defp route(conn, "GET", ["v2", "droplets"], _) do
    Fake.count("GET /v2/droplets")
    tag = conn.query_params["tag_name"]
    json(conn, 200, %{"droplets" => Enum.map(tagged(tag), &present/1)})
  end

  defp route(conn, "POST", ["v2", "droplets"], body) do
    Fake.count("POST /v2/droplets")
    tags = Map.get(body, "tags", [])
    Enum.each(tags, &Fake.count("POST /v2/droplets tag:" <> &1))
    id = Fake.next_id()

    droplet = %{
      "id" => id,
      "name" => body["name"],
      "region" => body["region"],
      "size" => body["size"],
      "tags" => tags,
      "created_ms" => System.monotonic_time(:millisecond)
    }

    Fake.put({:droplet, id}, droplet)
    json(conn, 202, %{"droplet" => present(droplet)})
  end

  defp route(conn, "GET", ["v2", "droplets", id], _) do
    Fake.count("GET /v2/droplets/:id")

    cond do
      Fake.take_failure("reserve") -> json(conn, 500, %{"message" => "injected failure"})
      droplet = find_droplet(id) -> json(conn, 200, %{"droplet" => present(droplet)})
      true -> json(conn, 404, %{"id" => "not_found"})
    end
  end

  defp route(conn, "DELETE", ["v2", "droplets"], _) do
    Fake.count("DELETE /v2/droplets")
    Enum.each(tagged(conn.query_params["tag_name"]), &Fake.delete({:droplet, &1["id"]}))
    send_resp(conn, 204, "")
  end

  # -- firewalls --------------------------------------------------------------

  defp route(conn, "GET", ["v2", "firewalls"], _) do
    Fake.count("GET /v2/firewalls")
    json(conn, 200, %{"firewalls" => Fake.all(:firewall)})
  end

  defp route(conn, "POST", ["v2", "firewalls"], body) do
    Fake.count("POST /v2/firewalls")
    Enum.each(Map.get(body, "tags", []), &Fake.count("POST /v2/firewalls tag:" <> &1))
    id = "fw-#{Fake.next_id()}"
    firewall = Map.merge(body, %{"id" => id, "status" => "succeeded"})
    Fake.put({:firewall, id}, firewall)
    json(conn, 202, %{"firewall" => firewall})
  end

  defp route(conn, "DELETE", ["v2", "firewalls", id], _) do
    Fake.count("DELETE /v2/firewalls/:id")
    Fake.delete({:firewall, id})
    send_resp(conn, 204, "")
  end

  # -- DNS --------------------------------------------------------------------

  defp route(conn, "GET", ["v2", "domains"], _) do
    Fake.count("GET /v2/domains")
    json(conn, 200, %{"domains" => [%{"name" => "fake.invalid", "ttl" => 1800}]})
  end

  defp route(conn, "GET", ["v2", "domains", zone, "records"], _) do
    Fake.count("GET /v2/domains/:zone/records")
    name = conn.query_params["name"]

    records =
      Fake.all(:record)
      |> Enum.filter(&(&1["zone"] == zone and "#{&1["name"]}.#{zone}" == name))

    json(conn, 200, %{"domain_records" => records})
  end

  defp route(conn, "POST", ["v2", "domains", zone, "records"], body) do
    Fake.count("POST /v2/domains/:zone/records")
    id = Fake.next_id()
    record = Map.merge(body, %{"id" => id, "zone" => zone})
    Fake.put({:record, id}, record)
    json(conn, 201, %{"domain_record" => record})
  end

  defp route(conn, "PUT", ["v2", "domains", _zone, "records", id], body) do
    Fake.count("PUT /v2/domains/:zone/records/:id")

    case Enum.find(Fake.all(:record), &(to_string(&1["id"]) == id)) do
      nil ->
        json(conn, 404, %{"id" => "not_found"})

      record ->
        record = Map.merge(record, body)
        Fake.put({:record, record["id"]}, record)
        json(conn, 200, %{"domain_record" => record})
    end
  end

  defp route(conn, "DELETE", ["v2", "domains", _zone, "records", id], _) do
    Fake.count("DELETE /v2/domains/:zone/records/:id")

    with {int, ""} <- Integer.parse(id), do: Fake.delete({:record, int})
    send_resp(conn, 204, "")
  end

  defp route(conn, "GET", ["v2", "sizes"], _) do
    json(conn, 200, %{
      "sizes" => [
        %{"slug" => "s-2vcpu-4gb", "price_monthly" => 24, "vcpus" => 2, "memory" => 4096},
        %{"slug" => "s-4vcpu-8gb", "price_monthly" => 48, "vcpus" => 4, "memory" => 8192}
      ]
    })
  end

  defp route(conn, method, path, _) do
    json(conn, 404, %{"id" => "not_found", "message" => "#{method} /#{Enum.join(path, "/")}"})
  end

  # -- helpers ----------------------------------------------------------------

  defp tagged(nil), do: Fake.all(:droplet)
  defp tagged(tag), do: Enum.filter(Fake.all(:droplet), &(tag in &1["tags"]))

  defp find_droplet(id) do
    case Integer.parse(id) do
      {int, ""} -> Enum.find(Fake.all(:droplet), &(&1["id"] == int))
      _ -> nil
    end
  end

  defp present(droplet) do
    active = System.monotonic_time(:millisecond) - droplet["created_ms"] >= Fake.delay_ms()

    networks =
      if active,
        do: [%{"type" => "public", "ip_address" => "203.0.113.#{rem(droplet["id"], 250) + 1}"}],
        else: []

    droplet
    |> Map.drop(["created_ms"])
    |> Map.merge(%{
      "status" => if(active, do: "active", else: "new"),
      "networks" => %{"v4" => networks}
    })
  end

  defp read_json(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}} = conn) do
    case read_body(conn) do
      {:ok, "", _} -> %{}
      {:ok, raw, _} -> decode(raw)
      _ -> %{}
    end
  end

  defp read_json(%Plug.Conn{body_params: params}) when is_map(params), do: params
  defp read_json(_), do: %{}

  defp decode(raw) do
    case Jason.decode(raw) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
