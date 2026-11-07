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
  alias Platform.Prototypes.Storage
  alias Platform.Prototypes.Version
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.PrototypeController
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
      assert get_resp_header(conn, "cache-control") == ["private, no-cache"]
    end

    test "relative assets resolve under the grant and carry the same sandbox", ctx do
      root = grant_root(grant_url(ctx, 1))

      conn = get(build_conn(), root <> "app.js")
      assert response(conn, 200) == "document.title = 'v1';"
      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "sandbox allow-scripts;"
      assert get_resp_header(conn, "cache-control") == ["private, no-cache"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

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
      # No head and no doctype: the bridge goes at the very start.
      assert build_conn() |> get(root <> "sub/") |> response(200) ==
               PrototypeController.bridge_tag() <> "<p>sub</p>"

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

  describe "the room bridge (task 01a1316b-84fa stage 2)" do
    defp bridge_count(body), do: length(String.split(body, "data-suite-bridge")) - 1

    defp stored(ctx, version, path) do
      row = Prototypes.get_live_version(ctx.prototype.id, version)
      {:ok, bytes} = Storage.read(Version.file(row, path)["storage_key"])
      bytes
    end

    test "every HTML response carries exactly one bridge script, after the doctype", ctx do
      root = grant_root(grant_url(ctx, 1))

      for path <- ["index.html", "b.html", "sub/"] do
        body = build_conn() |> get(root <> path) |> response(200)
        assert bridge_count(body) == 1, "#{path} carries #{bridge_count(body)} bridges"
        assert body =~ "window"
      end

      # index.html starts with a doctype and has no head: the bridge goes
      # right after the doctype, so standards mode is kept, and the rest of
      # the stored bytes follow unchanged.
      body = build_conn() |> get(root <> "index.html") |> response(200)
      original = stored(ctx, 1, "index.html")
      assert "<!doctype html>" <> rest = original
      assert body == "<!doctype html>" <> PrototypeController.bridge_tag() <> rest
    end

    test "non-HTML files are byte-identical to storage", ctx do
      root = grant_root(grant_url(ctx, 1))

      for path <- ["app.js", "app.css"] do
        body = build_conn() |> get(root <> path) |> response(200)
        assert body == stored(ctx, 1, path)
        assert bridge_count(body) == 0
      end
    end

    test "the CSP is unchanged by the injection", ctx do
      conn = get(build_conn(), grant_url(ctx, 1))
      [csp] = get_resp_header(conn, "content-security-policy")
      assert String.ends_with?(csp, PrototypeController.bundle_csp())
      assert csp =~ "connect-src 'none'"
      refute csp =~ "allow-same-origin"
    end

    test "inject_bridge/1 goes after the head tag, never inside a header tag" do
      tag = PrototypeController.bridge_tag()

      assert PrototypeController.inject_bridge(~s(<html><HEAD lang="en"><title>t</title>)) ==
               ~s(<html><HEAD lang="en">) <> tag <> "<title>t</title>"

      assert PrototypeController.inject_bridge("<header>x</header>") ==
               tag <> "<header>x</header>"

      assert PrototypeController.inject_bridge("<!DOCTYPE html>\n<p>x</p>") ==
               "<!DOCTYPE html>" <> tag <> "\n<p>x</p>"
    end

    test "the bridge source is one inline script that cannot close itself early" do
      tag = PrototypeController.bridge_tag()
      inner = tag |> String.replace_prefix(~s(<script data-suite-bridge="1">), "")
      refute inner |> String.replace_suffix("</script>", "") |> String.contains?("</script")
      # 6 KiB -> 8 KiB in the #1235 rollup: room scripts (01a1316b-aab0
      # stage 2) added `suite.call` and its result envelope to suite.js
      # (6098 -> 7419 bytes). The budget still bounds the per-page inline cost.
      assert byte_size(inner) < 8 * 1024
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
      conn = serve(ctx.prototype.id, 1, grant)
      assert response(conn, 200)

      # The 404 below only happens if the browser asks again. A `max-age`
      # here let Chrome answer a re-navigation from disk cache for an hour
      # after revocation, so the response must forbid reuse without
      # revalidation (and must not carry a freshness lifetime at all).
      assert [cache] = get_resp_header(conn, "cache-control")
      assert cache =~ "no-cache"
      refute cache =~ "max-age"
      refute cache =~ "immutable"

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

  # Task 01a1b70c stage 2: a prototype in a tenant org with ZERO membership
  # rows follows its space, and every refusal is the unknown-id 404.
  describe "a space-bound prototype in a tenant org with no members" do
    setup ctx do
      tenant_id = tenant_org_id("proto-tenant-#{System.unique_integer([:positive])}")
      other_id = tenant_org_id("proto-sibling-#{System.unique_integer([:positive])}")

      space = Platform.ExternalUserFixtures.channel!(%{name: "Tenant room", org_id: tenant_id})

      {:ok, %{prototype: p}} =
        Prototypes.publish(
          agent_publisher(ctx.agent),
          %{org_id: tenant_id, name: "Tenant"},
          {:files, bundle_files("tenant-marker")}
        )

      p = p |> Ecto.Changeset.change(space_id: space.id) |> Repo.update!()
      assert p.canvas_id == nil

      participant = user!("Participant")
      member!(participant, other_id, "admin")
      Platform.ExternalUserFixtures.add_user!(space.id, participant.id)

      assert tenant_memberships(tenant_id) == 0

      {:ok,
       tenant_id: tenant_id,
       other_id: other_id,
       space: space,
       prototype: p,
       participant: participant}
    end

    defp tenant_memberships(org_id),
      do: Repo.aggregate(from(m in OrgMembership, where: m.org_id == ^org_id), :count)

    # status, body and content-type: what a reader can observe of a 404.
    defp observed(conn), do: {conn.status, conn.resp_body, get_resp_header(conn, "content-type")}

    defp entry_as(user, id, path \\ "1/"),
      do: build_conn() |> authed(user) |> get("/proto/#{id}/#{path}")

    # The 404s of a reader refused on `id`, next to the same routes for an
    # unknown id, so the two lists must be identical.
    defp refusals(user, id) do
      [
        entry_as(user, id),
        entry_as(user, id, "latest/"),
        serve(id, 1, PrototypeGrant.sign(user.id, id, 1))
      ]
      |> Enum.map(&observed/1)
    end

    defp unknown_404s(user), do: refusals(user, Ecto.UUID.generate())

    test "1: a participant from another org gets the entry, the bytes and latest", ctx do
      id = ctx.prototype.id
      conn = entry_as(ctx.participant, id)
      assert [url] = get_resp_header(conn, "location")
      assert conn.status == 302
      assert url =~ ~r{^/proto/#{id}/1/g/[^/]+/index\.html$}

      conn = get(build_conn(), url)
      assert response(conn, 200) =~ "tenant-marker"
      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "sandbox allow-scripts;"

      assert redirected_to(entry_as(ctx.participant, id, "latest/"), 302) == "/proto/#{id}/1/"
      assert tenant_memberships(ctx.tenant_id) == 0
    end

    test "2: a non-participant from another org gets the unknown-id 404 everywhere", ctx do
      outsider = user!("Outsider")
      member!(outsider, ctx.other_id)

      # The narrowing step alone would admit this reader: no grant covers the
      # tenant space for them. Only the participation rule refuses, so this
      # test fails if the space branch falls back to Access.check alone.
      root_member = user!("Root member")
      member!(root_member, acme_org_id())
      unattached = user!("Unattached")

      for user <- [outsider, root_member, unattached] do
        refute Platform.Tenancy.root_admin?(Platform.Accounts.get_user(user.id))
        expected = unknown_404s(user)
        assert [{404, "Not found", ["text/plain; charset=utf-8"]} | _] = expected
        assert refusals(user, ctx.prototype.id) == expected
      end

      for user <- [root_member, unattached] do
        scope = Platform.Access.Scope.for_user(Platform.Accounts.get_user(user.id))
        assert Platform.Access.check(scope, "chat.read", {:space, ctx.space.id}) == :ok
      end
    end

    # An entry or latest request by an external user never reaches the
    # controller: `PlatformWeb.Plugs.ExternalUserScope` denies the path first,
    # and its 403 render raises on `:proto_browser` (no `:accepts`). That is
    # path-based, so it cannot leak existence: the outcome for the real id is
    # compared with the outcome for an unknown id, whatever it is.
    defp outcome(fun) do
      observed(fun.())
    rescue
      e -> {:raised, e.__struct__, Exception.message(e)}
    end

    test "3: an external non-participant gets that same 404 on the grant route", ctx do
      external =
        Platform.ExternalUserFixtures.external_user!(Platform.Tenancy.get_org!(ctx.other_id))

      assert Platform.Tenancy.external_user?(Platform.Accounts.get_user(external.id))
      id = ctx.prototype.id
      unknown = Ecto.UUID.generate()

      expected = observed(serve(unknown, 1, PrototypeGrant.sign(external.id, unknown, 1)))
      assert {404, "Not found", ["text/plain; charset=utf-8"]} = expected
      assert observed(serve(id, 1, PrototypeGrant.sign(external.id, id, 1))) == expected

      for path <- ["1/", "latest/"] do
        assert outcome(fn -> entry_as(external, id, path) end) ==
                 outcome(fn -> entry_as(external, unknown, path) end)
      end

      # :member is the one path external users keep.
      Platform.ExternalUserFixtures.add_user!(ctx.space.id, external.id)
      grant = PrototypeGrant.sign(external.id, id, 1)
      assert serve(id, 1, grant) |> response(200) =~ "tenant-marker"
    end

    test "4: removing the participant revokes their grant on the next request", ctx do
      id = ctx.prototype.id
      grant = PrototypeGrant.sign(ctx.participant.id, id, 1)
      assert serve(id, 1, grant) |> response(200) =~ "tenant-marker"

      {1, _} =
        Repo.delete_all(
          from(p in Platform.Chat.Participant,
            where: p.space_id == ^ctx.space.id and p.participant_id == ^ctx.participant.id
          )
        )

      assert observed(serve(id, 1, grant)) ==
               observed(serve(Ecto.UUID.generate(), 1, grant))

      assert observed(serve(id, 1, grant)) |> elem(0) == 404
    end
  end
end
