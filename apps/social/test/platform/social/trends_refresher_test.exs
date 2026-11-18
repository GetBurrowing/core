defmodule Platform.Social.TrendsRefresherTest do
  use Platform.DataCase, async: false

  import Platform.SocialStudioFixtures
  alias Platform.Social.Trends.{Refresher, Wikimedia}
  @fixture Path.expand("../../fixtures/wikimedia/top-en-2026-11-13.json", __DIR__)
  @now ~U[2026-11-14 12:00:00Z]

  setup do
    keys = [:trends, :trends_wikimedia, :trends_req_options]
    old = Map.new(keys, &{&1, Application.get_env(:social, &1)})

    on_exit(fn ->
      Enum.each(old, fn {key, value} ->
        if is_nil(value),
          do: Application.delete_env(:social, key),
          else: Application.put_env(:social, key, value)
      end)
    end)

    Application.put_env(:social, :trends,
      enabled: true,
      source: "wikimedia_pageviews",
      max_items: 50
    )

    Application.put_env(:social, :trends_wikimedia, contact: "https://example.com/contact")
    Application.put_env(:social, :trends_req_options, plug: {Req.Test, Wikimedia})
    :ok
  end

  test "off, missing contact and no enabled profile issue no HTTP request" do
    parent = self()

    Req.Test.stub(Wikimedia, fn conn ->
      send(parent, :requested)
      Plug.Conn.send_resp(conn, 500, "")
    end)

    Application.put_env(:social, :trends, enabled: false, source: "wikimedia_pageviews")
    assert {:error, :disabled} = Refresher.refresh(@now)
    Application.put_env(:social, :trends, enabled: true, source: "unapproved_source")
    assert {:error, :invalid_source} = Refresher.refresh(@now)
    Application.put_env(:social, :trends, enabled: true, source: "wikimedia_pageviews")
    assert {:error, :no_enabled_profile} = Refresher.refresh(@now)
    studio_world!()
    Application.put_env(:social, :trends_wikimedia, [])
    assert {:error, :missing_contact} = Refresher.refresh(@now)
    refute_receive :requested
  end

  test "invalid numeric configuration fails closed without sending HTTP" do
    studio_world!()
    parent = self()

    Req.Test.stub(Wikimedia, fn conn ->
      send(parent, :requested)
      Plug.Conn.send_resp(conn, 500, "")
    end)

    Application.put_env(:social, :trends,
      enabled: true,
      source: "wikimedia_pageviews",
      max_items: "many"
    )

    assert {:error, :invalid_configuration} = Refresher.refresh(@now)
    refute_receive :requested
  end

  test "an excessive interval does not crash the background process" do
    Application.put_env(:social, :trends,
      enabled: false,
      refresh_interval_ms: 99_999_999_999_999_999_999
    )

    assert {:noreply, :state} = Refresher.handle_info(:refresh, :state)
  end

  test "fetches yesterday once and retains one snapshot on repeated refresh" do
    studio_world!()
    parent = self()

    Req.Test.stub(Wikimedia, fn conn ->
      send(parent, :requested)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, File.read!(@fixture))
    end)

    assert {:ok, :updated} = Refresher.refresh(@now)
    assert_receive :requested
    assert {:ok, :up_to_date} = Refresher.refresh(@now)
    refute_receive :requested

    assert %{current: %{reporting_date: ~D[2026-11-13]}, previous: nil} =
             Platform.Social.Trends.latest("wikimedia_pageviews")
  end

  test "a retry-after throttle persists and prevents requests until the deadline" do
    studio_world!()
    parent = self()

    Req.Test.stub(Wikimedia, fn conn ->
      send(parent, :requested)

      conn
      |> Plug.Conn.put_resp_header("retry-after", "7200")
      |> Plug.Conn.send_resp(429, "slow down")
    end)

    assert {:error, :throttled} = Refresher.refresh(@now)
    assert_receive :requested
    assert %{retry_at: retry_at} = Platform.Social.Trends.source_status("wikimedia_pageviews")
    assert DateTime.compare(retry_at, ~U[2026-11-14 14:00:00Z]) == :eq
    assert {:error, :backoff} = Refresher.refresh(DateTime.add(@now, 60, :second))
    refute_receive :requested
    assert {:error, :throttled} = Refresher.refresh(DateTime.add(@now, 7201, :second))
    assert_receive :requested
  end

  test "the maximum supported Retry-After is honored rather than shortened to the fallback" do
    studio_world!()

    Req.Test.stub(Wikimedia, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", "31536000")
      |> Plug.Conn.send_resp(429, "slow")
    end)

    assert {:error, :throttled} = Refresher.refresh(@now)
    assert %{retry_at: retry_at} = Platform.Social.Trends.source_status("wikimedia_pageviews")
    assert DateTime.diff(retry_at, @now, :second) == 31_536_000
    assert {:error, :backoff} = Refresher.refresh(DateTime.add(@now, 86_401, :second))
  end

  test "an unpublished next day leaves the last successful dataset intact" do
    studio_world!()

    Req.Test.stub(Wikimedia, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, File.read!(@fixture))
    end)

    assert {:ok, :updated} = Refresher.refresh(@now)
    Req.Test.stub(Wikimedia, fn conn -> Plug.Conn.send_resp(conn, 404, "not yet") end)
    assert {:error, :not_yet_available} = Refresher.refresh(DateTime.add(@now, 86_400, :second))

    assert %{current: %{reporting_date: ~D[2026-11-13]}, previous: nil} =
             Platform.Social.Trends.latest("wikimedia_pageviews")

    assert %{status: "not_yet_available"} =
             Platform.Social.Trends.source_status("wikimedia_pageviews")
  end

  test "a delayed day is retried and can recover before advancing" do
    studio_world!()
    Req.Test.stub(Wikimedia, fn conn -> Plug.Conn.send_resp(conn, 200, File.read!(@fixture)) end)
    assert {:ok, :updated} = Refresher.refresh(@now)
    Req.Test.stub(Wikimedia, fn conn -> Plug.Conn.send_resp(conn, 404, "delayed") end)
    assert {:error, :not_yet_available} = Refresher.refresh(~U[2026-11-16 12:00:00Z])

    Req.Test.stub(Wikimedia, fn conn ->
      assert String.ends_with?(conn.request_path, "/2026/11/14")
      body = @fixture |> File.read!() |> String.replace("\"day\":\"13\"", "\"day\":\"14\"")
      Plug.Conn.send_resp(conn, 200, body)
    end)

    assert {:ok, :updated} = Refresher.refresh(~U[2026-11-16 13:00:00Z])

    assert %{current: %{reporting_date: ~D[2026-11-14]}} =
             Platform.Social.Trends.latest("wikimedia_pageviews")
  end

  test "a permanently missing date advances after bounded retries and preserves the gap" do
    studio_world!()
    Req.Test.stub(Wikimedia, fn conn -> Plug.Conn.send_resp(conn, 200, File.read!(@fixture)) end)
    assert {:ok, :updated} = Refresher.refresh(@now)
    parent = self()

    Req.Test.stub(Wikimedia, fn conn ->
      send(parent, conn.request_path)
      Plug.Conn.send_resp(conn, 404, "missing")
    end)

    assert {:error, :not_yet_available} = Refresher.refresh(~U[2026-11-16 12:00:00Z])
    assert {:error, :not_yet_available} = Refresher.refresh(~U[2026-11-16 13:00:00Z])
    assert_receive "/api/rest_v1/metrics/pageviews/top/en.wikipedia/all-access/2026/11/14"
    assert_receive "/api/rest_v1/metrics/pageviews/top/en.wikipedia/all-access/2026/11/14"

    assert %{current: %{reporting_date: ~D[2026-11-13]}} =
             Platform.Social.Trends.latest("wikimedia_pageviews")

    Req.Test.stub(Wikimedia, fn conn ->
      assert String.ends_with?(conn.request_path, "/2026/11/15")
      body = @fixture |> File.read!() |> String.replace("\"day\":\"13\"", "\"day\":\"15\"")
      Plug.Conn.send_resp(conn, 200, body)
    end)

    assert {:ok, :updated} = Refresher.refresh(~U[2026-11-16 14:00:00Z])

    assert %{
             current: %{reporting_date: ~D[2026-11-15]},
             previous: %{reporting_date: ~D[2026-11-13]}
           } = Platform.Social.Trends.latest("wikimedia_pageviews")
  end

  test "an HTTP-date Retry-After is enforced on subsequent attempts" do
    studio_world!()
    parent = self()

    Req.Test.stub(Wikimedia, fn conn ->
      send(parent, :requested)

      conn
      |> Plug.Conn.put_resp_header("retry-after", "Sat, 14 Nov 2026 15:00:00 GMT")
      |> Plug.Conn.send_resp(429, "slow")
    end)

    assert {:error, :throttled} = Refresher.refresh(@now)
    assert_receive :requested
    assert {:error, :backoff} = Refresher.refresh(~U[2026-11-14 14:59:00Z])
    refute_receive :requested
  end

  test "an invalid Retry-After still backs off instead of immediately retrying" do
    studio_world!()

    Req.Test.stub(Wikimedia, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", "not-a-date")
      |> Plug.Conn.send_resp(429, "slow")
    end)

    assert {:error, :throttled} = Refresher.refresh(@now)
    assert {:error, :backoff} = Refresher.refresh(DateTime.add(@now, 3600, :second))
  end
end
