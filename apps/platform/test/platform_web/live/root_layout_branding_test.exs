defmodule PlatformWeb.RootLayoutBrandingTest do
  @moduledoc """
  The app-shell `<head>` renders the install's identity from
  `Platform.Branding` (task `01a0879a` stage 7).

  ## Why the detonation moves BOTH surfaces from ONE action

  Safari reads `apple-touch-icon` and `apple-mobile-web-app-title` from the
  CURRENT PAGE'S `<head>` at Add-to-Home-Screen time; Android reads the
  manifest. A test that moves only one of the two cannot catch the
  half-wired state where the manifest reads "SENTINEL-XYZ" and the
  home-screen label still says "Suite" — so one upload + one rename is
  followed by assertions on the rendered head AND `/manifest.json` in the
  SAME test, including that the `/branding/<version>/` segment is identical
  across both.

  The page rendered is `/admin/branding` as an Acme admin: it is the one
  page whose fixture this test already needs, and it goes through the
  `:browser` pipeline and the root layout like every other app page.
  """

  use PlatformWeb.ConnCase, async: false

  alias Platform.Accounts.User
  alias Platform.Branding
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation, as: VipsOperation

  setup do
    prev = Application.get_env(:platform, :chat_attachments_root)
    scratch = Platform.TestTemp.mkdir!("root_layout_branding_test")
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

  defp admin! do
    n = System.unique_integer([:positive])

    user =
      %User{}
      |> User.changeset(%{
        email: "root-layout-#{n}@example.com",
        name: "Root Layout #{n}",
        oidc_sub: "oidc-root-layout-#{n}"
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

  defp solid_png(rgb, side \\ 600) do
    {:ok, one} = VipsOperation.black(1, 1)
    {:ok, coloured} = VipsOperation.linear(one, [1.0, 1.0, 1.0], Enum.map(rgb, &(&1 * 1.0)))
    {:ok, cast} = VipsOperation.cast(coloured, :VIPS_FORMAT_UCHAR)
    {:ok, tiled} = VipsOperation.embed(cast, 0, 0, side, side, extend: :VIPS_EXTEND_COPY)
    {:ok, srgb} = VipsOperation.colourspace(tiled, :VIPS_INTERPRETATION_sRGB)
    {:ok, bytes} = VipsImage.write_to_buffer(srgb, ".png")
    bytes
  end

  defp render_page(conn, user) do
    conn =
      conn
      |> Plug.Test.init_test_session(%{"current_user_id" => user.id})
      |> get("/admin/branding")

    assert conn.status == 200
    html_response(conn, 200)
  end

  defp render_head(conn, user) do
    [head] = Regex.run(~r/<head>.*<\/head>/s, render_page(conn, user), capture: :first)
    head
  end

  # The opening <html ...> tag only. The inline background lives on the root
  # element, not in <head>, so the head helpers cannot see it.
  defp html_tag(html) do
    [tag] = Regex.run(~r/<html\b[^>]*>/, html, capture: :first)
    tag
  end

  defp meta(head, name) do
    case Regex.run(~r/<meta name="#{name}" content="([^"]*)"/, head) do
      [_, content] -> content
      nil -> nil
    end
  end

  defp link_href(head, attrs) do
    # Attribute order in the rendered tag follows the template, so match
    # each attribute independently within one <link ...> tag.
    head
    |> then(&Regex.scan(~r/<link\b[^>]*>/, &1))
    |> List.flatten()
    |> Enum.find(fn tag -> Enum.all?(attrs, &String.contains?(tag, &1)) end)
    |> case do
      nil -> nil
      tag -> Regex.run(~r/href="([^"]*)"/, tag) |> Enum.at(1)
    end
  end

  defp title(head) do
    [_, t] = Regex.run(~r/<title[^>]*>(.*?)<\/title>/s, head)
    t
  end

  describe "default render (no upload)" do
    test "carries Suite, dark base-100 and the /images/ paths, with no framework suffix",
         %{conn: conn} do
      head = render_head(conn, admin!())

      assert meta(head, "apple-mobile-web-app-title") == "Suite"
      assert meta(head, "theme-color") == "#171b25"
      refute meta(head, "theme-color") == "#000000"

      assert link_href(head, [~s(rel="icon"), ~s(type="image/x-icon")]) == "/images/favicon.ico"
      assert link_href(head, [~s(rel="icon"), ~s(sizes="32x32")]) == "/images/favicon-32.png"
      assert link_href(head, [~s(rel="icon"), ~s(sizes="16x16")]) == "/images/favicon-16.png"
      assert link_href(head, [~s(rel="apple-touch-icon")]) == "/images/apple-touch-icon.png"
      assert link_href(head, [~s(rel="manifest")]) == "/manifest.json"

      refute head =~ "Phoenix Framework"
      refute title(head) =~ "Phoenix"
      assert title(head) =~ "Branding"
    end

    test "the title falls back to the app name, not the framework scaffold", %{conn: conn} do
      head = render_head(conn, admin!())
      assert head =~ ~s(data-default="Suite")
      refute head =~ "data-suffix"
    end

    test "the root element carries the branding background inline, not a literal",
         %{conn: conn} do
      # Stage 8: an installed iOS web app cold-launches into a white view and
      # paints nothing until app.css arrives; the inline background is what
      # <html> is from the first parsed byte. This pins that the value is the
      # seeded dark base-100 from the branding row.
      tag = html_tag(render_page(conn, admin!()))
      assert tag =~ ~s(style="background-color: #171b25")
    end
  end

  describe "detonation: the inline root background follows the branding row" do
    test "changing background_color moves the style attribute", %{conn: conn} do
      admin = admin!()
      {:ok, _} = Branding.update_identity(admin, %{background_color: "#0a0b0c"})

      tag = html_tag(render_page(conn, admin))
      assert tag =~ ~s(style="background-color: #0a0b0c")
      refute tag =~ "#171b25"
    end
  end

  describe "detonation: one upload + one rename moves the head AND the manifest" do
    test "every identity value on both surfaces follows the branding row", %{conn: conn} do
      admin = admin!()

      {:ok, branding} =
        Branding.put_source(admin, {:binary, solid_png([30, 140, 60])}, content_type: "image/png")

      {:ok, _} = Branding.update_identity(admin, %{app_name: "SENTINEL-XYZ"})
      version = branding.version
      assert is_binary(version)

      # Surface 1: the rendered <head>.
      head = render_head(conn, admin)

      assert meta(head, "apple-mobile-web-app-title") == "SENTINEL-XYZ"
      assert head =~ ~s(data-default="SENTINEL-XYZ")

      assert link_href(head, [~s(rel="icon"), ~s(type="image/x-icon")]) ==
               "/branding/#{version}/favicon_ico"

      assert link_href(head, [~s(rel="icon"), ~s(sizes="32x32")]) ==
               "/branding/#{version}/favicon_32"

      assert link_href(head, [~s(rel="icon"), ~s(sizes="16x16")]) ==
               "/branding/#{version}/favicon_16"

      assert link_href(head, [~s(rel="apple-touch-icon")]) ==
               "/branding/#{version}/apple_touch"

      refute head =~ ~s(content="Suite")
      refute head =~ "/images/favicon"
      refute head =~ "/images/apple-touch-icon"

      # Surface 2: the manifest, through the endpoint, in the SAME test.
      body = conn |> get("/manifest.json") |> json_response(200)

      assert body["name"] == "SENTINEL-XYZ"
      assert body["short_name"] == "SENTINEL-XYZ"
      srcs = Enum.map(body["icons"], & &1["src"])
      assert Enum.all?(srcs, &String.starts_with?(&1, "/branding/#{version}/"))
      assert "/branding/#{version}/icon_512_maskable" in srcs

      # The version segment is identical across both surfaces.
      head_versions =
        Regex.scan(~r{/branding/([0-9a-f]+)/}, head) |> Enum.map(&Enum.at(&1, 1)) |> Enum.uniq()

      manifest_versions =
        Regex.scan(~r{/branding/([0-9a-f]+)/}, Jason.encode!(body))
        |> Enum.map(&Enum.at(&1, 1))
        |> Enum.uniq()

      assert head_versions == [version]
      assert manifest_versions == [version]

      # And every href the head names actually answers.
      for href <- [
            link_href(head, [~s(rel="icon"), ~s(type="image/x-icon")]),
            link_href(head, [~s(rel="icon"), ~s(sizes="32x32")]),
            link_href(head, [~s(rel="icon"), ~s(sizes="16x16")]),
            link_href(head, [~s(rel="apple-touch-icon")])
          ] do
        assert get(build_conn(), href).status == 200, "#{href} did not answer"
      end
    end
  end

  describe "the guest meeting layout" do
    test "renders the same identity from the same row" do
      admin = admin!()
      {:ok, _} = Branding.update_identity(admin, %{app_name: "SENTINEL-XYZ"})

      html =
        Phoenix.Template.render_to_string(PlatformWeb.Layouts, "guest_root", "html", %{
          conn: build_conn(),
          inner_content: "",
          page_title: nil
        })

      assert html =~ ~s(data-suffix=" · SENTINEL-XYZ")
      assert html_tag(html) =~ ~s(style="background-color: #171b25")
      assert html =~ ~s(href="/images/favicon.ico")
      assert html =~ ~s(content="#171b25")
      refute html =~ "Phoenix Framework"
    end
  end
end
