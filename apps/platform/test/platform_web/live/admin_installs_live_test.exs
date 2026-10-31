defmodule PlatformWeb.AdminInstallsLiveTest do
  @moduledoc """
  `/admin/installs` (task 01a10315 stage 3): root admins only, the progress
  link is shown once, and Destroy needs the slug typed.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.InstallsFixtures

  alias Platform.Installs
  alias Platform.Installs.Fake
  alias Platform.Installs.RequestSettings
  alias Platform.Repo
  alias Platform.VaultFixtures

  setup %{conn: conn} do
    use_fake_backend()
    Platform.Installs.DigitalOcean.clear_sizes_cache()
    on_exit(&Platform.Installs.DigitalOcean.clear_sizes_cache/0)
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

    # Stage 6: only the regions that offer the default size (the fake answers
    # as DigitalOcean did on 2026-10-30), the first of them selected.
    for region <- ~w(nyc1 sfo2 sfo3) do
      assert has_element?(view, "#install-form option[value=#{region}]")
    end

    for region <- ~w(nyc2 nyc3 atl1 ric1) do
      refute has_element?(view, "#install-form option[value=#{region}]")
    end

    assert has_element?(view, "#install-form option[value=nyc1][selected]")
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
          region: "nyc1",
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

    assert url =~ ~r|/install-status/[A-Za-z0-9_-]{43}$|
    token = url |> String.split("/") |> List.last()
    assert Installs.get_by_token(token).id == install.id
    assert has_element?(view, "#install-#{install.slug}", install.primary_host)

    # Shown once: a fresh mount cannot show it again.
    {:ok, _view, html} = live(conn, ~p"/admin/installs")
    refute html =~ token
    refute html =~ "install-new-link"
  end

  test "a configured size with no tier is refused in words, and nothing is created",
       %{conn: conn} do
    put_installs_env(sizes: ["s-2vcpu-4gb", "s-8vcpu-16gb"])
    {:ok, view, _html} = live(conn, ~p"/admin/installs")

    html =
      view
      |> form("#install-form",
        install: %{
          business_name: "Acme Bakery",
          owner_email: "owner@acme.test",
          region: "nyc1",
          size: "s-8vcpu-16gb",
          domain_mode: "ours"
        }
      )
      |> render_submit()

    assert html =~ "This server size isn&#39;t supported yet."
    assert {:ok, []} = Installs.list(admin!())
  end

  test "a customer domain is created with its host; a bad one is refused in words",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/installs")

    params = %{
      business_name: "Acme Bakery",
      owner_email: "owner@acme.test",
      region: "nyc1",
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

  test "the list never holds an install's sealed private key", %{conn: conn} do
    {install, _token} = create_install!()

    assert Installs.get(install.id).handover_sealed
           |> Platform.Installs.Handover.fetch("ssh_private_key") =~ "BEGIN OPENSSH"

    {:ok, view, html} = live(conn, ~p"/admin/installs")
    assert html =~ install.slug
    # Walked, not inspected: Install's derived Inspect hides handover_sealed,
    # so `inspect/2` would pass even with the key in an assign.
    state = :sys.get_state(view.pid)
    # Positive control: the walker does reach the list.
    assert deep_holds?(state, install.slug)
    refute deep_holds?(state, "BEGIN OPENSSH")
  end

  defp deep_holds?(term, needle) when is_binary(term), do: String.contains?(term, needle)

  # A hand-over's values sit behind a closure the walker cannot enter.
  defp deep_holds?(%Platform.Installs.Handover{} = handover, needle),
    do: Platform.Installs.Handover.to_json(handover) =~ needle

  defp deep_holds?(%_{} = struct, needle),
    do: struct |> Map.from_struct() |> deep_holds?(needle)

  defp deep_holds?(term, needle) when is_map(term),
    do: Enum.any?(term, fn {k, v} -> deep_holds?(k, needle) or deep_holds?(v, needle) end)

  defp deep_holds?([head | tail], needle),
    do: deep_holds?(head, needle) or deep_holds?(tail, needle)

  defp deep_holds?(term, needle) when is_tuple(term),
    do: term |> Tuple.to_list() |> deep_holds?(needle)

  defp deep_holds?(_term, _needle), do: false

  # ── Install requests (task 01a18f0c stage 3) ───────────────────────────

  @request %{
    "name" => "Pat Baker",
    "email" => "pat@acme-requests.test",
    "business" => "Acme Bakery",
    "note" => "two locations"
  }

  defp request!(overrides \\ %{}) do
    attrs = Map.merge(@request, overrides)
    {:ok, :created} = Installs.request(attrs)
    {:ok, requests} = Installs.list_requests(admin!())
    Enum.find(requests, &(&1.owner_email == attrs["email"]))
  end

  test "requests render above the form with who, what and exactly what Provision buys",
       %{conn: conn} do
    request = request!()
    {:ok, view, html} = live(conn, ~p"/admin/installs")

    {requests_at, _} = :binary.match(html, ~s(data-role="install-requests"))
    {form_at, _} = :binary.match(html, ~s(id="install-form"))
    assert requests_at < form_at

    row = "#install-request-#{request.id}"
    assert has_element?(view, row, "Acme Bakery")
    assert has_element?(view, row, "Pat Baker")
    assert has_element?(view, row, "pat@acme-requests.test")
    assert has_element?(view, row, "two locations")

    defaults = Installs.defaults()

    expected =
      "Will use: #{Installs.region_label(hd(defaults.regions))} · 2 vCPU / 4 GB · $24/mo · " <>
        "#{request.slug}.installs.example.test"

    [line] =
      html
      |> Floki.parse_document!()
      |> Floki.find("#{row} [data-role=install-request-will-use]")
      |> Enum.map(&(&1 |> Floki.text() |> String.split() |> Enum.join(" ")))

    assert line == expected
    refute html =~ "No install requests."
  end

  test "the empty state, and Provision as one click moving the row to the list as queued",
       %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/admin/installs")
    assert html =~ "No install requests."

    request = request!()
    # The broadcast reaches the open page: the row appears without a reload.
    assert render(view) =~ "install-request-#{request.id}"

    html =
      view
      |> element("#install-request-#{request.id} button", "Provision")
      |> render_click()

    install = Installs.get(request.id)
    assert install.status == "queued"
    refute has_element?(view, "#install-request-#{request.id}")
    assert has_element?(view, "#install-#{install.slug}", "queued")
    assert has_element?(view, "#install-#{install.slug}", "Requested by pat@acme-requests.test")
    assert html =~ "Provisioning. pat@acme-requests.test gets an email when it&#39;s ready."
    assert html =~ "No install requests."

    # A request-made install never shows a progress link or token.
    refute html =~ "/install-status/"
    refute html =~ "install-new-link"
    # start_runs is false here: the click queued the run, it bought nothing yet.
    assert Map.get(Fake.calls(), "POST /v2/droplets", 0) == 0
  end

  test "Dismiss deletes the request", %{conn: conn} do
    request = request!()
    {:ok, view, _html} = live(conn, ~p"/admin/installs")

    assert has_element?(
             view,
             "#install-request-#{request.id} button[data-confirm]",
             "Dismiss"
           )

    view |> element("#install-request-#{request.id} button", "Dismiss") |> render_click()

    assert Installs.get(request.id) == nil
    refute has_element?(view, "#install-request-#{request.id}")
  end

  test "the spend-gate toggle reflects and persists RequestSettings, asking before on",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/installs")
    toggle = "[data-role=auto-provision-toggle]"

    refute has_element?(view, "#{toggle}[checked]")
    assert has_element?(view, "#{toggle}[data-confirm]")

    view |> element(toggle) |> render_click()
    assert RequestSettings.get().auto_provision_requests
    assert has_element?(view, "#{toggle}[checked]")
    refute has_element?(view, "#{toggle}[data-confirm]")

    # A fresh mount reads the row.
    {:ok, view, _html} = live(conn, ~p"/admin/installs")
    assert has_element?(view, "#{toggle}[checked]")

    view |> element(toggle) |> render_click()
    refute RequestSettings.get().auto_provision_requests
  end

  test "a requester's note renders escaped", %{conn: conn} do
    request!(%{"note" => "<script>alert('x')</script> hello"})
    {:ok, _view, html} = live(conn, ~p"/admin/installs")

    refute html =~ "<script>alert"
    assert html =~ "&lt;script&gt;alert"
  end

  test "the hand-over email state is a status word read from the delivery", %{conn: conn} do
    request = request!()
    {:ok, install} = Installs.provision_request(admin!(), request.id)

    {:ok, _view, html} = live(conn, ~p"/admin/installs")
    assert email_state(html, install) == "not sent yet"

    org = Platform.Tenancy.get_org_by_slug!("initech")
    account = Platform.Test.ExperimentsMailFixtures.account!(org.id)
    id = Platform.Types.UUIDv7.generate()

    %{
      id: id,
      org_id: org.id,
      account_id: account.id,
      sender_key: "noreply",
      from_address: "noreply@example.com",
      recipients: [install.owner_email],
      subject: "Your Burrow is ready",
      body: "BODY-MUST-NOT-RENDER",
      actor_type: "system",
      message_id_header: "<#{id}@example.com>",
      status: "queued"
    }
    |> Platform.Mail.Delivery.insert_changeset()
    |> Repo.insert!()

    Installs.update!(Installs.get(install.id), %{handover_email_delivery_id: id})

    {:ok, _view, html} = live(conn, ~p"/admin/installs")
    assert email_state(html, install) == "queued"
    refute html =~ "BODY-MUST-NOT-RENDER"
    refute html =~ "/install-status/"
  end

  test "a ready request-made install with no mail sender says not configured", %{conn: conn} do
    request = request!()
    {:ok, install} = Installs.provision_request(admin!(), request.id)
    Installs.update!(Installs.get(install.id), %{status: "ready"})

    {:ok, _view, html} = live(conn, ~p"/admin/installs")
    assert email_state(html, install) == "not configured"
  end

  defp email_state(html, install) do
    html
    |> Floki.parse_document!()
    |> Floki.find("#install-#{install.slug} [data-role=install-email-state]")
    |> Enum.map(&String.trim(Floki.text(&1)))
    |> List.first()
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
