defmodule PlatformWeb.AdminBreadcrumbTest do
  @moduledoc """
  Coverage for the shared breadcrumb escape hatch on the Admin subpages
  (task 019f62c8 stage 2).

  Each admin subpage renders a `<.breadcrumb>` whose root ("Admin")
  segment is a `<.link navigate>` pointing UP to the module root `/admin`,
  so a user stuck on a subpage always has a self-serve way back to root.
  The prompts EDIT view additionally chains an intermediate "Prompts"
  segment linking to `/admin/prompts`.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  defp acme_admin_conn(conn) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "breadcrumb-#{n}@example.com",
        name: "Breadcrumb Admin #{n}",
        oidc_sub: "oidc-breadcrumb-#{n}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Tenancy.get_org_by_slug!("acme").id,
      role: "admin"
    })
    |> Repo.insert!()

    Plug.Test.init_test_session(conn, %{"current_user_id" => user.id})
  end

  # The breadcrumb root ("up to module root") link — a `<.link navigate>`
  # renders as `<a href="/admin">` inside the breadcrumb nav.
  defp breadcrumb_root_selector,
    do: ~s(nav[data-role="breadcrumb"] a[data-role="breadcrumb-link"][href="/admin"])

  describe "Admin subpages render a breadcrumb whose root link targets /admin" do
    for {path, page_label} <- [
          {"/admin/users", "User Access"},
          {"/admin/recovery", "Recovery"},
          {"/admin/federation", "Federation"},
          {"/admin/prompts", "Prompts"}
        ] do
      test "#{path} breadcrumb up-targets /admin", %{conn: conn} do
        {:ok, view, _html} =
          conn |> acme_admin_conn() |> live(unquote(path))

        # The breadcrumb is present and its root segment navigates UP to /admin.
        assert has_element?(view, breadcrumb_root_selector()),
               "expected a breadcrumb root link to /admin on #{unquote(path)}"

        # The current (inert) segment names this subpage and is NOT a link.
        assert has_element?(
                 view,
                 ~s([data-role="breadcrumb-current"]),
                 unquote(page_label)
               )
      end
    end
  end

  describe "prompts edit view chains /admin/prompts -> /admin" do
    test "breadcrumb links both the module root and the prompts index", %{conn: conn} do
      {:ok, template} =
        PromptTemplates.create_template(%{
          slug: "breadcrumb-test-tmpl-#{System.unique_integer([:positive])}",
          name: "Breadcrumb Test Template",
          content: "hello {{name}}"
        })

      {:ok, view, _html} =
        conn |> acme_admin_conn() |> live(~p"/admin/prompts/#{template.slug}")

      # Root segment still links up to /admin.
      assert has_element?(view, breadcrumb_root_selector())

      # Intermediate segment links to the prompts index (/admin/prompts).
      assert has_element?(
               view,
               ~s(nav[data-role="breadcrumb"] a[data-role="breadcrumb-link"][href="/admin/prompts"])
             )

      # The template slug is the inert current segment.
      assert has_element?(view, ~s([data-role="breadcrumb-current"]), template.slug)
    end
  end
end
