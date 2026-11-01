defmodule PlatformWeb.AdminLiveTest do
  @moduledoc """
  The `/admin` index after its re-skin onto the masters' panel anatomy
  (Burrow redesign 24, task 01a1557a-fe9b stage 4). The re-skin is a token
  swap: every entry keeps its href and its gate, and the Themes card is new.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Access.Scope
  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  # {data-admin-card, href} for every card visible to a root admin with the
  # sign-in switch off, in page order. "Connect your AI" (task 01a10315 stage
  # 5) leads while no Burrow agent is connected, which is the case here; its
  # own gate is pinned in connect_ai_live_test.exs.
  @always [
    {"connect-ai", "/setup/connect-ai"},
    {"access", "/access"},
    {"agents", "/control"},
    {"federation", "/admin/federation"},
    {"usage", "/control/usage"},
    {"users", "/admin/users"},
    {"orgs", "/admin/orgs"},
    {"vault", "/admin/vault"},
    {"branding", "/admin/branding"},
    {"themes", "/admin/themes"},
    {"prototypes", "/admin/prototypes"},
    {"insights", "/admin/insights"},
    {"external-logins", "/admin/external-logins"},
    {"recovery", "/admin/recovery"}
  ]

  defp user!(role) do
    n = System.unique_integer([:positive])

    user =
      %User{}
      |> User.changeset(%{
        email: "admin-index-#{n}@example.com",
        name: "Admin Index #{n}",
        oidc_sub: "oidc-admin-index-#{n}"
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

  defp authed(user), do: build_conn() |> init_test_session(current_user_id: user.id)

  defp cards(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("[data-role=admin-card-list] a[data-admin-card]")
    |> Enum.map(fn node ->
      {node |> LazyHTML.attribute("data-admin-card") |> hd(),
       node |> LazyHTML.attribute("href") |> hd()}
    end)
  end

  # The template rendered directly with a given scope: the only way to show
  # the Access card's own gate, because `/admin` mounts only for an actor who
  # already holds module access to :admin.
  defp render_index(scope, sign_in?) do
    PlatformWeb.AdminLive.render(%{
      __changed__: nil,
      access_scope: scope,
      sign_in_admin?: sign_in?,
      connect_ai?: false
    })
    |> rendered_to_string()
  end

  test "every entry is present with its href, in order, under the heading 'Admin'" do
    refute Platform.SignInAdmin.Config.enabled?()
    {:ok, view, html} = live(authed(user!("admin")), "/admin")

    assert cards(html) == @always
    assert has_element?(view, "h1[data-role=admin-heading]", "Admin")
    refute html =~ "Admin · Operations"

    # Each card is the panel anatomy: an h3, a subtle p and an always-visible
    # ghost "Open".
    doc = LazyHTML.from_document(html)

    for {slug, _href} <- @always do
      card = "a[data-admin-card=\"#{slug}\"]"
      assert doc |> LazyHTML.query("#{card} > h3") |> Enum.count() == 1, slug
      assert doc |> LazyHTML.query("#{card} > p.text-subtle") |> Enum.count() == 1, slug

      [open] = doc |> LazyHTML.query("#{card} [data-role=admin-card-open]") |> Enum.to_list()
      assert open |> LazyHTML.text() |> String.trim() == "Open"
      [class] = LazyHTML.attribute(open, "class")
      refute class =~ "opacity"
    end
  end

  test "the Themes card links to /admin/themes, desktop only, with its description" do
    {:ok, view, _html} = live(authed(user!("admin")), "/admin")

    assert has_element?(
             view,
             ~s(a[data-admin-card="themes"][href="/admin/themes"].max-lg\\:hidden),
             "Edit colour tokens, shape, density, font and glass, then make a theme available in Appearance."
           )
  end

  test "the Access card is gated on module access to :admin" do
    admin_scope = Scope.for_user(Accounts.get_user(user!("admin").id))
    member_scope = Scope.for_user(Accounts.get_user(user!("member").id))

    assert Platform.Access.module_access?(admin_scope, :admin)
    refute Platform.Access.module_access?(member_scope, :admin)

    with_access = render_index(admin_scope, false) |> cards()
    without = render_index(member_scope, false) |> cards()

    assert {"access", "/access"} in with_access
    refute Enum.any?(without, fn {slug, _} -> slug == "access" end)
    # Only the Access card is scope-gated.
    assert without == List.delete(with_access, {"access", "/access"})
  end

  test "the sign-in users card follows the sign-in switch" do
    scope = Scope.for_user(Accounts.get_user(user!("admin").id))

    off = render_index(scope, false) |> cards()
    on = render_index(scope, true) |> cards()

    refute Enum.any?(off, fn {slug, _} -> slug == "sign-in-users" end)
    assert {"sign-in-users", "/admin/sign-in-users"} in on
    assert List.delete(on, {"sign-in-users", "/admin/sign-in-users"}) == off
  end

  test "sign-in users is absent from the live page while its switch is off" do
    refute Platform.SignInAdmin.Config.enabled?()
    {:ok, view, html} = live(authed(user!("admin")), "/admin")

    refute has_element?(view, "[data-role=admin-sign-in-users-link]")
    refute html =~ ~s(href="/admin/sign-in-users")
  end

  test "a catch-all handle_info swallows a stray message" do
    assert function_exported?(PlatformWeb.AdminLive, :handle_info, 2)

    {:ok, view, _html} = live(authed(user!("admin")), "/admin")
    send(view.pid, {:stray, make_ref()})
    send(view.pid, :unexpected)

    assert render(view) =~ "data-admin-card"
    assert Process.alive?(view.pid)
  end
end
