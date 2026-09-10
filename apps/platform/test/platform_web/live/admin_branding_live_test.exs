defmodule PlatformWeb.AdminBrandingLiveTest do
  @moduledoc """
  `/admin/branding` — the install-wide PWA identity form (task `01a0879a`
  stage 4).

  Four properties, each of which has a mutation that reddens it:

    * The route inherits the `:admin` live_session's `:ensure_admin` hook,
      so a non-admin mount halt-redirects. Removing the hook from the
      session reddens "a member (non-admin) mount is redirected".
    * A name change persists and survives a reload.
    * ONE upload produces ALL SEVEN derived keys plus a version.
    * A REJECTED upload renders user-facing copy AND leaves the previous
      branding not merely un-rewritten but still SERVING — the blobs the
      committed row points at are still readable. Asserting "no new row"
      alone would pass on a path that deleted the old blobs first, which
      is the failure `Branding.put_source/3`'s ordering exists to prevent.

  The fixture images are generated rather than committed, for the reason
  `Platform.Branding.IconSetTest` gives: the input's pixel content is the
  thing under test and a committed binary hides it.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Branding
  alias Platform.Branding.IconSet
  alias Platform.Branding.IconStorage
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  defp create_user!(role) do
    n = System.unique_integer([:positive])

    user =
      %User{}
      |> User.changeset(%{
        email: "admin-branding-#{n}@example.com",
        name: "Admin Branding #{n}",
        oidc_sub: "oidc-admin-branding-#{n}"
      })
      |> Repo.insert!()

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Tenancy.get_org_by_slug!("fabrikam").id,
      role: role
    })
    |> Repo.insert!()

    user
  end

  defp authenticated_conn(conn, user) do
    Plug.Test.init_test_session(conn, %{"current_user_id" => user.id})
  end

  defp admin_conn(conn), do: authenticated_conn(conn, create_user!("admin"))

  # A flat square, generated. `side` defaults comfortably above the 512px
  # floor `IconSet` enforces.
  defp solid_png(rgb, side \\ 600) do
    {:ok, one} = Operation.black(1, 1)
    {:ok, coloured} = Operation.linear(one, [1.0, 1.0, 1.0], Enum.map(rgb, &(&1 * 1.0)))
    {:ok, cast} = Operation.cast(coloured, :VIPS_FORMAT_UCHAR)
    {:ok, tiled} = Operation.embed(cast, 0, 0, side, side, extend: :VIPS_EXTEND_COPY)
    {:ok, srgb} = Operation.colourspace(tiled, :VIPS_INTERPRETATION_sRGB)
    {:ok, bytes} = VipsImage.write_to_buffer(srgb, ".png")
    bytes
  end

  defp upload_source(view, bytes, opts) do
    entry = %{
      name: Keyword.get(opts, :name, "logo.png"),
      content: bytes,
      type: Keyword.get(opts, :type, "image/png"),
      size: byte_size(bytes)
    }

    input = file_input(view, "#branding-upload-form", :source, [entry])
    render_upload(input, entry.name)
  end

  defp all_keys(branding) do
    keys = Map.values(branding.derived || %{})
    if branding.source_storage_key, do: [branding.source_storage_key | keys], else: keys
  end

  defp serving?(branding) do
    keys = all_keys(branding)
    keys != [] and Enum.all?(keys, &match?({:ok, _}, IconStorage.get(&1)))
  end

  describe "authorization" do
    test "a member (non-admin) mount is redirected by :ensure_admin", %{conn: conn} do
      user = create_user!("member")

      assert {:error, {:live_redirect, %{to: "/", flash: flash}}} =
               conn |> authenticated_conn(user) |> live(~p"/admin/branding")

      assert flash["error"] =~ "access"
    end

    test "a Fabrikam admin gets the form", %{conn: conn} do
      {:ok, _view, html} = conn |> admin_conn() |> live(~p"/admin/branding")

      assert html =~ ~s(data-role="branding-dropzone")
      assert html =~ ~s(data-role="branding-app-name")
      assert html =~ ~s(data-role="branding-preview")
      # Exactly one file input on the page — see the LiveView moduledoc.
      assert html |> String.split(~s(type="file")) |> length() == 2
    end
  end

  describe "identity form" do
    test "a name change persists and the reloaded page shows it", %{conn: conn} do
      conn = admin_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/admin/branding")

      current = Branding.get()

      view
      |> form("#branding-identity-form", %{
        "branding" => %{
          "app_name" => "Fathom",
          "theme_color" => current.theme_color,
          "background_color" => current.background_color
        }
      })
      |> render_submit()

      assert Branding.app_name() == "Fathom"

      {:ok, _view, html} = live(conn, ~p"/admin/branding")
      assert html =~ "Fathom"
    end

    test "the label counter reports the typed length without blocking a long name", %{conn: conn} do
      {:ok, view, _html} = conn |> admin_conn() |> live(~p"/admin/branding")

      current = Branding.get()

      html =
        view
        |> form("#branding-identity-form", %{
          "branding" => %{
            "app_name" => "Ellis Suite",
            "theme_color" => current.theme_color,
            "background_color" => current.background_color
          }
        })
        |> render_change()

      assert html =~ "currently 14"
      refute html =~ "should be at most"
    end

    test "a malformed colour renders inline instead of raising", %{conn: conn} do
      {:ok, view, _html} = conn |> admin_conn() |> live(~p"/admin/branding")

      html =
        view
        |> form("#branding-identity-form", %{
          "branding" => %{
            "app_name" => "Fathom",
            "theme_color" => "blue",
            "background_color" => "#171b25"
          }
        })
        |> render_submit()

      assert html =~ "6-digit hex"
      refute Branding.theme_color() == "blue"
    end
  end

  describe "source upload" do
    test "one upload derives all seven variants and a version", %{conn: conn} do
      {:ok, view, _html} = conn |> admin_conn() |> live(~p"/admin/branding")

      upload_source(view, solid_png([200, 30, 40]), [])

      branding = Branding.get()

      assert is_binary(branding.version)
      assert branding.version =~ ~r/^[0-9a-f]{12}$/
      assert is_binary(branding.source_storage_key)

      derived_keys = branding.derived |> Map.keys() |> Enum.sort()
      expected = Branding.variants() |> Enum.map(&Atom.to_string/1) |> Enum.sort()
      assert derived_keys == expected
      assert length(derived_keys) == 7

      assert serving?(branding)
    end

    test "the preview strip renders the derived icons after an upload", %{conn: conn} do
      {:ok, view, _html} = conn |> admin_conn() |> live(~p"/admin/branding")

      upload_source(view, solid_png([10, 90, 220]), [])
      html = render(view)

      version = Branding.get().version
      assert html =~ "/branding/#{version}/icon_192"
      assert html =~ "/branding/#{version}/icon_512_maskable"
      assert html =~ "/branding/#{version}/favicon_32"
      # The maskable tile is masked to a circle — that crop IS the check
      # the surface exists to make visible.
      assert html =~ ~r/data-role="branding-preview-maskable"/
      assert html =~ ~r/rounded-full[^>]*data-role="branding-preview-maskable"/s
    end

    test "a too-small source is rejected and the previous branding still serves", %{conn: conn} do
      {:ok, view, _html} = conn |> admin_conn() |> live(~p"/admin/branding")

      upload_source(view, solid_png([200, 30, 40]), [])
      before = Branding.get()
      assert serving?(before)

      html = upload_source(view, solid_png([1, 2, 3], 64), name: "tiny.png")

      assert html =~ ~s(data-role="branding-upload-error")
      assert html =~ IconSet.error_message({:source_too_small, 64, 64})

      unchanged = Branding.get()
      assert unchanged.version == before.version
      assert unchanged.derived == before.derived
      assert unchanged.source_storage_key == before.source_storage_key
      # Not merely un-rewritten — still readable, so the icons the row
      # points at are still being served.
      assert serving?(unchanged)
    end

    test "a .svg claiming image/png is rejected by the filename re-check", %{conn: conn} do
      {:ok, view, _html} = conn |> admin_conn() |> live(~p"/admin/branding")

      upload_source(view, solid_png([200, 30, 40]), [])
      before = Branding.get()

      # LiveView's own `accept` validation short-circuits on the reported
      # type, so this entry reaches consume. The filename is the only
      # thing that gives it away.
      html =
        upload_source(view, solid_png([1, 2, 3]), name: "payload.svg", type: "image/png")

      assert html =~ ~s(data-role="branding-upload-error")
      assert html =~ "not supported"

      unchanged = Branding.get()
      assert unchanged.version == before.version
      assert serving?(unchanged)
    end
  end

  describe "cross-window" do
    test "a save elsewhere updates an open form", %{conn: conn} do
      {:ok, view, _html} = conn |> admin_conn() |> live(~p"/admin/branding")

      {:ok, _} = Branding.update_identity(create_user!("admin"), %{"app_name" => "Elsewhere"})

      assert render(view) =~ "Elsewhere"
    end
  end

  describe "admin index" do
    test "the admin landing page links to /admin/branding", %{conn: conn} do
      {:ok, _view, html} = conn |> admin_conn() |> live(~p"/admin")

      assert html =~ ~s(data-role="admin-branding-link")
      assert html =~ ~s(navigate="/admin/branding") or html =~ ~s(href="/admin/branding")
    end
  end
end
