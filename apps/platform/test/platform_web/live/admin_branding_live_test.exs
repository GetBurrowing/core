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

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Branding
  alias Platform.Branding.IconSet
  alias Platform.Branding.IconStorage
  alias Platform.Branding.Palette
  alias Platform.Branding.Presets
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership
  alias Vix.Vips.Image, as: VipsImage
  alias PlatformWeb.AdminBrandingLive
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
      org_id: Tenancy.get_org_by_slug!("acme").id,
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

      assert {:error, {_, %{to: "/access-denied?module=admin"}}} =
               conn |> authenticated_conn(user) |> live(~p"/admin/branding")
    end

    test "an Acme admin gets the form", %{conn: conn} do
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

  describe "the page owns its scroller" do
    # The app shell bounds the document: `.app-shell-root` is
    # `h-[100dvh] overflow-hidden` and `<main data-scroll-container>` is
    # `overflow-hidden`, whose comment states the contract outright —
    # "per-LiveView panels supply their own `overflow-y-auto` scrollers."
    # This page shipped without one, so everything past the fold was
    # unreachable: it rendered correctly and could not be scrolled to.
    #
    # WHAT THIS TEST CANNOT DO, stated so nobody mistakes it for proof:
    # a LiveView test has no viewport, no layout and no scrolling, so it
    # cannot demonstrate that the page scrolls. That is exactly why the
    # original defect passed a green suite. This asserts only that the
    # structural pieces the shell requires are PRESENT — it is a
    # regression guard against their removal, not evidence of the fix.
    test "the root is the bounded column and a scroller is inside it", %{conn: conn} do
      {:ok, _view, html} = conn |> admin_conn() |> live(~p"/admin/branding")

      {:ok, doc} = Floki.parse_document(html)

      root = Floki.find(doc, ~s([data-role="admin-branding"]))
      assert root != [], "the page root marker is gone; this guard is now blind"

      root_class = root |> Floki.attribute("class") |> List.first() || ""

      # `h-full` is what lets the column receive <main>'s bounded height;
      # `min-h-0` is what lets it shrink below its intrinsic content
      # height. Without both, `flex-1` on the child cannot bound anything.
      for required <- ["flex", "h-full", "min-h-0", "flex-col"] do
        assert String.contains?(root_class, required),
               "page root must carry `#{required}` (shell bounds the document); got: #{root_class}"
      end

      scrollers =
        root
        |> Floki.find("[class]")
        |> Enum.filter(fn el ->
          el
          |> Floki.attribute("class")
          |> List.first()
          |> Kernel.||("")
          |> String.contains?("overflow-y-auto")
        end)

      assert scrollers != [],
             "no `overflow-y-auto` inside the page: the shell will clip everything past 100dvh"
    end
  end

  describe "app colours (task 01a0dbee stage 4)" do
    # A mid-grey surface with NO readable body text: black is under 4.5:1 and
    # so is the dark theme's near-white. Palette's moduledoc puts the blocking
    # band at about #6c6c6c..#737373. The stage spec's own example, #777777,
    # sits OUTSIDE that band (black on it is 4.69:1) and does not block; the
    # first test below pins that so the example cannot be silently re-used.
    # Stage 5 moved body text onto Suite's own base-content colours
    # (Palette.body_text/0); the light one IS #000000, so #777777 still
    # passes at 4.69:1 and that gate went back to the orchestrator.
    @blocking_grey "#707070"

    defp colours_form(view), do: form(view, "#app-colours-form")

    defp change_colour(view, field, value) do
      view
      |> colours_form()
      |> render_change(%{"_target" => ["colors", field], "colors" => %{field => value}})
    end

    defp attr_of(html, selector, attr) do
      {:ok, doc} = Floki.parse_document(html)
      doc |> Floki.find(selector) |> Floki.attribute(attr) |> List.first()
    end

    defp text_of(html, selector) do
      {:ok, doc} = Floki.parse_document(html)
      doc |> Floki.find(selector) |> Floki.text() |> String.trim()
    end

    defp save_disabled?(html) do
      attr_of(html, ~s([data-role="color-save"]), "disabled") != nil
    end

    # The 01a0dbee spec expected #777777 NOT to block, and it did not while the
    # light body text was #000000 (4.69:1). The Burrow spec's warm ink #221f1b
    # would have made it block (3.66:1), but stage 4 of task 01a120c5 kept the
    # light body text black for secondary-text AA, so Palette (which picks body
    # text from the two shipped base-content colours, Brosnan's 2026-09-26
    # decision) lets #777777 through again: 4.6895:1 against #000000.
    test "the blocking example is real, and #777777 does not block under black body text" do
      assert Palette.blocked?(:light, %{surface: @blocking_grey})
      refute Palette.blocked?(:light, %{surface: "#777777"})
    end

    test "a fresh install: defaults as placeholders, nothing stored, no #install-theme",
         %{conn: conn} do
      conn = admin_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/admin/branding")

      assert html =~ ~s(data-role="app-colours")
      defaults = Palette.suite_defaults()

      for mode <- [:light, :dark], slot <- [:action, :surface] do
        sel = "#colors-#{mode}_#{slot}"
        assert attr_of(html, sel, "value") in [nil, ""]
        assert attr_of(html, sel, "placeholder") == defaults[mode][slot]
      end

      assert attr_of(html, "#colors-light_accent", "placeholder") == "same as action"
      assert text_of(html, ~s([data-role="color-preset-label"])) == "current: Burrow default"
      assert attr_of(html, ~s([data-role="color-preview-light"]), "style") in [nil, ""]

      page = conn |> get(~p"/admin/branding") |> html_response(200)
      refute page =~ ~s(id="install-theme")
    end

    test "the section sits between the identity form and the icon preview", %{conn: conn} do
      {:ok, _view, html} = conn |> admin_conn() |> live(~p"/admin/branding")

      {identity, _} = :binary.match(html, ~s(id="branding-identity-form"))
      {colours, _} = :binary.match(html, ~s(data-role="app-colours"))
      {icons, _} = :binary.match(html, ~s(data-role="branding-preview"))
      assert identity < colours and colours < icons
    end

    test "applying a preset fills both modes and the label reads its name", %{conn: conn} do
      {:ok, view, _html} = conn |> admin_conn() |> live(~p"/admin/branding")
      nord = Presets.get("nord")

      html = view |> element(~s([data-role="color-preset"][data-preset="nord"])) |> render_click()

      for mode <- [:light, :dark], slot <- [:action, :surface, :accent] do
        assert attr_of(html, "#colors-#{mode}_#{slot}", "value") == nord[mode][slot]
      end

      assert text_of(html, ~s([data-role="color-preset-label"])) == "current: Nord"

      assert attr_of(html, ~s([data-role="color-preview-dark"]), "style") =~
               "--color-base-100:#{nord.dark.surface};"

      # A draft, not a save.
      assert Branding.get().light_action == nil
    end

    test "editing one hex after a preset relabels it Custom (from <Name>)", %{conn: conn} do
      {:ok, view, _html} = conn |> admin_conn() |> live(~p"/admin/branding")
      view |> element(~s([data-role="color-preset"][data-preset="nord"])) |> render_click()

      html = change_colour(view, "dark_action", "#abc")

      assert text_of(html, ~s([data-role="color-preset-label"])) == "current: Custom (from Nord)"
      # #RGB expands and the preview follows the draft.
      assert attr_of(html, ~s([data-role="color-preview-dark"]), "style") =~
               "--color-primary:#aabbcc;"
    end

    test "the native swatch updates the hex field and the preview through _target",
         %{conn: conn} do
      {:ok, view, _html} = conn |> admin_conn() |> live(~p"/admin/branding")

      html = change_colour(view, "light_action_swatch", "#7a3fd1")

      assert attr_of(html, "#colors-light_action", "value") == "#7a3fd1"

      assert attr_of(html, ~s([data-role="color-preview-light"]), "style") =~
               "--color-primary:#7a3fd1;"
    end

    test "the preview renders the DRAFT, not the saved colours", %{conn: conn} do
      {:ok, _} =
        Branding.update_colors(create_user!("admin"), %{"light_action" => "#5e81ac"})

      {:ok, view, html} = conn |> admin_conn() |> live(~p"/admin/branding")
      assert attr_of(html, ~s([data-role="color-preview-light"]), "style") =~ "#5e81ac"

      html = change_colour(view, "light_action", "#7a3fd1")
      style = attr_of(html, ~s([data-role="color-preview-light"]), "style")
      assert style =~ "--color-primary:#7a3fd1;"
      refute style =~ "#5e81ac"
      assert Branding.get().light_action == "#5e81ac"

      # Suite default applied as a draft: the preview carries no inline style
      # and opts out of the saved #install-theme block, so it shows app.css.
      html =
        view
        |> element(~s([data-role="color-preset"][data-preset="suite_default"]))
        |> render_click()

      assert attr_of(html, ~s([data-role="color-preview-light"]), "style") in [nil, ""]
      assert attr_of(html, ~s([data-role="color-preview-light"]), "data-theme-preview") != nil
    end

    test "a blocking surface renders its reason beside a disabled Save", %{conn: conn} do
      {:ok, view, html} = conn |> admin_conn() |> live(~p"/admin/branding")
      refute save_disabled?(html)

      html = change_colour(view, "light_surface", @blocking_grey)

      assert save_disabled?(html)
      reason = text_of(html, ~s([data-role="color-block-reason"]))
      assert reason =~ "Light: Body text on this surface is"
      assert reason =~ "It needs 4.5:1 to be readable."

      assert html =~ ~s(data-level="block")

      assert attr_of(html, ~s([data-role="color-save"]), "data-confirm") ==
               AdminBrandingLive.save_scope()
    end

    # Stage 5 (e2e finding 01a0dbfb-dc60-7001): the field used to echo the RAW
    # text, so '#f55' stayed '#f55' while the swatch showed #ff5555. Both the
    # value and data-normalized (which the HexField hook copies in on blur,
    # because LiveView never patches a focused input's value) must carry the
    # normalised hex.
    for {typed, label} <- [{"#F55", "shorthand"}, {"ff5555", "a #-less hex"}] do
      test "#{label} is normalised in its own field (#{typed} -> #ff5555)", %{conn: conn} do
        {:ok, view, _html} = conn |> admin_conn() |> live(~p"/admin/branding")

        html = change_colour(view, "light_action", unquote(typed))

        assert attr_of(html, "#colors-light_action", "value") == "#ff5555"
        assert attr_of(html, "#colors-light_action", "data-normalized") == "#ff5555"
        assert attr_of(html, "#colors-light_action", "phx-hook") == "HexField"
        assert attr_of(html, "#colors-light_action-swatch", "value") == "#ff5555"
      end
    end

    test "an invalid entry stays as typed beside its error, not normalised away",
         %{conn: conn} do
      {:ok, view, _html} = conn |> admin_conn() |> live(~p"/admin/branding")

      html = change_colour(view, "light_action", "#12")

      assert attr_of(html, "#colors-light_action", "value") == "#12"
      assert attr_of(html, "#colors-light_action", "data-normalized") == "#12"

      assert text_of(html, ~s([data-role="color-light-action"] [data-role="color-input-error"])) =~
               "Not a colour"
    end

    test "clearing a field leaves it empty, not the Suite default", %{conn: conn} do
      {:ok, view, _html} = conn |> admin_conn() |> live(~p"/admin/branding")
      change_colour(view, "light_action", "#abc")

      html = change_colour(view, "light_action", "  ")

      assert attr_of(html, "#colors-light_action", "value") in [nil, ""]
    end

    test "an unparseable hex shows an inline error and keeps the last good colour",
         %{conn: conn} do
      {:ok, view, _html} = conn |> admin_conn() |> live(~p"/admin/branding")
      change_colour(view, "light_surface", "#fbfaf5")

      html = change_colour(view, "light_surface", "#12")

      assert text_of(html, ~s([data-role="color-light-surface"] [data-role="color-input-error"])) =~
               "Not a colour"

      assert attr_of(html, "#colors-light_surface", "value") == "#12"
      assert attr_of(html, "#colors-light_surface-swatch", "value") == "#fbfaf5"

      assert attr_of(html, ~s([data-role="color-preview-light"]), "style") =~
               "--color-base-100:#fbfaf5;"
    end

    test "save persists the draft and full-redirects so the root layout re-renders",
         %{conn: conn} do
      {:ok, view, _html} = conn |> admin_conn() |> live(~p"/admin/branding")
      view |> element(~s([data-role="color-preset"][data-preset="nord"])) |> render_click()

      assert {:error, {:redirect, %{to: "/admin/branding"}}} =
               view |> colours_form() |> render_submit()

      saved = Branding.get()
      assert saved.color_preset == "nord"

      assert Branding.app_colors(saved) == %{
               light: Presets.get("nord").light,
               dark: Presets.get("nord").dark
             }
    end

    test "the server refuses a blocked palette even when Save is bypassed", %{conn: conn} do
      {:ok, view, _html} = conn |> admin_conn() |> live(~p"/admin/branding")
      change_colour(view, "light_surface", @blocking_grey)

      # The disabled button is client-side only; a tampered form still submits.
      html = view |> colours_form() |> render_submit()

      assert text_of(html, ~s([data-role="color-save-error"])) =~ "It needs 4.5:1"
      assert Branding.get().light_surface == nil
    end

    test "reset puts every colour and the preset back to nil", %{conn: conn} do
      admin = create_user!("admin")
      preset = Presets.get("dracula")

      {:ok, _} =
        Branding.update_colors(admin, %{
          "light_action" => preset.light.action,
          "dark_surface" => preset.dark.surface,
          "color_preset" => "dracula"
        })

      {:ok, view, _html} = conn |> authenticated_conn(admin) |> live(~p"/admin/branding")

      assert {:error, {:redirect, %{to: "/admin/branding"}}} =
               view |> element(~s([data-role="color-reset"])) |> render_click()

      saved = Branding.get()
      assert saved.color_preset == nil

      assert Branding.app_colors(saved) == %{
               light: %{action: nil, surface: nil, accent: nil},
               dark: %{action: nil, surface: nil, accent: nil}
             }
    end

    test "cancel restores the saved values", %{conn: conn} do
      {:ok, view, _html} = conn |> admin_conn() |> live(~p"/admin/branding")
      change_colour(view, "dark_action", "#9fe870")

      html = view |> element(~s([data-role="color-cancel"])) |> render_click()

      assert attr_of(html, "#colors-dark_action", "value") in [nil, ""]
      assert attr_of(html, ~s([data-role="color-preview-dark"]), "style") in [nil, ""]
    end

    test "a save_colors push from an actor who is no longer an admin is refused",
         %{conn: conn} do
      user = create_user!("admin")
      {:ok, view, _html} = conn |> authenticated_conn(user) |> live(~p"/admin/branding")
      view |> element(~s([data-role="color-preset"][data-preset="nord"])) |> render_click()

      {1, _} =
        Repo.update_all(
          from(m in OrgMembership, where: m.user_id == ^user.id),
          set: [role: "member"]
        )

      assert {:error, :unauthorized} =
               Branding.update_colors(user, %{"light_action" => "#5e81ac"})

      html = view |> colours_form() |> render_submit()

      assert html =~ "access"
      assert Branding.get().color_preset == nil
      assert Branding.get().light_action == nil
    end

    test "Match app colours copies the dark surface into the browser-chrome fields",
         %{conn: conn} do
      {:ok, view, _html} = conn |> admin_conn() |> live(~p"/admin/branding")
      view |> element(~s([data-role="color-preset"][data-preset="nord"])) |> render_click()

      html = view |> element(~s([data-role="branding-match-app-colours"])) |> render_click()

      dark_surface = Presets.get("nord").dark.surface
      assert attr_of(html, ~s([data-role="branding-background-color"]), "value") == dark_surface
      assert attr_of(html, ~s([data-role="branding-theme-color"]), "value") == dark_surface
      # Copied, not saved.
      refute Branding.get().background_color == dark_surface
    end

    test "a colour save in another window replaces this window's draft", %{conn: conn} do
      {:ok, view, _html} = conn |> admin_conn() |> live(~p"/admin/branding")

      {:ok, _} =
        Branding.update_colors(create_user!("admin"), %{
          "light_action" => "#5e81ac",
          "color_preset" => "nord"
        })

      html = render(view)
      assert attr_of(html, "#colors-light_action", "value") == "#5e81ac"
      assert text_of(html, ~s([data-role="color-preset-label"])) == "current: Custom (from Nord)"
    end

    test "a name save does not discard a colour draft", %{conn: conn} do
      {:ok, view, _html} = conn |> admin_conn() |> live(~p"/admin/branding")
      change_colour(view, "light_action", "#7a3fd1")

      {:ok, _} = Branding.update_identity(create_user!("admin"), %{"app_name" => "Elsewhere"})

      html = render(view)
      assert html =~ "Elsewhere"
      assert attr_of(html, "#colors-light_action", "value") == "#7a3fd1"
    end
  end
end
