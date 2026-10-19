defmodule PlatformWeb.ChatLiveScopeRowsTest do
  @moduledoc """
  Every chat scope colour is driven by `orgs` rows (task 01a14dd9 stage 2).

  The compiled five-org palette (`@sibling_scope_tokens`,
  `section_dot_class/1`, `section_scope_atom/1`, `parse_scope/1`'s clauses,
  the per-slug `bg-<slug>-dot` / `channel-section-swatch--<slug>` /
  `text-<slug>` rules in app.css) is gone. Section dots, recolor swatches and
  scope pills carry `data-scope` = an org slug and slug-agnostic classes that
  read `--scope-fill`, which `ScopeColorStyles` emits from the row.

  The four behaviours this file pins:

    (a) colour identity: the dot, the swatch and the pill of an org all name
        the SAME `data-scope`, all read `--scope-fill`, and the emitted
        `--scope-fill` for it is `ScopeColor.derive(hue, chroma, lightness).fill`;
    (b) a section of an active org wearing an ARCHIVED org's token still gets
        that org's colour rule;
    (c) a runtime-created org with a colour is in the recolor palette, can be
        chosen, and renders; a token naming no org is refused;
    (d) no rendered class name embeds an org slug.

  Placeholder orgs only (`newco`, `oldco`): none of them is seeded, so no test
  here depends on which tenants an install ships with.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Chat.Section
  alias Platform.Chat.Sidebar
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.Org
  alias Platform.Tenancy.OrgMembership
  alias Platform.Tenancy.ScopeColor

  @newco %{hue: 25, chroma: 0.15, lightness: 0.7}
  @oldco %{hue: 300, chroma: 0.12, lightness: 0.66}

  defp admin! do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "scope-rows-#{n}@example.com",
        name: "Scope Rows #{n}",
        oidc_sub: "oidc-scope-rows-#{n}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Tenancy.get_root_org().id,
      role: "admin"
    })
    |> Repo.insert!()

    user
  end

  # Through the real create path, so the org gets the default section
  # `Sidebar.ensure_default_section/1` writes (colour = its own token).
  defp coloured_org!(admin, slug, name, colour) do
    {:ok, org} = Tenancy.create_org(admin, %{name: name, slug: slug})

    org
    |> Org.changeset(%{
      color_hue: colour.hue,
      color_chroma: colour.chroma,
      color_lightness: colour.lightness
    })
    |> Repo.update!()
  end

  defp section_for!(org), do: Repo.get_by!(Section, org_id: org.id)

  defp live_chat(conn, user) do
    conn = init_test_session(conn, current_user_id: user.id)

    case live(conn, ~p"/chat") do
      {:error, {:live_redirect, %{to: path}}} -> live(conn, path)
      ok -> ok
    end
  end

  defp enter_admin_edit(view) do
    view |> element(~s(button[phx-click="toggle_sidebar_menu"])) |> render_click()

    view
    |> element(~s(button[role="menuitem"][phx-click="toggle_sidebar_admin_edit"]))
    |> render_click()
  end

  defp query(html, selector) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)
  end

  defp attr(node, name), do: node |> LazyHTML.attribute(name) |> List.first()

  defp section_dot(html, section_id) do
    query(html, ~s(section[id="section-#{section_id}"] .channel-section-color-dot))
  end

  # The `--scope-fill` value the page's emitted rules give `slug`, or nil.
  defp emitted_fill(html, slug) do
    case Regex.run(~r/\[data-scope="#{slug}"\]\{--scope-fill:([^;]+);/, html) do
      [_, fill] -> fill
      _ -> nil
    end
  end

  defp derived_fill(colour),
    do: ScopeColor.derive(colour.hue, colour.chroma, colour.lightness).fill

  describe "(a) colour identity: dot, swatch and pill all wear the row's fill" do
    test "a coloured org's section dot, recolor swatch and scope pill", %{conn: conn} do
      admin = admin!()
      newco = coloured_org!(admin, "newco", "Newco", @newco)
      section = section_for!(newco)
      assert section.color == "newco"

      {:ok, view, _html} = live_chat(conn, admin)
      html = enter_admin_edit(view)

      # The dot: slug-agnostic class, the org's slug as data-scope.
      dot = section_dot(html, section.id)
      assert Enum.count(dot) == 1
      assert attr(dot, "data-scope") == "newco"
      assert attr(dot, "class") =~ "channel-section-color-dot--scope"

      # The swatch for newco in its OWN section's palette.
      swatch =
        query(
          html,
          ~s(section[id="section-#{section.id}"] button.channel-section-swatch[phx-value-color="newco"])
        )

      assert Enum.count(swatch) == 1
      assert attr(swatch, "data-scope") == "newco"

      # The pill: the bare component, as every chat call site renders it.
      pill =
        render_component(&PlatformWeb.Components.ScopePill.scope_pill/1,
          scope: newco.slug,
          value: newco.slug,
          label: newco.name
        )

      assert pill =~ ~s(data-scope="newco")
      assert pill =~ "scope-dot"

      # All three read one custom property, and the page emits exactly the
      # row's derived fill for it.
      assert emitted_fill(html, "newco") == derived_fill(@newco)

      css = File.read!("assets/css/app.css")

      for rule <- [
            ~r/\.channel-section-color-dot--scope\s*\{[^}]*background-color:\s*var\(--scope-fill,/,
            ~r/\.channel-section-swatch\s*\{[^}]*background-color:\s*var\(--scope-fill,/,
            ~r/\.scope-dot\s*\{\s*background-color:\s*var\(--scope-fill\)/
          ] do
        assert css =~ rule, "app.css lost #{inspect(rule)}"
      end
    end
  end

  describe "(b) a section wearing an ARCHIVED org's token" do
    test "keeps that org's colour: the rail emits the archived org's rule", %{conn: conn} do
      admin = admin!()
      oldco = coloured_org!(admin, "oldco", "Oldco", @oldco)

      {1, _} =
        Repo.update_all(from(o in Org, where: o.id == ^oldco.id),
          set: [archived_at: DateTime.utc_now()]
        )

      # An ACTIVE org's section (the root's) recoloured to the archived
      # org's token, the shape measured on the largest install.
      root_section = section_for!(Tenancy.get_root_org())

      {1, _} =
        Repo.update_all(from(s in Section, where: s.id == ^root_section.id),
          set: [color: "oldco"]
        )

      # The shell's list is active orgs only, so it cannot be what colours this.
      refute Enum.any?(Tenancy.scope_color_entries(admin), &(&1.slug == "oldco"))

      {:ok, _view, html} = live_chat(conn, admin)

      dot = section_dot(html, root_section.id)
      assert attr(dot, "data-scope") == "oldco"
      assert attr(dot, "class") =~ "channel-section-color-dot--scope"
      assert emitted_fill(html, "oldco") == derived_fill(@oldco)
    end
  end

  describe "(c) a runtime-created org in the recolor palette" do
    test "appears as a swatch, can be chosen, and renders", %{conn: conn} do
      admin = admin!()
      newco = coloured_org!(admin, "newco", "Newco", @newco)
      root_section = section_for!(Tenancy.get_root_org())

      {:ok, view, _html} = live_chat(conn, admin)
      html = enter_admin_edit(view)

      swatch =
        query(
          html,
          ~s(section[id="section-#{root_section.id}"] button.channel-section-swatch[phx-value-color="newco"])
        )

      assert Enum.count(swatch) == 1, "the runtime org has no swatch in another section's palette"
      assert attr(swatch, "data-scope") == newco.slug

      html =
        render_hook(view, "recolor_section_default", %{
          "section_id" => root_section.id,
          "color" => "newco"
        })

      assert Repo.get!(Section, root_section.id).color == "newco"
      assert attr(section_dot(html, root_section.id), "data-scope") == "newco"
      assert emitted_fill(html, "newco") == derived_fill(@newco)
    end

    test "a token naming no org is refused, and an archived org's token too", %{conn: conn} do
      admin = admin!()
      oldco = coloured_org!(admin, "oldco", "Oldco", @oldco)

      {1, _} =
        Repo.update_all(from(o in Org, where: o.id == ^oldco.id),
          set: [archived_at: DateTime.utc_now()]
        )

      root_section = section_for!(Tenancy.get_root_org())
      before = Repo.get!(Section, root_section.id).color

      {:ok, view, _html} = live_chat(conn, admin)
      _ = enter_admin_edit(view)

      for forged <- ["nonesuch", "oldco", "", "newco\"}"] do
        render_hook(view, "recolor_section_default", %{
          "section_id" => root_section.id,
          "color" => forged
        })

        assert Repo.get!(Section, root_section.id).color == before, "accepted #{inspect(forged)}"
      end
    end

    test "the palette is the org rows, not a compiled list" do
      admin = admin!()
      _ = coloured_org!(admin, "newco", "Newco", @newco)
      tokens = Enum.map(Tenancy.scope_palette(), & &1.token)

      assert "newco" in tokens

      # Every colour-bearing, non-archived org is in it, and nothing else.
      expected =
        from(o in Org, where: is_nil(o.archived_at) and not is_nil(o.color_hue), select: o.slug)
        |> Repo.all()
        |> Enum.map(&Tenancy.css_slug/1)
        |> Enum.sort()

      assert Enum.sort(tokens) == expected
      assert Sidebar.list_default_sections() != []
    end
  end

  describe "(d) no rendered class name embeds an org slug" do
    test "dots, swatches and pills for placeholder orgs carry no per-slug class", %{conn: conn} do
      admin = admin!()
      _ = coloured_org!(admin, "newco", "Newco", @newco)
      oldco = coloured_org!(admin, "oldco", "Oldco", @oldco)

      {1, _} =
        Repo.update_all(from(o in Org, where: o.id == ^oldco.id),
          set: [archived_at: DateTime.utc_now()]
        )

      root_section = section_for!(Tenancy.get_root_org())

      {1, _} =
        Repo.update_all(from(s in Section, where: s.id == ^root_section.id),
          set: [color: "oldco"]
        )

      {:ok, view, _html} = live_chat(conn, admin)
      html = enter_admin_edit(view)

      # The page does render both orgs, so the absence below is not vacuous.
      assert html =~ ~s(data-scope="newco")
      assert html =~ ~s(data-scope="oldco")

      classes =
        html
        |> query("[class]")
        |> Enum.flat_map(&(&1 |> LazyHTML.attribute("class") |> hd() |> String.split()))

      for slug <- ["newco", "oldco"],
          class <- ["text-#{slug}", "bg-#{slug}-dot", "channel-section-swatch--#{slug}"] do
        refute class in classes, "rendered class #{class}"
      end

      assert Enum.filter(classes, &String.contains?(&1, ["newco", "oldco"])) == []
    end
  end
end
