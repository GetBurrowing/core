defmodule PlatformWeb.AdminPrototypesLiveTest do
  @moduledoc """
  `/admin/prototypes` (task 01a1316b-4e46 stage 2): the install's prototype
  publishing switch and caps. Admin-only by the `:admin` live_session, and
  each field saves into the `Platform.Prototypes.Settings` singleton.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.PrototypeFixtures

  alias Platform.Prototypes.Settings
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  @form "#admin-prototypes-form"

  setup do
    set_settings!(%{
      enabled: false,
      who_may_publish: "members",
      max_bundle_bytes: 25 * 1024 * 1024,
      max_files: 500,
      retention_days: 90
    })

    :ok
  end

  defp acme_user!(role) do
    user = user!("Admin Prototypes #{role}")

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Tenancy.get_org_by_slug!("acme").id,
      role: role
    })
    |> Repo.insert!()

    user
  end

  defp conn_for(conn, user), do: init_test_session(conn, %{"current_user_id" => user.id})

  defp save(view, params), do: view |> form(@form, %{"settings" => params}) |> render_submit()

  test "a member (non-admin) mount is redirected by :ensure_admin", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/"}}} =
             conn |> conn_for(acme_user!("member")) |> live(~p"/admin/prototypes")
  end

  test "an admin sees the current settings", %{conn: conn} do
    {:ok, _view, html} = conn |> conn_for(acme_user!("admin")) |> live(~p"/admin/prototypes")

    assert html =~ "Admin · Prototypes"
    assert html =~ ~s(value="25")
    assert html =~ ~s(value="500")
    assert html =~ ~s(value="90")
  end

  test "each field saves", %{conn: conn} do
    {:ok, view, _html} = conn |> conn_for(acme_user!("admin")) |> live(~p"/admin/prototypes")

    save(view, %{"enabled" => "true"})
    assert Settings.get().enabled == true

    save(view, %{"who_may_publish" => "admins"})
    assert Settings.get().who_may_publish == "admins"

    save(view, %{"max_bundle_mb" => "40"})
    assert Settings.get().max_bundle_bytes == 40 * 1024 * 1024

    save(view, %{"max_files" => "120"})
    assert Settings.get().max_files == 120

    save(view, %{"retention_days" => "30"})
    assert Settings.get().retention_days == 30

    html = save(view, %{"retention_days" => ""})
    assert Settings.get().retention_days == nil
    assert html =~ "Prototype settings saved."

    # The earlier saves were not undone by the later ones.
    s = Settings.get()
    assert {s.enabled, s.who_may_publish, s.max_files} == {true, "admins", 120}

    save(view, %{"enabled" => "false"})
    assert Settings.get().enabled == false
  end

  test "an invalid value is refused and nothing changes", %{conn: conn} do
    {:ok, view, _html} = conn |> conn_for(acme_user!("admin")) |> live(~p"/admin/prototypes")

    html = save(view, %{"max_files" => "0"})
    assert html =~ "Not saved"
    assert Settings.get().max_files == 500
  end

  test "/admin links to the page", %{conn: conn} do
    {:ok, _view, html} = conn |> conn_for(acme_user!("admin")) |> live(~p"/admin")
    assert html =~ ~s(data-role="admin-prototypes-link")
    assert html =~ ~s(href="/admin/prototypes")
  end
end
