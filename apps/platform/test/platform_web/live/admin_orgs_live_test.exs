defmodule PlatformWeb.AdminOrgsLiveTest do
  @moduledoc """
  `/admin/orgs` — the human-reachable caller for `Tenancy.create_org/2`
  (task 019ffe9d stage 4).

  Covers the two halves of the authorization story (the `:admin`
  live_session's `:ensure_admin` hook, and the fact that a created org is
  really parented to the root org by the context function rather than by
  the form), plus the three form outcomes: valid, duplicate slug, and
  malformed slug. The duplicate-slug case is the one that matters most —
  it must render as an inline error on `:slug`, never an
  `Ecto.ConstraintError` reaching the browser.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.Org
  alias Platform.Tenancy.OrgMembership
  alias Platform.Tenancy.ScopeColor

  defp create_user!(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          email: "admin-orgs-#{n}@example.com",
          name: "Admin Orgs #{n}",
          oidc_sub: "oidc-admin-orgs-#{n}"
        },
        overrides
      )

    %User{}
    |> User.changeset(attrs)
    |> Repo.insert!()
  end

  defp create_membership!(user, org, role) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: role})
    |> Repo.insert!()
  end

  defp authenticated_conn(conn, user) do
    Plug.Test.init_test_session(conn, %{"current_user_id" => user.id})
  end

  defp admin_user! do
    user = create_user!()
    create_membership!(user, Tenancy.get_org_by_slug!("fabrikam"), "admin")
    user
  end

  defp count_orgs_with_slug(slug) do
    Repo.aggregate(from(o in Org, where: o.slug == ^slug), :count)
  end

  describe "authorization" do
    test "a member (non-admin) mount is redirected by :ensure_admin", %{conn: conn} do
      user = create_user!()
      create_membership!(user, Tenancy.get_org_by_slug!("fabrikam"), "member")

      assert {:error, {:live_redirect, %{to: "/", flash: flash}}} =
               conn |> authenticated_conn(user) |> live(~p"/admin/orgs")

      assert Phoenix.Flash.get(flash, :error) =~ "don't have access"
    end

    test "a user with no memberships is redirected", %{conn: conn} do
      user = create_user!()

      assert {:error, {:live_redirect, %{to: "/"}}} =
               conn |> authenticated_conn(user) |> live(~p"/admin/orgs")
    end
  end

  describe "rendering" do
    test "an admin renders the route and can open the create sheet", %{conn: conn} do
      admin = admin_user!()

      {:ok, view, html} = conn |> authenticated_conn(admin) |> live(~p"/admin/orgs")

      assert html =~ "Admin · Orgs"
      # Seeded root org is listed.
      assert html =~ ~s(data-org-slug="fabrikam")
      # The sheet is not in the DOM until it is opened.
      refute html =~ ~s(id="create-org-sheet")

      opened =
        view
        |> element(~s([data-role="open-create-org"]))
        |> render_click()

      assert opened =~ ~s(id="create-org-sheet")
      assert opened =~ ~s(data-role="create-org-form")
      # Slug format rule is shown up front, not discovered by rejection.
      assert opened =~ "^[a-z][a-z0-9_-]*$"
      # The colour caveat this used to assert is GONE, because the thing it
      # apologised for is done: stage 2 made the chip immediate and stage 4
      # made the colour pickable here. What replaces it is the control
      # itself, so assert that rather than deleting the coverage.
      assert opened =~ ~s(data-role="org-hue-ring")
      assert opened =~ ~s(data-role="org-color-hue-input")
      refute opened =~ "COLOUR still needs one"
    end

    test "the admin hub links to the new surface", %{conn: conn} do
      admin = admin_user!()

      {:ok, _view, html} = conn |> authenticated_conn(admin) |> live(~p"/admin")

      assert html =~ ~s(data-role="admin-orgs-link")
      assert html =~ ~s(href="/admin/orgs")
    end
  end

  describe "colour (task 01a09287 stage 4)" do
    defp open_sheet(conn, admin) do
      {:ok, view, _html} = conn |> authenticated_conn(admin) |> live(~p"/admin/orgs")
      view |> element(~s([data-role="open-create-org"])) |> render_click()
      view
    end

    test "submitting with a hue persists color_hue", %{conn: conn} do
      view = open_sheet(conn, admin_user!())

      html =
        view
        |> form(~s(#create-org-form),
          org: %{name: "Aurora Labs", slug: "aurora_labs", color_hue: "123"}
        )
        |> render_submit()

      assert Repo.get_by!(Org, slug: "aurora_labs").color_hue == 123

      # The swatch is rendered from the stored hue, so the row proves the
      # value reached the DB AND came back out, not merely that the insert
      # did not raise.
      assert html =~ ~s(data-role="org-swatch")
      assert html =~ ~s(data-org-hue="123")
      refute html =~ "No colour"
    end

    test "submitting with no hue succeeds, leaves it nil, and badges the row", %{conn: conn} do
      view = open_sheet(conn, admin_user!())

      html =
        view
        |> form(~s(#create-org-form), org: %{name: "Aurora Labs", slug: "aurora_labs"})
        |> render_submit()

      created = Repo.get_by!(Org, slug: "aurora_labs")
      assert created.color_hue == nil

      assert html =~ ~s(data-role="scope-rail-no")
      assert html =~ "No colour"

      # The badge must not have brought the withdrawn promise back with it.
      refute html =~ "follow-up code change"
    end

    test "the apology copy is gone from the list AND the open sheet", %{conn: conn} do
      # The copy-removal guard. It asserts on the SHEET-OPEN render, because
      # two of the three deleted strings only ever appeared inside the sheet
      # — a list-only assertion would pass on a page that still carried
      # them and would be a guard in name only.
      view = open_sheet(conn, admin_user!())
      html = render(view)

      assert html =~ ~s(data-role="create-org-form"),
             "the sheet is not open; nothing was measured"

      refute html =~ "follow-up code change"
      refute html =~ "scope-rail-notice"
      refute html =~ "create-org-followup-note"
      refute html =~ "renders unstyled until that lands"
    end

    test "a hue within 20 degrees of an existing org warns and still submits", %{conn: conn} do
      admin = admin_user!()
      # fabrikam ships at hue 50; 62 is 12 degrees away, inside the window.
      assert Tenancy.get_org_by_slug!("fabrikam").color_hue == 50

      view = open_sheet(conn, admin)

      view
      |> form(~s(#create-org-form),
        org: %{name: "Aurora Labs", slug: "aurora_labs", color_hue: "62"}
      )
      |> render_change()

      warned = warning_html(view)
      assert warned =~ "Fabrikam"
      assert warned =~ "12"
      refute warned =~ "Soylent"

      # WARNS, never blocks: the same form still creates the org.
      view
      |> form(~s(#create-org-form),
        org: %{name: "Aurora Labs", slug: "aurora_labs", color_hue: "62"}
      )
      |> render_submit()

      assert Repo.get_by!(Org, slug: "aurora_labs").color_hue == 62
    end

    test "picking a colour first does not scold about fields not yet reached", %{conn: conn} do
      # The ring is above the fold and a colour is a legal first move. This
      # asserts the errors are ABSENT after a hue-only change and PRESENT
      # once a text field is touched and left blank — without the second
      # half it would pass for a form that never validates at all.
      #
      # Matched on the error elements' `data-role`, NOT on the message text:
      # HEEx escapes the apostrophe, so the rendered string is
      # `can&#39;t be blank` and a `=~ "can\'t be blank"` can never match.
      # Both halves would then be vacuous — the refute trivially, the assert
      # loudly. That cost a red run to find.
      view = open_sheet(conn, admin_user!())

      hue_only =
        view
        |> element(~s([data-role="hue-stop"][data-hue="160"]))
        |> render_click()

      assert hue_only =~ ~s(data-role="org-color-preview"), "the pick did not register"
      refute hue_only =~ ~s(data-role="org-name-error")
      refute hue_only =~ ~s(data-role="org-slug-error")

      typed =
        view
        |> form(~s(#create-org-form), org: %{name: "Aurora Labs", slug: ""})
        |> render_change()

      assert typed =~ ~s(data-role="org-slug-error")
      assert typed =~ "can&#39;t be blank"
    end

    test "the chroma STORED is the chroma previewed, and it is not the column default",
         %{conn: conn} do
      # Task 01a09287 stage 5. This module's own contract, two hundred lines
      # into it, is that "the numbers an operator reads off this panel are
      # the numbers the server will store and the rail will paint". It was
      # false by 0.01 for every org ever created through this form:
      # `form_attrs/1` took only name/slug/color_hue, so `color_chroma` was
      # never written and the column's `default: 0.16` decided. The panel
      # previewed 0.15, the row held 0.16, the emitted CSS said 0.16.
      #
      # Asserted as an IDENTITY against `ScopeColor.default_chroma/0` rather
      # than against a literal, because a literal here would be a fifth place
      # naming the number and could drift from the other four in exactly the
      # way this test exists to catch.
      view = open_sheet(conn, admin_user!())

      view
      |> form(~s(#create-org-form),
        org: %{name: "Aurora Labs", slug: "aurora_labs", color_hue: "200"}
      )
      |> render_submit()

      org = Repo.get_by!(Org, slug: "aurora_labs")

      assert org.color_hue == 200
      assert org.color_chroma == ScopeColor.default_chroma()

      # The number the panel PREVIEWED, recovered from the fill it printed
      # rather than from the constant — otherwise both sides of the identity
      # would come from the same place and the test could not fail.
      assert PlatformWeb.AdminOrgsLive.org_fill(org) ==
               ScopeColor.derive(200, ScopeColor.default_chroma()).fill

      # And the defaults that used to disagree now agree, from one source.
      refute org.color_chroma == 0.16
      assert Tenancy.scope_slug_entries(nil) == []
    end

    test "a list swatch uses the org's stored fill lightness, else the 72% default" do
      # Task 01a09333-d374 stage 5: the six shipped orgs carry the fill
      # lightness they shipped at (paragon 80%), because the runtime path
      # now paints them from their rows. The list swatch has to agree with
      # the rail, so it reads the same column.
      assert PlatformWeb.AdminOrgsLive.org_fill(%Org{
               color_hue: 95,
               color_chroma: 0.16,
               color_lightness: 0.80
             }) == "oklch(80% 0.16 95)"

      assert PlatformWeb.AdminOrgsLive.org_fill(%Org{color_hue: 95, color_chroma: 0.16}) ==
               "oklch(72% 0.16 95)"
    end

    test "an org created with NO hue stores no chroma either", %{conn: conn} do
      # The other half. A chroma without a hue is a stored value that means
      # nothing — nothing reads it, and `scope_slug_entries/1` would hand a
      # chroma to an emitter that drops the row for want of a hue. Without
      # this the test above passes for a `form_attrs/1` that writes the
      # chroma unconditionally.
      view = open_sheet(conn, admin_user!())

      view
      |> form(~s(#create-org-form), org: %{name: "Greyscale", slug: "greyscale"})
      |> render_submit()

      org = Repo.get_by!(Org, slug: "greyscale")

      assert is_nil(org.color_hue)

      assert is_nil(org.color_chroma),
             "a column default is back, or form_attrs writes a chroma with no hue"
    end

    test "a hue far from every taken hue does NOT warn", %{conn: conn} do
      # The negative half. Without it the test above passes for a template
      # that renders the warning unconditionally.
      view = open_sheet(conn, admin_user!())

      html =
        view
        |> form(~s(#create-org-form),
          org: %{name: "Aurora Labs", slug: "aurora_labs", color_hue: "200"}
        )
        |> render_change()

      assert html =~ ~s(data-role="org-color-preview"), "the preview did not render"
      refute html =~ ~s(data-role="hue-proximity-warning")
    end

    test "proximity is measured on the CIRCLE, across the wrap point", %{conn: conn} do
      # An org at 350: hue 5 is 15 degrees away round the circle and 345 the
      # linear way, so a subtraction would not warn here. Created rather
      # than assumed — the seeded set has no org near the wrap point, which
      # is exactly why a linear bug would survive the tests above.
      admin = admin_user!()

      {:ok, _} =
        Tenancy.create_org(admin, %{name: "Vermilion", slug: "vermilion", color_hue: 350})

      # soylent sits at 295 and must NOT be picked up at this distance.
      assert Tenancy.get_org_by_slug!("soylent").color_hue == 295

      view = open_sheet(conn, admin_user!())

      html =
        view
        |> form(~s(#create-org-form),
          org: %{name: "Aurora Labs", slug: "aurora_labs", color_hue: "5"}
        )
        |> render_change()

      assert html =~ ~s(data-role="hue-proximity-warning")

      warned = warning_html(view)
      assert warned =~ "Vermilion"
      assert warned =~ "15"
      refute warned =~ "Soylent"
    end

    test "the preview prints the WORST cell, names it, and computes it server-side",
         %{conn: conn} do
      view = open_sheet(conn, admin_user!())

      html =
        view
        |> form(~s(#create-org-form),
          org: %{name: "Aurora Labs", slug: "aurora_labs", color_hue: "162"}
        )
        |> render_change()

      ramp = ScopeColor.derive(162, 0.15)
      worst = ramp.worst_light

      # Both theme grounds, not one: no single value clears AA on both.
      assert html =~ ~s(data-ground="light")
      assert html =~ ~s(data-ground="dark")

      # The figure shown is the solver's own worst cell, read off the ramp.
      # The panel used to recompute it from a private cell table, and the
      # gap between the two tables is why it printed 3.74 where the clause
      # wanted 4.50. Since task 01a09333-d374 each surface has its own tint
      # and label, so the discriminating comparison is the OTHER surface's
      # cell: it reads more generously, and its figure is not on the page.
      # Without that, a panel printing the best cell and calling it the
      # worst would pass.
      assert html =~ "#{PlatformWeb.AdminOrgsLive.format_contrast(worst.contrast)}:1"
      assert worst.contrast == ramp.contrast_light

      [better] = Enum.reject(ramp.cells.light, &(&1.surface == worst.surface))
      assert better.contrast > worst.contrast
      refute html =~ "#{PlatformWeb.AdminOrgsLive.format_contrast(better.contrast)}:1"

      # And the printed figure clears the bar with margin, which is the whole
      # point: a panel that prints an honest worst-case number is only
      # useful if that number passes.
      assert worst.contrast >= 4.5
      assert ramp.floor_light >= 4.5

      # A bare number is not interpretable: the cell is named beside it.
      assert html =~ worst.cell

      # Every chip is painted with the bytes it was measured on: its OPAQUE
      # tint and its own label, one per surface per theme. No alpha tint is
      # left in the preview to composite in the browser.
      [preview] =
        Regex.run(~r/data-role="org-color-preview".*data-role="org-color-derived"/s, html)

      refute preview =~ "color-mix"

      for theme <- [:light, :dark], cell <- ramp.cells[theme] do
        assert preview =~ "background-color:#{cell.tint}",
               "#{theme} #{cell.cell}: tint not painted"

        assert preview =~ "color:#{cell.label}", "#{theme} #{cell.cell}: label not painted"
      end

      assert count_matches(html, ~s(data-role="preview-surface")) == 4

      # The machine values come from the server, not from JS.
      assert html =~ ramp.fill

      for field <-
            [:tint_light_100, :tint_light_200, :tint_dark_100, :tint_dark_200] ++
              [:label_light_100, :label_light_200, :label_dark_100, :label_dark_200] do
        assert html =~ Map.fetch!(ramp, field), "#{field} is not printed"
      end
    end

    test "no hue on the ring renders the below-AA branch, in either theme", %{conn: conn} do
      # The panel carries two mutually exclusive branches per theme:
      # `preview-aa-clears` and `preview-aa-fail`. Until this stage the fail
      # branch fired for EVERY hue in light, and the copy beside it told the
      # operator that was a known limitation of the ramp rather than a
      # defect — which is how a panel teaches someone to accept a failing
      # figure as normal.
      #
      # Sampled across the circle rather than at one hue, because the old
      # failure was flat: a single hue would pass for a panel that fails
      # everywhere else.
      view = open_sheet(conn, admin_user!())

      for hue <- [0, 45, 95, 160, 200, 240, 300, 330, 350] do
        html =
          view
          |> element(~s([data-role="hue-stop"][data-hue="#{hue}"]))
          |> render_click()

        # POSITIVE CONTROL: the pick registered and the panel rendered. A
        # `refute` against a panel that never appeared is vacuous.
        assert html =~ ~s(data-role="org-color-preview"), "hue #{hue}: no preview"

        assert html =~ ~s(data-role="preview-contrast" data-ground="light"),
               "hue #{hue}: no light figure"

        assert html =~ ~s(data-role="preview-contrast" data-ground="dark"),
               "hue #{hue}: no dark figure"

        refute html =~ ~s(data-role="preview-aa-fail"), "hue #{hue} renders below-AA"
      end
    end

    test "the ring's stops are not all the same hue — the sweep above is real", %{conn: conn} do
      # Guards the loop above against a ring whose stops all carry the same
      # `data-hue`, or a `render_click` that silently no-ops: nine identical
      # results would satisfy it just as well as nine different ones.
      view = open_sheet(conn, admin_user!())

      figures =
        for hue <- [0, 95, 200, 300] do
          html =
            view
            |> element(~s([data-role="hue-stop"][data-hue="#{hue}"]))
            |> render_click()

          # Scoped to the DERIVED block, not the whole document: the ring
          # paints 72 stops of its own as `oklch(72% <c> <h>)`, so an
          # unscoped match reads a stop rather than the preview and returns
          # the same hue every time whatever was clicked. That is exactly
          # the false pass this test exists to prevent, and it found it on
          # the first run.
          [derived] = Regex.run(~r/data-role="org-color-derived".*?<\/div>/s, html)

          [_, fill] = Regex.run(~r/oklch\(72% [0-9.]+ (\d+)\)/, derived)
          fill
        end

      assert figures == ["0", "95", "200", "300"],
             "the ring stops did not move the previewed hue: #{inspect(figures)}"
    end

    test "the ring has 72 stops and a notch for every org that has a hue", %{conn: conn} do
      view = open_sheet(conn, admin_user!())
      html = render(view)

      assert count_matches(html, ~s(data-role="hue-stop")) == 72

      with_hue =
        Tenancy.list_orgs_in_priority_order()
        |> Enum.count(&is_integer(&1.color_hue))

      assert with_hue > 0, "no seeded org has a hue; the notch assertion would be vacuous"
      assert count_matches(html, ~s(data-role="hue-notch")) == with_hue

      # Read from the DB, not a hardcoded table: a hue nobody shipped in CSS
      # still gets a notch.
      {:ok, _} =
        Tenancy.create_org(admin_user!(), %{name: "Aurora", slug: "aurora", color_hue: 7})

      view = open_sheet(conn, admin_user!())
      assert count_matches(render(view), ~s(data-role="hue-notch")) == with_hue + 1
    end

    # Scoped to the warning block, NOT the whole document: every org's name
    # appears in the list row and in a ring notch title, so `html =~ "Fabrikam"`
    # would pass whether or not the warning named it — and the negative
    # assertions would fail for the same irrelevant reason.
    defp warning_html(view) do
      case view |> element(~s([data-role="hue-proximity-warning"])) |> render() do
        html when is_binary(html) -> html
      end
    end

    defp count_matches(html, needle) do
      html |> String.split(needle) |> length() |> Kernel.-(1)
    end
  end

  describe "create" do
    test "a valid name and slug creates a tenant org parented to Fabrikam, and it lists", %{
      conn: conn
    } do
      admin = admin_user!()
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")

      {:ok, view, _html} = conn |> authenticated_conn(admin) |> live(~p"/admin/orgs")
      view |> element(~s([data-role="open-create-org"])) |> render_click()

      html =
        view
        |> form(~s(#create-org-form), org: %{name: "Aurora Labs", slug: "aurora_labs"})
        |> render_submit()

      created = Repo.get_by!(Org, slug: "aurora_labs")
      assert created.name == "Aurora Labs"
      # Parentage is derived by `create_org/2`, not posted by the form.
      assert created.parent_org_id == fabrikam.id

      assert html =~ ~s(data-org-slug="aurora_labs")
      assert html =~ "Aurora Labs"
    end

    test "a duplicate slug renders an inline :slug error, no crash, no second row", %{conn: conn} do
      admin = admin_user!()

      assert {:ok, _first} =
               Tenancy.create_org(admin, %{name: "Aurora Labs", slug: "aurora_labs"})

      assert count_orgs_with_slug("aurora_labs") == 1

      {:ok, view, _html} = conn |> authenticated_conn(admin) |> live(~p"/admin/orgs")
      view |> element(~s([data-role="open-create-org"])) |> render_click()

      html =
        view
        |> form(~s(#create-org-form), org: %{name: "Aurora Labs Two", slug: "aurora_labs"})
        |> render_submit()

      # The LiveView is still alive — an Ecto.ConstraintError reaching the
      # browser would have killed it before this line.
      assert render(view) =~ ~s(id="create-org-sheet")

      slug_error = view |> element(~s([data-role="org-slug-error"])) |> render()
      assert slug_error =~ "has already been taken"

      # The error is on :slug specifically, not smeared across the form.
      refute html =~ ~s(data-role="org-name-error")

      assert count_orgs_with_slug("aurora_labs") == 1
    end

    test "an invalid slug format renders the format error", %{conn: conn} do
      admin = admin_user!()

      {:ok, view, _html} = conn |> authenticated_conn(admin) |> live(~p"/admin/orgs")
      view |> element(~s([data-role="open-create-org"])) |> render_click()

      view
      |> form(~s(#create-org-form), org: %{name: "Aurora Labs", slug: "Not A Slug"})
      |> render_submit()

      slug_error = view |> element(~s([data-role="org-slug-error"])) |> render()
      assert slug_error =~ "must start with a lowercase letter"

      assert count_orgs_with_slug("Not A Slug") == 0
    end
  end
end
