defmodule PlatformWeb.InstallIdentityRenderedPagesTest do
  @moduledoc """
  The install-identity guard's check, run over RENDERED pages (task 01a14b9e
  stage 6).

  `Platform.Regression.InstallIdentityGuardTest` scans the tracked tree. This
  test scans what a root admin is served on `/chat`, `/tasks` and
  `/admin/branding`: the full dead-render document (root layout, head and
  icon links included) and the connected LiveView render. It uses plain
  `InstallIdentityScanner.hits/1`, with no page-only exemption, so class
  names and attribute values count like any other text.

  Each page also gets a POSITIVE CONTROL: the same function, run over the
  same page HTML with one term planted (the operator org token, derived from
  the shipped bundle id so this file does not spell it), finds exactly the
  planted hit. A zero is only evidence if the check could have said
  otherwise on that very input.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Regression.InstallIdentityScanner, as: Scanner
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  @pages ["/chat", "/tasks", "/admin/branding"]

  defp root_admin_conn(conn) do
    n = System.unique_integer([:positive])

    user =
      %User{}
      |> User.changeset(%{
        email: "rendered-pages-#{n}@example.com",
        name: "Rendered Pages #{n}",
        oidc_sub: "oidc-rendered-pages-#{n}"
      })
      |> Repo.insert!()

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Tenancy.get_org_by_slug!(Tenancy.root_org_slug()).id,
      role: "admin"
    })
    |> Repo.insert!()

    Plug.Test.init_test_session(conn, %{"current_user_id" => user.id})
  end

  # The planted term goes in the middle of the page, inside a class
  # attribute, the place stage 6's finding was.
  defp plant(html, term) do
    at = div(byte_size(html), 2)
    planted = ~s(<span class="hero-#{term} size-4"></span>)

    {binary_part(html, 0, at) <> planted <> binary_part(html, at, byte_size(html) - at),
     at + byte_size(~s(<span class="hero-))}
  end

  for path <- @pages do
    test "#{path}: hits/1 is empty on the dead render and the live render, and fires on a plant",
         %{conn: conn} do
      conn = root_admin_conn(conn)

      document = conn |> get(unquote(path)) |> html_response(200)
      {:ok, _view, live_html} = live(conn, unquote(path))

      for {label, html} <- [document: document, live: live_html] do
        # not vacuous: a real shell page, with the theme picker in it
        # (task 01a1557a stage 4 replaced the theme toggle)
        assert html =~ ~s(id="theme-picker-trigger"), "#{label} render has no shell"
        assert html =~ ~s(data-theme-chip), "#{label} render has no theme picker chips"

        assert Scanner.hits(html) == [],
               "#{unquote(path)} #{label} render carries install identity at " <>
                 inspect(Scanner.hits(html))

        # POSITIVE CONTROL on the same HTML
        org = Scanner.published_org_token()
        {planted, offset} = plant(html, org)
        assert Scanner.hits(planted) == [{offset, byte_size(org)}]
      end

      # the document is the whole page: head, manifest link and icon links
      assert document =~ ~s(rel="manifest")
      assert document =~ ~s(href="/images/favicon-32.png")
    end
  end
end
