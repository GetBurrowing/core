defmodule PlatformWeb.BurrowMarkTest do
  @moduledoc """
  The default brand mark is the Burrow arch everywhere it renders, and an
  admin upload still wins over it (task `01a120c5` stage 2).

  ## Asserted by CONTENT, not by file name

  A path check alone passes against a file that merely has the right name.
  Every rendered logo `src` here is resolved back to the bytes under
  `priv/static` and those bytes must carry the arch's inner path, whose
  first coordinates are `#{"M824.79,1143.17"}`. The Phoenix bird and the
  match-stick glyph that shipped before carry neither.

  ## What each mutation detonates

    * Revert the rail logo (`icon_rail.ex`, the header `<img>`) to
      `/images/logo.svg` with `alt="Startup Suite"`: the shell test fails on
      both the src and the alt.
    * Make `Branding.icon_url/2` ignore `source_storage_key`: the override
      test fails, because the head and manifest fall back to `/images/...`.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Branding
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.Org
  alias Platform.Tenancy.OrgMembership
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation, as: VipsOperation

  # The first coordinates of the arch's inner path in burrow-mark.svg.
  @arch_marker "M824.79,1143.17"

  # sha256 of the committed repo-default icon-512.png, regenerated from
  # burrow-mark.svg by Platform.Branding.IconSet.derive/2 on #191b20.
  @icon_512_sha256 "edca2407552cab43f246fd3c1019ebbc4b81db96c9c5cb22e80176b0c571704c"
  # ... and of the match-stick icon-512.png it replaced (main c6f96bb3b).
  @previous_icon_512_sha256 "09e3ce73828ff57695f92c92a2b191cea1bc68445340f6c063d951ed1458ab0c"

  # Byte copies of the spec lockups (spec dir burrow-spec-01a120c5).
  @lockup_sha256 "921ab0ed6ea46b8b04576591def4e22c08d2fa97482675c7fb5f213acbec6a81"
  @lockup_darktext_sha256 "b60ef80e97b44dc33171c6ab9b823819aadfca9cf4ddd2284f58aac1781efb94"

  setup do
    prev = Application.get_env(:platform, :chat_attachments_root)
    scratch = Platform.TestTemp.mkdir!("burrow_mark_test")
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

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp images_dir, do: Path.join(:code.priv_dir(:platform), "static/images")

  # Resolve a rendered `/images/...` src (possibly digested or with a
  # `?vsn=` query) back to the committed file's bytes.
  defp asset_bytes!(src) do
    path = src |> URI.parse() |> Map.fetch!(:path)
    assert "/images/" <> name = path
    File.read!(Path.join(images_dir(), name))
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp img_srcs(html, selector) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("src")
  end

  defp img_alts(html, selector) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("alt")
  end

  defp assert_burrow_mark!(src) do
    assert src =~ ~r{^/images/burrow-mark(-[0-9a-f]+)?\.svg},
           "expected the Burrow mark, got #{src}"

    assert asset_bytes!(src) =~ @arch_marker
  end

  defp user!(name) do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{
      email: "burrow-mark-#{n}@example.com",
      name: name,
      oidc_sub: "oidc-burrow-mark-#{n}"
    })
    |> Repo.insert!()
  end

  defp root_admin! do
    user = user!("Burrow Admin")

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Tenancy.get_org_by_slug!("acme").id,
      role: "admin"
    })
    |> Repo.insert!()

    user
  end

  defp external_user! do
    n = System.unique_integer([:positive])

    org =
      %Org{}
      |> Org.changeset(%{
        name: "Burrow Tenant #{n}",
        slug: "burrow_mark_tenant_#{n}",
        parent_org_id: Tenancy.get_org_by_slug!("acme").id
      })
      |> Repo.insert!()

    user = user!("Burrow External")
    {:ok, _} = Tenancy.mark_membership_external(%{user_id: user.id, org_id: org.id})
    Tenancy.allow_dm(user, org)
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

  defp link_href(head, attrs) do
    head
    |> then(&Regex.scan(~r/<link\b[^>]*>/, &1))
    |> List.flatten()
    |> Enum.find(fn tag -> Enum.all?(attrs, &String.contains?(tag, &1)) end)
    |> case do
      nil -> nil
      tag -> Regex.run(~r/href="([^"]*)"/, tag) |> Enum.at(1)
    end
  end

  # ── The shipped assets ──────────────────────────────────────────────────

  describe "shipped assets" do
    test "burrow-mark.svg is the arch alone: arch paths present, wordmark absent" do
      svg = File.read!(Path.join(images_dir(), "burrow-mark.svg"))

      assert svg =~ ~s(<g id="arch">)
      assert svg =~ @arch_marker
      # The outer arch path, also unchanged from the lockup.
      assert svg =~ "M523.22,1143.17"
      # The wordmark's fill in either lockup variant, and its first glyph.
      refute svg =~ "#faf6eb"
      refute svg =~ "#1e1a1a"
      refute svg =~ "M518.39,1423.07"
    end

    test "the lockups are byte copies of the spec files" do
      assert sha256(File.read!(Path.join(images_dir(), "burrow-lockup.svg"))) == @lockup_sha256

      assert sha256(File.read!(Path.join(images_dir(), "burrow-lockup-darktext.svg"))) ==
               @lockup_darktext_sha256
    end

    test "the Phoenix bird is gone from the tree" do
      refute File.exists?(Path.join(images_dir(), "logo.svg"))
    end

    test "icon.svg is the Burrow arch, not the match-stick glyph" do
      svg = File.read!(Path.join(images_dir(), "icon.svg"))
      assert svg =~ @arch_marker
      refute svg =~ "Match stick"
    end
  end

  # ── Rendered call sites ─────────────────────────────────────────────────

  describe "rendered call sites" do
    test "the shell sidebar header shows the Burrow mark, alt = the install's app name",
         %{conn: conn} do
      user = root_admin!()
      {:ok, _view, html} = conn |> init_test_session(current_user_id: user.id) |> live("/chat")

      assert [src] = img_srcs(html, "#sidebar-brand img")
      assert_burrow_mark!(src)
      assert img_alts(html, "#sidebar-brand img") == [Branding.app_name()]

      refute html =~ ~s(alt="Startup Suite")
      refute html =~ "/images/logo.svg"
    end

    # Burrow redesign 22 stage 2 deleted the desktop external rail and its
    # brand chip; the phone switcher's chip is the one left.
    test "the external switcher shows the Burrow mark", %{conn: conn} do
      ext = external_user!()

      # No allowlisted space: /chat is the landing, where the flat switcher
      # (external_rail.ex's brand chip) is open by default.
      {:ok, _view, html} =
        %{conn | host: "chat.localhost"}
        |> init_test_session(current_user_id: ext.id)
        |> live("/chat")

      srcs = img_srcs(html, "[data-role=brand-chip] img")
      # The landing switcher's chip only.
      assert length(srcs) == 1
      Enum.each(srcs, &assert_burrow_mark!/1)
      assert Enum.uniq(img_alts(html, "[data-role=brand-chip] img")) == [Branding.app_name()]
      refute html =~ "/images/logo.svg"
    end

    test "the holding page shows the Burrow mark", %{conn: conn} do
      user = user!("Burrow Holding")

      {:ok, _view, html} =
        conn
        |> Plug.Test.init_test_session(%{
          "current_user_id" => user.id,
          "external_admission" => %{state: :holding, reason: :awaiting_grant, user_id: user.id}
        })
        |> live("/welcome")

      assert [src] = img_srcs(html, "[data-role=brand-chip] img")
      assert_burrow_mark!(src)
      refute html =~ "/images/logo.svg"
    end

    test "the app header layout shows the Burrow mark" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <PlatformWeb.Layouts.app flash={%{}}>body</PlatformWeb.Layouts.app>
        """)

      assert [src] = img_srcs(html, "header img")
      assert_burrow_mark!(src)
    end
  end

  # ── PWA / favicon defaults and the admin override ───────────────────────

  describe "repo-default icon set" do
    test "a fresh row's manifest icons are the regenerated /images defaults", %{conn: conn} do
      assert %{source_storage_key: nil} = Branding.get()

      body = conn |> get("/manifest.json") |> json_response(200)
      srcs = Enum.map(body["icons"], & &1["src"])

      assert "/images/icon-512.png" in srcs
      assert Enum.all?(srcs, &String.starts_with?(&1, "/images/"))

      icon_512 = asset_bytes!("/images/icon-512.png")
      assert sha256(icon_512) == @icon_512_sha256
      refute sha256(icon_512) == @previous_icon_512_sha256
    end

    test "an admin upload still wins over the Burrow defaults on the head and the manifest",
         %{conn: conn} do
      admin = root_admin!()

      {:ok, branding} =
        Branding.put_source(admin, {:binary, solid_png([30, 140, 60])}, content_type: "image/png")

      version = branding.version

      html =
        conn |> init_test_session(current_user_id: admin.id) |> get("/chat") |> html_response(200)

      [head] = Regex.run(~r/<head>.*<\/head>/s, html, capture: :first)

      assert link_href(head, [~s(rel="icon"), ~s(sizes="32x32")]) ==
               "/branding/#{version}/favicon_32"

      assert link_href(head, [~s(rel="apple-touch-icon")]) == "/branding/#{version}/apple_touch"
      refute head =~ "/images/favicon"
      refute head =~ "/images/apple-touch-icon"

      body = build_conn() |> get("/manifest.json") |> json_response(200)
      srcs = Enum.map(body["icons"], & &1["src"])
      assert srcs != []
      assert Enum.all?(srcs, &String.starts_with?(&1, "/branding/#{version}/"))
    end
  end
end
