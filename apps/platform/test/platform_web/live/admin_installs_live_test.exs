defmodule PlatformWeb.AdminInstallsLiveTest do
  @moduledoc """
  `/admin/installs` (task 01a10315 stage 3): root admins only, the progress
  link is shown once, and Destroy needs the slug typed.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.InstallsFixtures

  alias Platform.Installs
  alias Platform.VaultFixtures

  setup %{conn: conn} do
    use_fake_backend()
    admin = admin!()
    %{conn: Plug.Test.init_test_session(conn, %{"current_user_id" => admin.id}), admin: admin}
  end

  test "a non-admin mount is redirected", %{conn: conn} do
    user = VaultFixtures.non_admin!()

    assert {:error, {_, %{to: "/access-denied?module=admin"}}} =
             conn
             |> Plug.Test.init_test_session(%{"current_user_id" => user.id})
             |> live(~p"/admin/installs")
  end

  test "the form offers the US regions, both sizes with prices and both domain modes",
       %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/admin/installs")

    for region <- ~w(nyc1 nyc2 nyc3 sfo2 sfo3 atl1 ric1) do
      assert has_element?(view, "#install-form option[value=#{region}]")
    end

    assert has_element?(view, "#install-form option[value=nyc3][selected]")
    assert html =~ "2 vCPU / 4 GB · $24/mo"
    assert html =~ "4 vCPU / 8 GB · $48/mo"
    assert has_element?(view, "input[name='install[size]'][value=s-2vcpu-4gb][checked]")
    assert html =~ "Use a Burrow subdomain"
    assert html =~ "Use my own domain"
    refute html =~ "Suite"
  end

  test "create shows the progress link once", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/installs")

    html =
      view
      |> form("#install-form",
        install: %{
          business_name: "Acme Bakery",
          owner_email: "owner@acme.test",
          region: "nyc3",
          size: "s-2vcpu-4gb",
          domain_mode: "ours"
        }
      )
      |> render_submit()

    [install] = Installs.list(admin!()) |> elem(1)
    assert install.business_name == "Acme Bakery"
    assert install.primary_host == "#{install.slug}.installs.example.test"

    [url] =
      html
      |> Floki.parse_document!()
      |> Floki.find("#install-new-link-url")
      |> Enum.map(&String.trim(Floki.text(&1)))

    assert url =~ ~r{/install-status/[A-Za-z0-9_-]{43}$}
    token = url |> String.split("/") |> List.last()
    assert Installs.get_by_token(token).id == install.id
    assert has_element?(view, "#install-#{install.slug}", install.primary_host)

    # Shown once: a fresh mount cannot show it again.
    {:ok, _view, html} = live(conn, ~p"/admin/installs")
    refute html =~ token
    refute html =~ "install-new-link"
  end

  test "a customer domain is created with its host; a bad one is refused in words",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/installs")

    params = %{
      business_name: "Acme Bakery",
      owner_email: "owner@acme.test",
      region: "nyc3",
      size: "s-4vcpu-8gb",
      domain_mode: "customer"
    }

    view |> form("#install-form", install: params) |> render_change()

    html =
      view
      |> form("#install-form", install: Map.put(params, :primary_host, "not a host"))
      |> render_submit()

    assert html =~ "Enter the customer&#39;s domain as a host name"
    assert {:ok, []} = Installs.list(admin!())

    view
    |> form("#install-form", install: Map.put(params, :primary_host, "burrow.acme.test"))
    |> render_submit()

    assert {:ok, [install]} = Installs.list(admin!())
    assert install.primary_host == "burrow.acme.test"
    assert install.size == "s-4vcpu-8gb"
  end

  test "Destroy requires the typed slug, then tears down", %{conn: conn} do
    {install, _token} = create_install!()
    {:ok, view, _html} = live(conn, ~p"/admin/installs")

    view |> element("#install-#{install.slug} button", "Destroy") |> render_click()
    assert has_element?(view, "#destroy-#{install.slug} button[type=submit][disabled]")

    # A wrong name is refused, even if the disabled button is bypassed.
    view |> form("#destroy-#{install.slug}", confirm: "wrong") |> render_submit()
    assert Installs.get(install.id).status == "queued"

    view |> form("#destroy-#{install.slug}", confirm: install.slug) |> render_change()
    refute has_element?(view, "#destroy-#{install.slug} button[type=submit][disabled]")
    view |> form("#destroy-#{install.slug}", confirm: install.slug) |> render_submit()

    wait_until(fn -> Installs.get(install.id).status == "destroyed" end)
    render_async(view)
    assert has_element?(view, "#install-#{install.slug}", "destroyed")
    refute has_element?(view, "#install-#{install.slug} button", "Destroy")
  end
end
