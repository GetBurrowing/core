defmodule PlatformWeb.ManifestControllerTest do
  @moduledoc """
  `/manifest.json` rendered from the branding record (task `01a0879a`
  stage 5).

  ## Why every test here calls the ACTION and not the endpoint

  `Plug.Static` runs BEFORE the router. Until stage 6 removes
  `manifest.json` from `PlatformWeb.static_paths/0` and deletes the file,
  `get(conn, "/manifest.json")` through the endpoint returns the STATIC
  FILE — it passes, proves nothing about the controller, and keeps passing
  if the action is wrong or absent. So these tests call
  `ManifestController.show/2` directly. The endpoint-level guard test
  belongs to the cutover stage, where it can actually fail.

  ## The endpoint guard (stage 6)

  Once the static file is gone and `manifest.json` / `favicon.ico` are out
  of `static_paths/0`, a request THROUGH THE ENDPOINT is the test that
  would have caught the file/route ordering mistake — so `describe "through
  the endpoint"` below issues real `get/2`s and asserts the controller
  answered (manifest content type, branding body) rather than a file. It
  only means something after the cutover, which is why it landed with it.

  ## The three deliberate corrections to the shipped file

  The default render is pinned field for field against what
  `priv/static/manifest.json` shipped, EXCEPT:

    * `background_color` `#ffffff` -> `#171b25` (no white splash flash into
      a dark-first app);
    * `theme_color` `#000000` -> `#171b25` (was matching neither theme);
    * the `maskable` entry now has its OWN `src`, because one file cannot
      be both `any` and `maskable`.

  Those three are asserted explicitly, so a silent drift back goes red.
  """

  use PlatformWeb.ConnCase, async: false

  alias Platform.Accounts.User
  alias Platform.Branding
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.ManifestController
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation, as: VipsOperation

  setup do
    prev = Application.get_env(:platform, :chat_attachments_root)
    scratch = Platform.TestTemp.mkdir!("manifest_controller_test")
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
        email: "manifest-#{n}@example.com",
        name: "Manifest #{n}",
        oidc_sub: "oidc-manifest-#{n}"
      })
      |> Repo.insert!()

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Tenancy.get_org_by_slug!("acme").id,
      role: "admin"
    })
    |> Repo.insert!()

    user
  end

  # A flat 600px square — clears `IconSet`'s 512px floor.
  defp solid_png(rgb, side \\ 600) do
    {:ok, one} = VipsOperation.black(1, 1)
    {:ok, coloured} = VipsOperation.linear(one, [1.0, 1.0, 1.0], Enum.map(rgb, &(&1 * 1.0)))
    {:ok, cast} = VipsOperation.cast(coloured, :VIPS_FORMAT_UCHAR)
    {:ok, tiled} = VipsOperation.embed(cast, 0, 0, side, side, extend: :VIPS_EXTEND_COPY)
    {:ok, srgb} = VipsOperation.colourspace(tiled, :VIPS_INTERPRETATION_sRGB)
    {:ok, bytes} = VipsImage.write_to_buffer(srgb, ".png")
    bytes
  end

  # Calls the action directly — see the moduledoc for why not the endpoint.
  defp render(conn) do
    conn = ManifestController.show(conn, %{})
    assert conn.state == :sent
    {conn, Jason.decode!(conn.resp_body)}
  end

  defp icon(body, purpose) do
    Enum.find(body["icons"], fn i -> Map.get(i, "purpose") == purpose end)
  end

  # ── Default pin ────────────────────────────────────────────────────────

  describe "default render (no upload)" do
    test "matches the retired static manifest field for field, except the three corrections",
         %{conn: conn} do
      {_conn, body} = render(conn)

      # Unchanged from the shipped file.
      assert body["name"] == "Suite"
      assert body["short_name"] == "Suite"
      assert body["start_url"] == "/chat"
      assert body["display"] == "standalone"
      assert body["orientation"] == "portrait"

      # Correction 1 + 2: the two colours are dark base-100, NOT the
      # shipped `#ffffff` / `#000000`.
      assert body["background_color"] == "#171b25"
      assert body["theme_color"] == "#171b25"
      refute body["background_color"] == "#ffffff"
      refute body["theme_color"] == "#000000"

      # The icon list has the same three entries in the same order.
      assert [
               %{"src" => "/images/icon-192.png", "sizes" => "192x192", "type" => "image/png"},
               %{"src" => "/images/icon-512.png", "sizes" => "512x512", "type" => "image/png"},
               %{"sizes" => "512x512", "type" => "image/png", "purpose" => "maskable"} = maskable
             ] = body["icons"]

      # Correction 3: the maskable entry has its OWN src.
      assert maskable["src"] == "/images/icon-512-maskable.png"
      refute maskable["src"] == "/images/icon-512.png"

      # Exactly these keys, nothing extra and nothing missing.
      assert Enum.sort(Map.keys(body)) ==
               ~w(background_color display icons name orientation short_name start_url theme_color)
    end

    test "the committed default maskable asset is a real padded derivation, not a copy" do
      images = Path.join(:code.priv_dir(:platform), "static/images")
      maskable = File.read!(Path.join(images, "icon-512-maskable.png"))
      any = File.read!(Path.join(images, "icon-512.png"))

      refute maskable == any

      {:ok, img} = VipsImage.new_from_buffer(maskable)
      assert VipsImage.width(img) == 512
      assert VipsImage.height(img) == 512
      # Opaque: no alpha band.
      assert VipsImage.bands(img) == 3

      # The corner is the seeded background colour — the padding rule ran.
      {:ok, corner} = VipsOperation.getpoint(img, 2, 2)
      assert Enum.map(corner, &round/1) == [0x17, 0x1B, 0x25]

      {:ok, any_img} = VipsImage.new_from_buffer(any)
      {:ok, any_corner} = VipsOperation.getpoint(any_img, 2, 2)
      refute Enum.map(any_corner, &round/1) == [0x17, 0x1B, 0x25]
    end
  end

  # ── Headers ────────────────────────────────────────────────────────────

  describe "response headers" do
    test "content type is application/manifest+json and the body is not cacheable",
         %{conn: conn} do
      {conn, _body} = render(conn)

      assert conn.status == 200
      assert [ct] = get_resp_header(conn, "content-type")
      assert ct =~ "application/manifest+json"
      assert get_resp_header(conn, "cache-control") == ["no-cache"]
    end
  end

  # ── Through the endpoint (only meaningful after the stage-6 cutover) ──

  describe "through the endpoint" do
    test "the static file is gone from the tree and from static_paths" do
      refute File.exists?(Path.join(:code.priv_dir(:platform), "static/manifest.json"))
      refute File.exists?(Path.join(:code.priv_dir(:platform), "static/favicon.ico"))
      refute "manifest.json" in PlatformWeb.static_paths()
      refute "favicon.ico" in PlatformWeb.static_paths()
      # The moved .ico is still shipped, under the prefix that IS static.
      assert File.exists?(Path.join(:code.priv_dir(:platform), "static/images/favicon.ico"))
      assert "images" in PlatformWeb.static_paths()
    end

    test "GET /manifest.json reaches the controller, not a file", %{conn: conn} do
      {:ok, _} = Branding.update_identity(admin!(), %{app_name: "SENTINEL-XYZ"})

      conn = get(conn, "/manifest.json")

      assert conn.status == 200
      assert [ct] = get_resp_header(conn, "content-type")
      # `Plug.Static` would have said `application/json` for a `.json` file.
      assert ct =~ "application/manifest+json"
      assert get_resp_header(conn, "cache-control") == ["no-cache"]

      body = Jason.decode!(conn.resp_body)
      # A file cannot carry a value written to the database a moment ago.
      assert body["name"] == "SENTINEL-XYZ"
      assert body["short_name"] == "SENTINEL-XYZ"
      assert icon(body, "maskable")["src"] == "/images/icon-512-maskable.png"
    end

    test "GET /favicon.ico is an uncached 302 whose target moves with the branding version",
         %{conn: conn} do
      before = get(conn, "/favicon.ico")
      assert before.status == 302
      assert redirected_to(before) == "/images/favicon.ico"
      assert get_resp_header(before, "cache-control") == ["no-cache"]

      {:ok, branding} =
        Branding.put_source(admin!(), {:binary, solid_png([10, 120, 200])},
          content_type: "image/png"
        )

      after_ = get(conn, "/favicon.ico")
      assert after_.status == 302
      assert redirected_to(after_) == "/branding/#{branding.version}/favicon_ico"
      refute redirected_to(after_) == redirected_to(before)

      # The target itself answers, unauthenticated, as a real ICO.
      target = get(conn, redirected_to(after_))
      assert target.status == 200
      assert [ct] = get_resp_header(target, "content-type")
      assert ct =~ "image/x-icon"
      assert <<0, 0, 1, 0, _::binary>> = target.resp_body
    end
  end

  # ── Detonations ────────────────────────────────────────────────────────

  describe "the manifest follows the branding row without a restart" do
    test "a name change moves both name and short_name", %{conn: conn} do
      {_conn, before} = render(conn)
      assert before["name"] == "Suite"

      {:ok, _} = Branding.update_identity(admin!(), %{app_name: "SENTINEL-XYZ"})

      {_conn, after_} = render(conn)
      assert after_["name"] == "SENTINEL-XYZ"
      assert after_["short_name"] == "SENTINEL-XYZ"
    end

    test "an upload moves all three icon srcs to /branding/<version>/ and the maskable src differs from the any src",
         %{conn: conn} do
      {:ok, branding} =
        Branding.put_source(admin!(), {:binary, solid_png([200, 30, 40])},
          content_type: "image/png"
        )

      version = branding.version
      assert is_binary(version)

      {_conn, body} = render(conn)

      [i192, i512, maskable] = body["icons"]
      assert i192["src"] == "/branding/#{version}/icon_192"
      assert i512["src"] == "/branding/#{version}/icon_512"
      assert maskable["src"] == "/branding/#{version}/icon_512_maskable"
      assert maskable["purpose"] == "maskable"
      refute maskable["src"] == i512["src"]

      for i <- body["icons"], do: assert(String.starts_with?(i["src"], "/branding/#{version}/"))
      refute Enum.any?(body["icons"], &String.starts_with?(&1["src"], "/images/"))

      assert icon(body, "maskable") == maskable
    end
  end
end
