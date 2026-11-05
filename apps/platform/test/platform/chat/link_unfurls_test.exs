defmodule Platform.Chat.LinkUnfurlsTest do
  @moduledoc """
  Link unfurls stage 2 (task 01a1a944): the SSRF-guarded fetcher, oEmbed
  merging, the cache and its concurrency, and the migration's down/0.

  Every request goes to the `Req.Test` stub `Platform.Chat.LinkUnfurls.Fetcher`
  (config/test.exs) and every host resolves through the static resolver set
  here, so nothing reaches DNS or the network. Each stub reports every
  request it serves to the test process as `{:hit, ip, path}`, so "never
  fetched" is a counted absence.

  `async: false`: the resolver and timeout are application env, and the
  fetch runs under `Platform.TaskSupervisor` in shared sandbox mode.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Chat.{LinkUnfurl, LinkUnfurls}
  alias Platform.Chat.LinkUnfurls.Fetcher
  alias Platform.Repo

  @fixtures Path.expand("../../support/fixtures/link_unfurls", __DIR__)

  @public {93, 184, 216, 34}
  @other {93, 184, 216, 35}
  @youtube {142, 250, 1, 1}
  @lan {192, 168, 1, 10}

  @resolver %{
    "public.test" => [@public],
    "other.test" => [@other],
    "internal.test" => [{127, 0, 0, 1}],
    "lan.test" => [@lan],
    "mixed.test" => [@public, {10, 0, 0, 7}],
    "www.youtube.com" => [@youtube],
    "vimeo.com" => [@other]
  }

  setup do
    prev = Application.get_env(:platform, :link_unfurl_resolver)
    Application.put_env(:platform, :link_unfurl_resolver, @resolver)

    on_exit(fn ->
      Application.put_env(:platform, :link_unfurl_resolver, prev)
      Application.delete_env(:platform, :link_unfurl_timeout_ms)
    end)

    :ok
  end

  defp ip(tuple), do: tuple |> :inet.ntoa() |> to_string()
  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  # Routes {ip, path} to a responder; every request is reported.
  defp stub(routes) do
    me = self()

    Req.Test.stub(Fetcher, fn conn ->
      send(me, {:hit, conn.host, conn.request_path})

      case Map.get(routes, {conn.host, conn.request_path}) do
        nil -> Plug.Conn.send_resp(conn, 404, "")
        fun -> fun.(conn)
      end
    end)
  end

  defp html(body), do: fn conn -> Req.Test.html(conn, body) end

  defp redirect(to, status \\ 302) do
    fn conn ->
      conn |> Plug.Conn.put_resp_header("location", to) |> Plug.Conn.send_resp(status, "")
    end
  end

  defp hits do
    receive do
      {:hit, host, path} -> [{host, path} | hits()]
    after
      0 -> []
    end
  end

  @page "<html><head><meta property=\"og:title\" content=\"Public page\"></head></html>"

  describe "SSRF guard" do
    test "a public host is fetched (positive control for every refusal below)" do
      stub(%{{ip(@public), "/"} => html(@page)})

      assert {:ok, %{body: @page, url: "http://public.test/"}} =
               Fetcher.get("http://public.test/")

      assert hits() == [{ip(@public), "/"}]
    end

    for url <-
          ~w(http://127.0.0.1/ http://[::1]/v6 http://10.0.0.5/ http://169.254.169.254/latest/meta-data/ http://[fd00::1]/ http://internal.test/ http://mixed.test/) do
      test "#{url} is refused and never fetched" do
        stub(%{})
        assert {:error, {:refused, :forbidden_address}} = Fetcher.get(unquote(url))
        assert hits() == []
      end
    end

    test "a name the resolver maps to a private LAN address is refused after resolution" do
      stub(%{{ip(@lan), "/"} => html(@page)})
      assert {:error, {:refused, :forbidden_address}} = Fetcher.get("http://lan.test/")
      assert hits() == []
    end

    test "file, ftp and userinfo urls are refused" do
      stub(%{{ip(@public), "/"} => html(@page)})
      assert {:error, {:refused, :scheme}} = Fetcher.get("file:///etc/passwd")
      assert {:error, {:refused, :scheme}} = Fetcher.get("ftp://public.test/")
      assert {:error, {:refused, :userinfo}} = Fetcher.get("http://user:pass@public.test/")
      assert hits() == []
    end

    test "a 302 to a name resolving to loopback is refused; the second hop is never requested" do
      stub(%{
        {ip(@public), "/"} => redirect("http://internal.test/probe"),
        {"127.0.0.1", "/probe"} => html(@page)
      })

      assert {:error, {:refused, :forbidden_address}} = Fetcher.get("http://public.test/")
      assert hits() == [{ip(@public), "/"}]
    end

    test "POSITIVE CONTROL: a 302 to another public host is followed and parsed" do
      stub(%{
        {ip(@public), "/"} => redirect("https://other.test/landing"),
        {ip(@other), "/landing"} => html(@page)
      })

      assert {:ok, %{url: "https://other.test/landing", body: @page}} =
               Fetcher.get("http://public.test/")

      assert hits() == [{ip(@public), "/"}, {ip(@other), "/landing"}]
    end

    test "a relative Location is resolved against the hop it came from" do
      stub(%{
        {ip(@public), "/a"} => redirect("/b"),
        {ip(@public), "/b"} => html(@page)
      })

      assert {:ok, %{url: "http://public.test/b"}} = Fetcher.get("http://public.test/a")
    end

    test "requests carry the generic user agent and no cookie" do
      me = self()

      Req.Test.stub(Fetcher, fn conn ->
        send(me, {:headers, conn.req_headers})
        Req.Test.html(conn, @page)
      end)

      assert {:ok, _} = Fetcher.get("http://public.test/")
      assert_received {:headers, headers}
      assert {"user-agent", "Mozilla/5.0 (compatible; LinkPreview/1.0)"} in headers
      refute List.keymember?(headers, "cookie", 0)
    end
  end

  describe "bounds" do
    test "redirects: three are followed, a fourth fails" do
      chain = for n <- 0..3, into: %{}, do: {{ip(@public), "/#{n}"}, redirect("/#{n + 1}")}

      stub(Map.put(chain, {ip(@public), "/4"}, html(@page)))
      assert {:error, :too_many_redirects} = Fetcher.get("http://public.test/0")
      assert length(hits()) == 4

      # Positive control: three hops land.
      assert {:ok, %{url: "http://public.test/4"}} = Fetcher.get("http://public.test/1")
    end

    test "a 2 MB body fails as too large and is not returned; 900 KB is fine" do
      big = "<html>" <> String.duplicate("a", 2 * 1024 * 1024) <> "</html>"
      ok = "<html>" <> String.duplicate("a", 900 * 1024) <> "</html>"
      stub(%{{ip(@public), "/big"} => html(big), {ip(@public), "/ok"} => html(ok)})

      assert {:error, :too_large} = Fetcher.get("http://public.test/big")
      assert {:ok, %{body: ^ok}} = Fetcher.get("http://public.test/ok")
    end

    test "the deadline fires on a stub slower than the configured timeout" do
      Application.put_env(:platform, :link_unfurl_timeout_ms, 100)

      stub(%{
        {ip(@public), "/slow"} => fn conn ->
          Process.sleep(1_000)
          Req.Test.html(conn, @page)
        end,
        {ip(@public), "/fast"} => html(@page)
      })

      {micros, result} = :timer.tc(fn -> Fetcher.get("http://public.test/slow") end)
      assert result == {:error, :timeout}
      assert micros < 900_000
      assert {:ok, _} = Fetcher.get("http://public.test/fast")
    end

    test "a non-HTML 200 is not parsed" do
      stub(%{{ip(@public), "/x.png"} => fn conn -> Req.Test.text(conn, "png") end})
      assert {:error, :unsupported_type} = Fetcher.get("http://public.test/x.png")
    end
  end

  describe "normalize/1" do
    test "lowercases scheme and host, drops default port, fragment and utm_*, keeps v=" do
      assert LinkUnfurls.normalize(
               "HTTPS://WWW.YouTube.com:443/watch?v=abc&utm_source=x&t=4#frag"
             ) ==
               "https://www.youtube.com/watch?v=abc&t=4"

      assert LinkUnfurls.normalize("http://Example.com") == "http://example.com/"

      assert LinkUnfurls.normalize("http://example.com:8080/a?UTM_medium=y") ==
               "http://example.com:8080/a"

      assert LinkUnfurls.normalize("ftp://example.com/") == nil
      assert LinkUnfurls.normalize("/canvases/x") == nil
    end
  end

  describe "ensure/2 and the cache" do
    defp ensure!(url) do
      me = self()
      result = LinkUnfurls.ensure(url, fn row -> send(me, {:done, row}) end)
      if result == :started, do: assert_receive({:done, _row}, 2_000)
      result
    end

    defp row(url), do: Repo.get_by!(LinkUnfurl, url_key: LinkUnfurls.normalize(url))

    defp expire!(url) do
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      key = LinkUnfurls.normalize(url)
      Repo.update_all(from(u in LinkUnfurl, where: u.url_key == ^key), set: [expires_at: past])
    end

    test "an article unfurls ok with its OG fields and a 7-day expiry" do
      stub(%{{ip(@public), "/post"} => html(fixture("og_article.html"))})
      assert ensure!("http://public.test/post?utm_campaign=z") == :started

      r = row("http://public.test/post")
      assert r.status == "ok"
      assert r.title == "Designing calm notifications & quiet apps"
      assert r.image_url == "https://cdn.example.com/hero/calm.jpg"
      assert r.media_kind == "article"
      assert r.url == "http://public.test/post?utm_campaign=z"
      assert DateTime.diff(r.expires_at, DateTime.utc_now(), :hour) in 167..168
      assert hits() == [{ip(@public), "/post"}]
    end

    test "cache hit: a second ensure inside the TTL makes zero requests" do
      stub(%{{ip(@public), "/post"} => html(fixture("og_article.html"))})
      assert ensure!("http://public.test/post") == :started
      assert length(hits()) == 1
      assert ensure!("http://public.test/post#again") == :cached
      assert hits() == []
    end

    test "cache miss after expires_at: fetched again" do
      stub(%{{ip(@public), "/post"} => html(fixture("og_article.html"))})
      assert ensure!("http://public.test/post") == :started
      _ = hits()
      expire!("http://public.test/post")
      assert ensure!("http://public.test/post") == :started
      assert hits() == [{ip(@public), "/post"}]
    end

    test "negative cache: a failed row suppresses refetch for an hour, then refetches" do
      stub(%{})
      assert ensure!("http://public.test/missing") == :started
      assert row("http://public.test/missing").status == "failed"

      assert DateTime.diff(
               row("http://public.test/missing").expires_at,
               DateTime.utc_now(),
               :minute
             ) in 59..60

      assert hits() == [{ip(@public), "/missing"}]

      assert ensure!("http://public.test/missing") == :cached
      assert hits() == []

      expire!("http://public.test/missing")
      assert ensure!("http://public.test/missing") == :started
      assert hits() == [{ip(@public), "/missing"}]
    end

    test "a refused url stores refused and fetches nothing, oEmbed included" do
      stub(%{})
      assert ensure!("http://internal.test/") == :started
      assert row("http://internal.test/").status == "refused"
      assert hits() == []
    end

    test "a redirect into the LAN stores refused and never requests the second hop" do
      stub(%{{ip(@public), "/r"} => redirect("http://lan.test/")})
      assert ensure!("http://public.test/r") == :started
      assert row("http://public.test/r").status == "refused"
      assert hits() == [{ip(@public), "/r"}]
    end

    test "a page with no metadata stores failed" do
      stub(%{{ip(@public), "/bare"} => html(fixture("no_metadata.html"))})
      assert ensure!("http://public.test/bare") == :started
      assert row("http://public.test/bare").status == "failed"
    end

    test "a data: og:image is never stored" do
      stub(%{{ip(@public), "/d"} => html(fixture("data_image.html"))})
      assert ensure!("http://public.test/d") == :started
      r = row("http://public.test/d")
      assert r.status == "ok"
      assert r.title == "Data image page"
      assert r.image_url == nil
    end

    test "YouTube: oEmbed's title, channel and 480x360 thumbnail win; video; no duration" do
      yt = ip(@youtube)

      stub(%{
        {yt, "/watch"} =>
          html(fixture("video_page.html") |> String.replace(~r/<meta itemprop.*?>/, "")),
        {yt, "/oembed"} => fn conn ->
          Req.Test.json(conn, Jason.decode!(fixture("youtube_oembed.json")))
        end
      })

      assert ensure!("https://www.youtube.com/watch?v=abc123") == :started
      r = row("https://www.youtube.com/watch?v=abc123")
      assert r.status == "ok"
      assert r.title == "How we rebuilt our deploy pipeline in a weekend"
      assert r.author == "Example Channel"
      assert r.provider == "youtube"
      assert r.media_kind == "video"

      assert {r.image_url, r.image_width, r.image_height} ==
               {"https://i.ytimg.com/vi/abc123/hqdefault.jpg", 480, 360}

      assert r.duration_seconds == nil
      assert Enum.sort(hits()) == [{yt, "/oembed"}, {yt, "/watch"}]
    end

    test "Vimeo: the oEmbed duration is stored" do
      vm = ip(@other)

      stub(%{
        {vm, "/76979871"} => html("<html><head><title>Vimeo page</title></head></html>"),
        {vm, "/api/oembed.json"} => fn conn ->
          Req.Test.json(conn, Jason.decode!(fixture("vimeo_oembed.json")))
        end
      })

      assert ensure!("https://vimeo.com/76979871") == :started
      r = row("https://vimeo.com/76979871")
      assert {r.duration_seconds, r.author, r.media_kind} == {724, "Example Studio", "video"}
    end

    test "two concurrent ensure calls on one url fetch it exactly once" do
      me = self()

      stub(%{
        {ip(@public), "/race"} => fn conn ->
          Process.sleep(50)
          Req.Test.html(conn, fixture("og_article.html"))
        end
      })

      results =
        1..2
        |> Enum.map(fn _ ->
          Task.async(fn ->
            LinkUnfurls.ensure("http://public.test/race", &send(me, {:done, &1}))
          end)
        end)
        |> Enum.map(&Task.await/1)

      assert Enum.sort(results) == [:cached, :started]
      assert_receive {:done, %LinkUnfurl{status: "ok"}}, 2_000
      assert hits() == [{ip(@public), "/race"}]
      assert Repo.aggregate(LinkUnfurl, :count) == 1
    end

    test "get_fresh/1 and get_many/1 return fresh rows only" do
      stub(%{{ip(@public), "/a"} => html(@page), {ip(@public), "/b"} => html(@page)})
      ensure!("http://public.test/a")
      ensure!("http://public.test/b")
      expire!("http://public.test/b")

      assert %LinkUnfurl{status: "ok"} = LinkUnfurls.get_fresh("http://public.test/a")
      assert LinkUnfurls.get_fresh("http://public.test/b") == nil

      assert LinkUnfurls.get_many(["http://public.test/a", "http://public.test/b"]) |> Map.keys() ==
               ["http://public.test/a"]
    end

    test "a non-http url is skipped" do
      assert LinkUnfurls.ensure("mailto:someone@example.com") == :skipped
    end
  end

  describe "migration" do
    @version 20_261_105_030_000
    @module Platform.Repo.Migrations.CreateLinkUnfurls
    @opts [log: false, log_migrations_sql: false, migration_lock: false]

    defp table? do
      %{rows: rows} = Repo.query!("SELECT to_regclass('public.link_unfurls') IS NOT NULL")
      rows == [[true]]
    end

    test "down/0 drops the table and up/0 recreates it" do
      [path] =
        Path.wildcard(Path.join(:code.priv_dir(:platform), "repo/migrations/#{@version}_*.exs"))

      unless Code.ensure_loaded?(@module), do: Code.require_file(path)

      assert table?()
      :ok = Ecto.Migrator.down(Repo, @version, @module, @opts)
      refute table?()

      Repo.query!("DELETE FROM schema_migrations WHERE version = $1", [@version])
      :ok = Ecto.Migrator.up(Repo, @version, @module, @opts)
      assert table?()
    end
  end
end
