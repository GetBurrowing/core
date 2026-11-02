defmodule PlatformWeb.ChatLiveScopeRowsTest do
  @moduledoc """
  Every chat scope colour is driven by `orgs` rows (task 01a14dd9 stage 2).

  The compiled five-org palette is gone. Scope pills carry `data-scope` = an
  org slug and slug-agnostic classes that read `--scope-fill`, which
  `ScopeColorStyles` emits from the row.

  Burrow redesign 22 stage 2 deleted the desktop channel rail, and with it the
  section dots, the admin recolor palette and the archived-token section rule.
  The cases that read those are deleted. What remains:

    (a) colour identity: a pill names the org's `data-scope`, reads
        `--scope-fill`, and the page emits the row's derived fill for it;
    (c) the palette is the org rows, not a compiled list.

  Placeholder orgs only (`newco`): it is not seeded, so no test here depends
  on which tenants an install ships with.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Chat.Sidebar
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.Org
  alias Platform.Tenancy.OrgMembership
  alias Platform.Tenancy.ScopeColor

  @newco %{hue: 25, chroma: 0.15, lightness: 0.7}

  defp admin! do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "scope-rows-#{n}@example.com",
        name: "Scope Rows #{n}",
        oidc_sub: "oidc-scope-rows-#{n}",
        preferences: %{"first_run_goal" => "existing"}
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

  defp live_chat(conn, user) do
    conn = init_test_session(conn, current_user_id: user.id)

    case live(conn, ~p"/chat") do
      {:error, {:live_redirect, %{to: path}}} -> live(conn, path)
      ok -> ok
    end
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

  describe "(a) colour identity: the pill wears the row's fill" do
    test "a coloured org's scope pill and the page's emitted rule", %{conn: conn} do
      admin = admin!()
      newco = coloured_org!(admin, "newco", "Newco", @newco)

      {:ok, _view, html} = live_chat(conn, admin)

      # The pill: the bare component, as every chat call site renders it.
      pill =
        render_component(&PlatformWeb.Components.ScopePill.scope_pill/1,
          scope: newco.slug,
          value: newco.slug,
          label: newco.name
        )

      assert pill =~ ~s(data-scope="newco")
      assert pill =~ "scope-dot"

      # The page emits exactly the row's derived fill for the pill to read.
      assert emitted_fill(html, "newco") == derived_fill(@newco)

      css = File.read!("assets/css/app.css")

      assert css =~ ~r/\.scope-dot\s*\{\s*background-color:\s*var\(--scope-fill\)/,
             "app.css lost the .scope-dot rule"
    end
  end

  describe "(c) the scope palette" do
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
end
