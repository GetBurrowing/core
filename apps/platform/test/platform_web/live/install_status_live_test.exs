defmodule PlatformWeb.InstallStatusLiveTest do
  @moduledoc """
  `/install-status/:token` (task 01a10315 stage 3): the customer's progress
  screen and the shown-once hand-over, against dev stub mode's fakes
  (`Platform.InstallsFixtures.use_fake_backend/0`).

  The hand-over's load-bearing property is that the credentials reach the
  browser once and are never a long-lived assign: `deep_holds?/2` walks the
  whole LiveView process state after the render, with a positive control
  showing the walker reaches assigns.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.InstallsFixtures

  alias Platform.Installs
  alias Platform.Installs.Runner

  @forbidden ~w(droplet cloud-init firewall suite)

  setup do
    use_fake_backend()
    :ok
  end

  defp path(token), do: ~p"/install-status/#{token}"

  defp iso(seconds_ago),
    do: DateTime.utc_now() |> DateTime.add(-seconds_ago, :second) |> DateTime.to_iso8601()

  defp put_steps!(install, states, attrs \\ %{}) do
    steps =
      Enum.map(install.steps, fn step ->
        case Map.fetch(states, step["key"]) do
          {:ok, changes} -> Map.merge(step, changes)
          :error -> step
        end
      end)

    Installs.update!(
      Installs.get(install.id),
      Map.merge(%{status: "provisioning", steps: steps}, attrs)
    )
  end

  defp refute_jargon(html) do
    lower = String.downcase(html)
    for word <- @forbidden, do: refute(lower =~ word, "found #{inspect(word)} on screen")
    refute lower =~ "dns record"
  end

  defp deep_holds?(term, needle) when is_binary(term), do: String.contains?(term, needle)

  defp deep_holds?(%_{} = struct, needle),
    do: struct |> Map.from_struct() |> deep_holds?(needle)

  defp deep_holds?(term, needle) when is_map(term),
    do: Enum.any?(term, fn {k, v} -> deep_holds?(k, needle) or deep_holds?(v, needle) end)

  defp deep_holds?([head | tail], needle),
    do: deep_holds?(head, needle) or deep_holds?(tail, needle)

  defp deep_holds?(term, needle) when is_tuple(term),
    do: term |> Tuple.to_list() |> deep_holds?(needle)

  defp deep_holds?(_term, _needle), do: false

  describe "progress" do
    test "each step state renders its label, tone and timing", %{conn: conn} do
      {install, token} = create_install!()

      put_steps!(install, %{
        "reserve" => %{"state" => "done", "started_at" => iso(100), "finished_at" => iso(58)},
        "install" => %{"state" => "running", "started_at" => iso(50)}
      })

      {:ok, view, html} = live(conn, path(token))

      assert html =~ "Setting up Acme Bakery"
      assert has_element?(view, "#step-reserve[data-state=done]", "Reserving your server")
      assert has_element?(view, "#step-reserve .text-neutral")
      assert has_element?(view, "#step-reserve", "0:42")

      assert has_element?(
               view,
               "#step-install[data-state=running].bg-info\\/10",
               "Installing Burrow"
             )

      assert has_element?(view, "#step-install .text-info", "Installing Burrow")
      assert has_element?(view, "#step-install", "…")

      assert has_element?(
               view,
               "#step-connect[data-state=pending]",
               "Connecting #{install.primary_host}"
             )

      assert has_element?(view, "#step-final[data-state=pending]", "Final checks")
      assert html =~ "About 8 minutes. You can close this tab; this link keeps working."
      assert has_element?(view, "#install-plan", "New York (nyc3) · 2 vCPU / 4 GB · $24/mo")
      refute has_element?(view, "#install-failed")
      refute has_element?(view, "#install-records")
      refute_jargon(html)
    end

    test "re-renders live when the install changes", %{conn: conn} do
      {install, token} = create_install!()
      {:ok, view, _html} = live(conn, path(token))
      assert has_element?(view, "#step-reserve[data-state=pending]")

      put_steps!(install, %{"reserve" => %{"state" => "running", "started_at" => iso(1)}})
      assert render(view) =~ "Reserving your server"
      assert has_element?(view, "#step-reserve[data-state=running]")
    end

    test "a failed step shows its reason, Retry and the no-second-server copy", %{conn: conn} do
      {install, token} = create_install!()

      put_steps!(
        install,
        %{
          "reserve" => %{"state" => "done", "started_at" => iso(60), "finished_at" => iso(30)},
          "install" => %{
            "state" => "failed",
            "started_at" => iso(20),
            "finished_at" => iso(5),
            "error" => Installs.describe_error("install", :timeout)
          }
        },
        %{status: "failed"}
      )

      {:ok, view, html} = live(conn, path(token))

      assert has_element?(view, "#step-install[data-state=failed] .text-error")
      assert has_element?(view, "#install-failed", "This step took longer than expected.")
      assert has_element?(view, "#install-failed", "Retrying won't create a second server.")
      assert has_element?(view, "#install-failed .text-error", "Installing Burrow didn't finish.")
      # Retry is the screen's one primary button.
      assert [_] = Floki.find(Floki.parse_document!(html), ".btn-primary")
      refute_jargon(html)

      view |> element("#install-retry") |> render_click()

      install = Installs.get(install.id)
      assert install.status == "queued"
      assert Enum.find(install.steps, &(&1["key"] == "install"))["state"] == "pending"
      refute has_element?(view, "#install-failed")
    end

    test "a customer-domain install waiting to connect lists its two CNAME records", %{conn: conn} do
      {install, token} =
        create_install!(%{"domain_mode" => "customer", "primary_host" => "burrow.acme.test"})

      put_steps!(
        install,
        %{
          "reserve" => %{"state" => "done", "started_at" => iso(60), "finished_at" => iso(30)},
          "install" => %{"state" => "done", "started_at" => iso(30), "finished_at" => iso(10)},
          "connect" => %{"state" => "running", "started_at" => iso(10)}
        },
        %{droplet_ip: "203.0.113.7"}
      )

      {:ok, view, html} = live(conn, path(token))

      assert has_element?(
               view,
               "#step-connect[data-state=running]",
               "Connecting burrow.acme.test"
             )

      assert has_element?(view, "#install-records [data-record-type=CNAME]", "burrow.acme.test")

      assert has_element?(
               view,
               "#install-records .font-mono",
               "#{install.slug}.installs.example.test."
             )

      assert has_element?(
               view,
               "#install-records .font-mono",
               "auth.#{install.slug}.installs.example.test."
             )

      assert length(
               Floki.find(Floki.parse_document!(html), "#install-records [data-record-type]")
             ) ==
               2

      refute_jargon(html)
    end

    test "an apex domain gets an A record to the server for its primary host", %{conn: conn} do
      {install, token} =
        create_install!(%{"domain_mode" => "customer", "primary_host" => "acme.test"})

      put_steps!(install, %{"connect" => %{"state" => "running", "started_at" => iso(1)}}, %{
        droplet_ip: "203.0.113.7"
      })

      {:ok, view, _html} = live(conn, path(token))

      assert has_element?(view, "#install-records [data-record-type=A]", "203.0.113.7")
      assert has_element?(view, "#install-records [data-record-type=CNAME]", "auth.acme.test")
    end

    test "a subdomain of ours shows no records block", %{conn: conn} do
      {install, token} = create_install!()
      put_steps!(install, %{"connect" => %{"state" => "running", "started_at" => iso(1)}})
      {:ok, view, _html} = live(conn, path(token))
      refute has_element?(view, "#install-records")
    end
  end

  describe "hand-over" do
    setup do
      {install, token} = create_install!()
      assert Runner.run(install.id) == :ready
      %{install: Installs.get(install.id), token: token}
    end

    test "the plain HTTP response carries no credential", %{conn: conn, token: token} do
      html = conn |> get(path(token)) |> html_response(200)
      assert html =~ "Save these now. We don&#39;t keep a copy."
      refute html =~ "FAKECODE"
      refute html =~ "BEGIN OPENSSH"
    end

    test "shows the card; the checkbox gates Open Burrow; acknowledging redirects and empties it",
         %{conn: conn, install: install, token: token} do
      {:ok, view, html} = live(conn, path(token))

      assert html =~ "Save these now. We don&#39;t keep a copy."
      assert has_element?(view, "#install-handover .border-warning")
      assert has_element?(view, "#handover-burrow.font-mono", "https://#{install.primary_host}")
      assert has_element?(view, "#handover-admin.font-mono", install.owner_email)
      assert has_element?(view, "#handover-signin-masked")

      assert has_element?(
               view,
               "#handover-signin-value.hidden",
               "https://auth.fake.invalid/lc/FAKECODE"
             )

      assert html =~ "Sign-in link"
      assert html =~ "Opens once. You&#39;ll add a passkey."
      # SSH collapsed by default: a <details> without `open`.
      assert has_element?(view, "details#handover-ssh:not([open])", "For technical users (SSH)")
      assert has_element?(view, "#handover-ssh-host", install.droplet_ip)
      assert has_element?(view, "#handover-ssh-user", "root")
      assert has_element?(view, "#handover-ssh-key", "BEGIN OPENSSH PRIVATE KEY")

      assert has_element?(
               view,
               "#handover-download.btn-outline[phx-hook=HandoverDownload]",
               "Download as file"
             )

      refute html =~ "fake-oidc-client-secret"
      refute html =~ "fake-static-api-key"
      refute_jargon(html)

      # One primary button, and it is disabled until the box is ticked.
      assert [_] = Floki.find(Floki.parse_document!(html), ".btn-primary")
      assert has_element?(view, "#open-burrow[disabled]", "Open Burrow")

      # A forged click while unticked does nothing.
      view |> element("#open-burrow") |> render_click()
      refute Installs.get(install.id).handover_acknowledged_at

      view |> form("#handover-ack", %{saved: "true"}) |> render_change()
      refute has_element?(view, "#open-burrow[disabled]")
      # Ticking re-rendered the page but not the card: the browser keeps it.
      assert has_element?(view, "#handover-signin-value", "FAKECODE")

      url = "https://#{install.primary_host}/setup/connect-ai"

      assert {:error, {:redirect, %{to: ^url}}} =
               view |> element("#open-burrow") |> render_click()

      install = Installs.get(install.id)
      assert install.handover_acknowledged_at
      assert install.handover_sealed == nil

      {:ok, _view, html} = live(conn, path(token))
      assert html =~ "Your Burrow is ready"
      assert html =~ "https://#{install.primary_host}"
      refute html =~ "sign-in"
      refute html =~ "Sign-in"
      refute html =~ "BEGIN OPENSSH"
      refute html =~ "FAKECODE"
    end

    test "the credentials are not held in the LiveView's state after the render",
         %{conn: conn, token: token, install: install} do
      {:ok, view, _html} = live(conn, path(token))
      assert render(view) =~ "FAKECODE"

      state = :sys.get_state(view.pid)
      # Positive control: the walker does reach assigns.
      assert deep_holds?(state, install.business_name)
      refute deep_holds?(state, "FAKECODE")
      refute deep_holds?(state, "BEGIN OPENSSH")

      # A broadcast while the card is up neither re-reveals nor empties it.
      send(view.pid, {:install_updated, install.id})
      assert render(view) =~ "FAKECODE"
      refute deep_holds?(:sys.get_state(view.pid), "FAKECODE")
    end

    test "an expired hand-over shows the ready page without credentials",
         %{conn: conn, token: token, install: install} do
      Installs.update!(install, %{handover_sealed: nil, handover_expired_at: DateTime.utc_now()})
      {:ok, _view, html} = live(conn, path(token))
      assert html =~ "Your Burrow is ready"
      refute html =~ "FAKECODE"
    end
  end

  test "an unknown token shows the invalid page", %{conn: conn} do
    {:ok, _view, html} = live(conn, path("not-a-real-token"))
    assert html =~ "This link isn&#39;t valid"
    refute html =~ "Setting up"
  end

  test "a destroyed install shows the removed page", %{conn: conn} do
    {install, token} = create_install!()
    Installs.update!(install, %{status: "destroyed"})
    {:ok, _view, html} = live(conn, path(token))
    assert html =~ "This install has been removed"
    refute html =~ "FAKECODE"
  end

  test "step timings format as m:ss" do
    alias PlatformWeb.InstallStatusLive, as: L

    step = %{
      "state" => "done",
      "started_at" => "2026-10-30T10:00:00Z",
      "finished_at" => "2026-10-30T10:03:10Z"
    }

    assert L.elapsed(step) == "3:10"
    assert L.elapsed(%{step | "finished_at" => "2026-10-30T10:00:42Z"}) == "0:42"
    assert L.elapsed(%{"state" => "running"}) == "…"
    assert L.elapsed(%{"state" => "pending", "started_at" => nil, "finished_at" => nil}) == nil
  end
end
