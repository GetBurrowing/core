defmodule Platform.Social.TrendsWikimediaTest do
  use ExUnit.Case, async: true

  alias Platform.Social.Trends.Wikimedia

  @fixture Path.expand("../../fixtures/wikimedia/top-en-2026-11-13.json", __DIR__)
  @observed ~U[2026-11-15 10:00:00Z]

  test "normalizes a real daily response, excluding non-articles and preserving source ranks" do
    body = @fixture |> File.read!() |> Jason.decode!()
    assert {:ok, snapshot} = Wikimedia.parse_response(body, ~D[2026-11-13], @observed, 50)
    assert snapshot.source == "wikimedia_pageviews"
    assert snapshot.reporting_date == ~D[2026-11-13]
    assert snapshot.observed_at == @observed
    assert length(snapshot.items) == 50

    assert [
             %{
               id: "Synthetic_article_0003",
               rank: 3,
               pageviews: 727_529,
               url: "https://en.wikipedia.org/wiki/Synthetic_article_0003"
             }
             | _
           ] = snapshot.items

    refute Enum.any?(snapshot.items, &String.starts_with?(&1.id, "Special:"))
    refute Enum.any?(snapshot.items, &(&1.id == "Main_Page"))
  end

  test "refuses a response for the wrong date, project or access" do
    body = @fixture |> File.read!() |> Jason.decode!()

    assert {:error, :invalid_response} =
             Wikimedia.parse_response(body, ~D[2026-11-12], @observed, 50)

    [entry] = body["items"]

    assert {:error, :invalid_response} =
             Wikimedia.parse_response(
               %{"items" => [%{entry | "project" => "fr.wikipedia"}]},
               ~D[2026-11-13],
               @observed,
               50
             )

    assert {:error, :invalid_response} =
             Wikimedia.parse_response(
               %{"items" => [%{entry | "access" => "mobile-web"}]},
               ~D[2026-11-13],
               @observed,
               50
             )

    assert {:error, :invalid_response} =
             Wikimedia.parse_response(
               %{"items" => [%{entry | "articles" => Enum.take(entry["articles"], 900)}]},
               ~D[2026-11-13],
               @observed,
               50
             )

    assert {:error, :invalid_response} =
             Wikimedia.parse_response(%{"items" => [nil]}, ~D[2026-11-13], @observed, 50)
  end

  test "excludes Wikimedia's dash placeholder for missing page titles" do
    body = @fixture |> File.read!() |> Jason.decode!()
    [entry] = body["items"]
    [first | rest] = entry["articles"]
    body = %{"items" => [%{entry | "articles" => [%{first | "article" => "-"} | rest]}]}
    assert {:ok, snapshot} = Wikimedia.parse_response(body, ~D[2026-11-13], @observed, 50)
    refute Enum.any?(snapshot.items, &(&1.id == "-"))
  end

  test "fetch sends identifying user agent and parses the real response shape" do
    parent = self()

    Req.Test.stub(Wikimedia, fn conn ->
      send(parent, {:request, conn.request_path, Plug.Conn.get_req_header(conn, "user-agent")})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, File.read!(@fixture))
    end)

    assert {:ok, snapshot} =
             Wikimedia.fetch(~D[2026-11-13], @observed, 50,
               contact: "https://example.com/contact",
               req_options: [plug: {Req.Test, Wikimedia}]
             )

    assert snapshot.reporting_date == ~D[2026-11-13]

    assert_receive {:request,
                    "/api/rest_v1/metrics/pageviews/top/en.wikipedia/all-access/2026/11/13", [ua]}

    assert ua =~ "BurrowSocialTrends"
    assert ua =~ "https://example.com/contact"
  end

  test "missing contact refuses without issuing a request" do
    assert {:error, :missing_contact} =
             Wikimedia.fetch(~D[2026-11-13], @observed, 50,
               contact: nil,
               req_options: [plug: {Req.Test, Wikimedia}]
             )
  end

  test "does not follow a redirect away from the fixed source" do
    parent = self()

    Req.Test.stub(Wikimedia, fn conn ->
      send(parent, {:request, conn.host})

      conn
      |> Plug.Conn.put_resp_header("location", "https://example.com/untrusted")
      |> Plug.Conn.send_resp(302, "redirect")
    end)

    assert {:error, {:http, 302}} =
             Wikimedia.fetch(~D[2026-11-13], @observed, 50,
               contact: "https://example.com/contact",
               req_options: [plug: {Req.Test, Wikimedia}]
             )

    assert_receive {:request, "wikimedia.org"}
    refute_receive {:request, "example.com"}
  end

  test "rejects an oversized response without parsing it as an observation" do
    Req.Test.stub(Wikimedia, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, String.duplicate("x", 1_100_000))
    end)

    assert {:error, :response_too_large} =
             Wikimedia.fetch(~D[2026-11-13], @observed, 50,
               contact: "https://example.com/contact",
               req_options: [plug: {Req.Test, Wikimedia}]
             )
  end

  test "still honors a throttle response when its body exceeds the limit" do
    Req.Test.stub(Wikimedia, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", "7200")
      |> Plug.Conn.send_resp(429, String.duplicate("x", 1_100_000))
    end)

    assert {:error, {:throttled, ["7200"]}} =
             Wikimedia.fetch(~D[2026-11-13], @observed, 50,
               contact: "https://example.com/contact",
               req_options: [plug: {Req.Test, Wikimedia}]
             )
  end

  test "a slow source is bounded by the configured timeout" do
    Req.Test.stub(Wikimedia, fn conn ->
      Process.sleep(100)
      Plug.Conn.send_resp(conn, 200, "{}")
    end)

    assert {:error, :unavailable} =
             Wikimedia.fetch(~D[2026-11-13], @observed, 50,
               contact: "https://example.com/contact",
               timeout_ms: 10,
               req_options: [plug: {Req.Test, Wikimedia}]
             )
  end
end
