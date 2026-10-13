defmodule PlatformWeb.PrototypeControllerTest do
  @moduledoc """
  `/proto/...` (task 01a1316b-4e46 stage 1, ADR 0057 Decision 1). Header
  assertions mirror `PlatformWeb.FileBlobControllerTest`.
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Platform.PrototypeFixtures
  import Platform.TenancyFixtures

  alias Platform.Prototypes
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.PrototypeGrant

  setup do
    scratch_storage!("prototype_controller_test")
    set_settings!(%{enabled: true, who_may_publish: "members", retention_days: 90})

    org_id = tenant_org_id("proto-web-#{System.unique_integer([:positive])}")
    agent = agent!()
    member = user!("Member")
    member!(member, org_id)
    outsider = user!("Outsider")

    files =
      bundle_files("v1")
      |> Map.put("sub/index.html", %{"content" => "<p>sub</p>"})

    {:ok, %{prototype: p}} =
      Prototypes.publish(agent_publisher(agent), %{org_id: org_id, name: "Web"}, {:files, files})

    {:ok, prototype: p, agent: agent, member: member, outsider: outsider, org_id: org_id}
  end

  defp authed(conn, user), do: init_test_session(conn, current_user_id: user.id)

  # Follow the entry redirect the way a frame would: the grant URL is then
  # requested with NO session, as it is from an opaque-origin frame.
  defp grant_url(ctx, version, path \\ "") do
    conn =
      build_conn() |> authed(ctx.member) |> get("/proto/#{ctx.prototype.id}/#{version}/#{path}")

    assert conn.status == 302
    [location] = get_resp_header(conn, "location")
    location
  end

  defp serve(id, version, grant, path \\ "index.html"),
    do: get(build_conn(), "/proto/#{id}/#{version}/g/#{grant}/#{path}")

  defp grant_root(url) do
    [root] = Regex.run(~r{^/proto/[^/]+/\d+/g/[^/]+/}, url)
    root
  end

  describe "entry and latest" do
    test "entry 302s to the grant URL for the entry path", ctx do
      url = grant_url(ctx, 1)
      assert url =~ ~r{^/proto/#{ctx.prototype.id}/1/g/[^/]+/index\.html$}
    end

    test "latest 302s to the numbered version, carrying path and query", ctx do
      conn =
        build_conn() |> authed(ctx.member) |> get("/proto/#{ctx.prototype.id}/latest/?screen=2")

      assert redirected_to(conn, 302) == "/proto/#{ctx.prototype.id}/1/?screen=2"

      {:ok, %{prototype: p}} =
        Prototypes.publish(
          agent_publisher(ctx.agent),
          %{prototype: ctx.prototype},
          {:files, bundle_files("v2")}
        )

      conn = build_conn() |> authed(ctx.member) |> get("/proto/#{p.id}/latest/b.html")
      assert redirected_to(conn, 302) == "/proto/#{p.id}/2/b.html"
    end

    test "an unauthenticated entry goes to login, not to the bundle", ctx do
      conn = get(build_conn(), "/proto/#{ctx.prototype.id}/1/")
      assert redirected_to(conn, 302) == "/auth/login"
    end

    test "non-member, unknown id, unknown and removed versions all get 404", ctx do
      id = ctx.prototype.id

      for path <- ["/proto/#{id}/1/", "/proto/#{id}/latest/"] do
        assert build_conn() |> authed(ctx.outsider) |> get(path) |> response(404) == "Not found"
      end

      for path <- [
            "/proto/#{Ecto.UUID.generate()}/1/",
            "/proto/not-a-uuid/1/",
            "/proto/#{id}/9/",
            "/proto/#{id}/zero/"
          ] do
        assert build_conn() |> authed(ctx.member) |> get(path) |> response(404) == "Not found"
      end

      url = grant_url(ctx, 1)

      Prototypes.get_live_version(id, 1)
      |> Ecto.Changeset.change(removed_at: DateTime.utc_now())
      |> Repo.update!()

      assert build_conn() |> authed(ctx.member) |> get("/proto/#{id}/1/") |> response(404)
      assert build_conn() |> get(url) |> response(404)
    end
  end

  describe "bundle files under a grant" do
    test "serves the entry with the sandbox CSP appended, not replacing", ctx do
      conn = get(build_conn(), grant_url(ctx, 1))
      assert response(conn, 200) =~ "v1"
      assert [ct] = get_resp_header(conn, "content-type")
      assert ct =~ "text/html"

      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "sandbox allow-scripts;"
      refute csp =~ "allow-same-origin"
      assert csp =~ "frame-ancestors 'self'"
      assert csp =~ "base-uri 'self'"
      assert csp =~ "script-src 'self' 'unsafe-inline'"
      assert csp =~ "connect-src 'none'"
      assert csp =~ "form-action 'none'"

      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
      assert [cache] = get_resp_header(conn, "cache-control")
      assert cache =~ "private"
    end

    test "relative assets resolve under the grant and carry the same sandbox", ctx do
      root = grant_root(grant_url(ctx, 1))

      conn = get(build_conn(), root <> "app.js")
      assert response(conn, 200) == "document.title = 'v1';"
      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "sandbox allow-scripts;"

      assert build_conn() |> get(root <> "app.css") |> response(200) =~ "color: red"
      assert build_conn() |> get(root <> "nope.js") |> response(404) == "Not found"
    end

    test "?screen=2 serves the same bytes; the entry carries the query through", ctx do
      root = grant_root(grant_url(ctx, 1))
      plain = build_conn() |> get(root <> "b.html") |> response(200)
      assert build_conn() |> get(root <> "b.html?screen=2") |> response(200) == plain

      conn = build_conn() |> authed(ctx.member) |> get("/proto/#{ctx.prototype.id}/1/?screen=2")
      assert redirected_to(conn, 302) =~ ~r{/index\.html\?screen=2$}
    end

    test "a directory serves its index.html; without the slash it redirects", ctx do
      root = grant_root(grant_url(ctx, 1))
      assert build_conn() |> get(root <> "sub/") |> response(200) == "<p>sub</p>"
      assert build_conn() |> get(root <> "sub") |> redirected_to(302) == root <> "sub/"
    end

    test "v1 still serves after v2 is published", ctx do
      {:ok, _} =
        Prototypes.publish(
          agent_publisher(ctx.agent),
          %{prototype: ctx.prototype},
          {:files, bundle_files("v2")}
        )

      assert build_conn() |> get(grant_url(ctx, 1)) |> response(200) =~ "v1"
      assert build_conn() |> get(grant_url(ctx, 2)) |> response(200) =~ "v2"
    end
  end

  describe "grant binding" do
    setup ctx do
      {:ok, %{prototype: other}} =
        Prototypes.publish(
          agent_publisher(ctx.agent),
          %{org_id: ctx.org_id, name: "Other"},
          {:files, bundle_files("other")}
        )

      {:ok, %{prototype: p}} =
        Prototypes.publish(
          agent_publisher(ctx.agent),
          %{prototype: ctx.prototype},
          {:files, bundle_files("v2")}
        )

      {:ok, other: other, prototype: p}
    end

    test "a valid grant serves (positive control for the refusals below)", ctx do
      grant = PrototypeGrant.sign(ctx.member.id, ctx.prototype.id, 1)
      assert serve(ctx.prototype.id, 1, grant) |> response(200) =~ "v1"
    end

    test "a grant for prototype A replayed on B gets 404", ctx do
      grant = PrototypeGrant.sign(ctx.member.id, ctx.prototype.id, 1)
      assert serve(ctx.other.id, 1, grant) |> response(404)
    end

    test "a grant for v1 replayed on v2 gets 404", ctx do
      grant = PrototypeGrant.sign(ctx.member.id, ctx.prototype.id, 1)
      assert serve(ctx.prototype.id, 2, grant) |> response(404)
    end

    test "an expired grant gets 404", ctx do
      signed_at = System.system_time(:second) - PrototypeGrant.max_age() - 60
      grant = PrototypeGrant.sign(ctx.member.id, ctx.prototype.id, 1, signed_at: signed_at)
      assert serve(ctx.prototype.id, 1, grant) |> response(404)
    end

    test "a grant whose user left the org gets 404 on the next request", ctx do
      grant = PrototypeGrant.sign(ctx.member.id, ctx.prototype.id, 1)
      assert serve(ctx.prototype.id, 1, grant) |> response(200)

      Repo.delete_all(
        from(m in OrgMembership, where: m.user_id == ^ctx.member.id and m.org_id == ^ctx.org_id)
      )

      assert serve(ctx.prototype.id, 1, grant) |> response(404)
    end

    test "a grant minted for a non-member, and a garbage grant, get 404", ctx do
      grant = PrototypeGrant.sign(ctx.outsider.id, ctx.prototype.id, 1)
      assert serve(ctx.prototype.id, 1, grant) |> response(404)
      assert serve(ctx.prototype.id, 1, "garbage") |> response(404)
    end
  end
end
