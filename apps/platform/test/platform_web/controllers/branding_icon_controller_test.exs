defmodule PlatformWeb.BrandingIconControllerTest do
  @moduledoc """
  Tests for `/branding/:version/:variant` (task `01a0879a` stage 3).

  ## The load-bearing test

  All seven variants must serve 200 to a conn with NO session and NO
  authentication of any kind, because the fetcher is an operating system at
  PWA-install time and it has no cookie to send. A gate here is not a 403
  anybody sees — it is a blank glyph on a home screen with nothing logged.

  That test is only worth something if the conn really is unauthenticated,
  so it carries a POSITIVE CONTROL: the SAME conn, in the same test, is
  redirected away from `/agents/:id/avatar`, which is behind
  `Plugs.RequireAuth`. Without the control, "the unauthenticated request
  succeeded" could just mean the test helper had logged someone in.

  ## The rest

    * `x-content-type-options: nosniff` and
      `cache-control: public, max-age=31536000, immutable`. The second is
      safe ONLY because the URL is content-versioned, which is why the
      stale-version 404 below is part of the same contract.
    * A stale `version` 404s rather than serving current bytes — an
      immutable-cached URL must never change meaning.
    * An unknown `variant` 404s and never reaches a storage key: the proof
      is a row whose `derived` map has been hand-poisoned with a bogus
      variant key pointing at real bytes. Serving those would mean the URL
      segment reached the map; 404 means the fixed allowlist ran first.
    * A fresh install (no upload) still answers `/images/...` static
      defaults — this feature is a no-op until an admin uploads.
  """

  use PlatformWeb.ConnCase, async: false

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Branding
  alias Platform.Branding.InstallBranding
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation, as: VipsOperation

  setup do
    prev = Application.get_env(:platform, :chat_attachments_root)
    scratch = Platform.TestTemp.mkdir!("branding_icon_controller_test")
    Application.put_env(:platform, :chat_attachments_root, scratch)

    on_exit(fn ->
      if prev do
        Application.put_env(:platform, :chat_attachments_root, prev)
      else
        Application.delete_env(:platform, :chat_attachments_root)
      end

      File.rm_rf!(scratch)
    end)

    :ok
  end

  # ── Fixtures ───────────────────────────────────────────────────────────

  defp admin! do
    n = System.unique_integer([:positive])

    user =
      %User{}
      |> User.changeset(%{
        email: "branding-icon-#{n}@example.com",
        name: "Branding Icon #{n}",
        oidc_sub: "oidc-branding-icon-#{n}"
      })
      |> Repo.insert!()

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Tenancy.get_org_by_slug!("fabrikam").id,
      role: "admin"
    })
    |> Repo.insert!()

    user
  end

  # A flat 600px square — clears `IconSet`'s 512px source floor. Same
  # construction as `Platform.BrandingTest`'s.
  defp solid_png(rgb, side \\ 600) do
    {:ok, one} = VipsOperation.black(1, 1)
    {:ok, coloured} = VipsOperation.linear(one, [1.0, 1.0, 1.0], Enum.map(rgb, &(&1 * 1.0)))
    {:ok, cast} = VipsOperation.cast(coloured, :VIPS_FORMAT_UCHAR)
    {:ok, tiled} = VipsOperation.embed(cast, 0, 0, side, side, extend: :VIPS_EXTEND_COPY)
    {:ok, srgb} = VipsOperation.colourspace(tiled, :VIPS_INTERPRETATION_sRGB)
    {:ok, bytes} = VipsImage.write_to_buffer(srgb, ".png")
    bytes
  end

  defp upload!(rgb \\ [200, 30, 40]) do
    {:ok, branding} =
      Branding.put_source(admin!(), {:binary, solid_png(rgb)}, content_type: "image/png")

    branding
  end

  defp insert_agent do
    n = System.unique_integer([:positive])

    %Agent{}
    |> Agent.changeset(%{
      slug: "branding-icon-agent-#{n}",
      name: "Branding Icon Agent",
      status: "active",
      workspace_id: Ecto.UUID.generate()
    })
    |> Repo.insert!()
  end

  defp expected_content_type("favicon_ico"), do: "image/x-icon"
  defp expected_content_type(_variant), do: "image/png"

  # ── The load-bearing test ──────────────────────────────────────────────

  describe "GET /branding/:version/:variant — unauthenticated" do
    test "serves all seven variants to a conn with no session at all", %{conn: conn} do
      branding = upload!()

      # POSITIVE CONTROL, first, on the SAME conn shape: prove this conn is
      # genuinely anonymous by bouncing it off a route that requires a
      # session. If the harness were silently logging someone in, this would
      # be a 200 and the seven assertions below would prove nothing.
      agent = insert_agent()
      control = get(conn, ~p"/agents/#{agent.id}/avatar")
      assert control.status == 302
      refute control.assigns[:current_user]

      for variant <- Branding.variants() do
        name = Atom.to_string(variant)
        res = get(conn, "/branding/#{branding.version}/#{name}")

        assert res.status == 200, "#{name} was #{res.status} for an anonymous request"
        assert byte_size(res.resp_body) > 0
        refute res.assigns[:current_user]

        assert [content_type] = get_resp_header(res, "content-type")
        assert content_type =~ expected_content_type(name)

        assert [disposition] = get_resp_header(res, "content-disposition")
        assert disposition =~ "inline"
      end
    end

    test "sets nosniff and an immutable public cache header", %{conn: conn} do
      branding = upload!()

      res = get(conn, "/branding/#{branding.version}/icon_512")

      assert res.status == 200
      assert get_resp_header(res, "x-content-type-options") == ["nosniff"]

      assert get_resp_header(res, "cache-control") == [
               "public, max-age=31536000, immutable"
             ]
    end
  end

  # ── The version segment is what makes the cache header safe ────────────

  describe "version handling" do
    test "a stale version 404s rather than serving the current bytes", %{conn: conn} do
      first = upload!([200, 30, 40])
      second = upload!([10, 20, 200])
      refute first.version == second.version

      stale = get(conn, "/branding/#{first.version}/icon_512")
      assert stale.status == 404

      current = get(conn, "/branding/#{second.version}/icon_512")
      assert current.status == 200
    end

    test "a version that never existed 404s", %{conn: conn} do
      upload!()
      assert get(conn, "/branding/deadbeefcafe/icon_512").status == 404
    end
  end

  # ── The variant segment never reaches a storage key ────────────────────

  describe "variant handling" do
    test "an unknown variant 404s without consulting the derived map", %{conn: conn} do
      branding = upload!()

      # Poison the row with a variant name the allowlist does not contain,
      # pointing at bytes that genuinely exist. A 200 here would mean the URL
      # segment was used as a map key; 404 means the fixed allowlist ran
      # first and the filesystem was never touched.
      poisoned = Map.put(branding.derived, "totally_made_up", branding.derived["icon_512"])

      branding
      |> Ecto.Changeset.change(%{derived: poisoned})
      |> Repo.update!()

      assert get(conn, "/branding/#{branding.version}/totally_made_up").status == 404
      # A key-shaped segment (the real key ends `.png`) is likewise refused:
      # the allowlist holds bare variant NAMES, not filenames.
      assert get(conn, "/branding/#{branding.version}/icon_512.png").status == 404
    end

    test "a declared variant missing from the row 404s", %{conn: conn} do
      branding = upload!()

      branding
      |> Ecto.Changeset.change(%{derived: Map.delete(branding.derived, "favicon_16")})
      |> Repo.update!()

      assert get(conn, "/branding/#{branding.version}/favicon_16").status == 404
      assert get(conn, "/branding/#{branding.version}/icon_192").status == 200
    end
  end

  # ── A fresh install is unchanged ───────────────────────────────────────

  describe "fresh install, no upload" do
    test "icon_url/1 still returns the repo's static defaults", _ctx do
      assert %InstallBranding{source_storage_key: nil} = Branding.get()

      for variant <- Branding.variants() do
        url = Branding.icon_url(variant)
        assert url == Branding.default_icon_url(variant)
        assert String.starts_with?(url, "/images/") or url == "/favicon.ico"
        refute String.starts_with?(url, "/branding/")
      end
    end

    test "after an upload every variant's url is the versioned public path", _ctx do
      branding = upload!()

      for variant <- Branding.variants() do
        assert Branding.icon_url(variant) == "/branding/#{branding.version}/#{variant}"
      end
    end
  end

  # ── The stable alias sw.js uses ────────────────────────────────────────

  describe "GET /branding/current/:variant" do
    test "redirects to the CURRENT icon, and follows an upload", %{conn: conn} do
      # Before any upload it must resolve to the repo default...
      before = get(conn, "/branding/current/icon_192")
      assert before.status == 302
      default_target = redirected_to(before, 302)
      assert default_target == Branding.default_icon_url(:icon_192)

      # ...and after an upload, to the versioned path. This is the whole
      # point of the route: the target MOVES. Asserting only the post-upload
      # shape would pass just as well against a hardcoded redirect.
      branding = upload!()

      after_upload = get(conn, "/branding/current/icon_192")
      assert after_upload.status == 302
      target = redirected_to(after_upload, 302)

      assert target == "/branding/#{branding.version}/icon_192"
      refute target == default_target

      # And the target actually serves bytes, so the redirect is not a
      # well-formed pointer at nothing.
      assert get(conn, target).status == 200
    end

    test "is no-cache, or a cached redirect pins the old icon", %{conn: conn} do
      conn = get(conn, "/branding/current/icon_192")

      assert get_resp_header(conn, "cache-control") == ["no-cache"]
    end

    test "an unknown variant 404s rather than reaching to_existing_atom", %{conn: conn} do
      assert get(conn, "/branding/current/not_a_variant").status == 404

      # Positive control on the same conn: a real variant on this route
      # does redirect, so the 404 above is the allowlist and not the route
      # failing to match at all.
      assert get(conn, "/branding/current/icon_192").status == 302
    end

    test "every variant resolves, so sw.js cannot name one that 404s", %{conn: conn} do
      upload!()

      for variant <- Branding.variants() do
        resp = get(conn, "/branding/current/#{variant}")

        assert resp.status == 302,
               "variant #{variant} did not redirect (status #{resp.status})"
      end
    end
  end
end
