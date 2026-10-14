defmodule PlatformWeb.LayoutsConnectionStatusTest do
  @moduledoc """
  The quiet reconnect markup (task 01a12b10 stage 2).

    * #client-error / #server-error no longer carry the stock
      `phx-disconnected` / `phx-connected` bindings (LiveView ran those 500 ms
      into any drop, which made every routine reconnect red). They carry the
      `data-escalate` / `data-clear` JS commands the app.js controller runs,
      and keep `role="alert"` and their copy.
    * #connection-status is a polite status region, `phx-update="ignore"`,
      and uses no error or warning tokens.
    * Exactly one slot per page: the shell renders the pane variant inside
      `<main>` and tells flash_group not to render the window one.
  """
  use PlatformWeb.ConnCase, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  defp flash_group(extra \\ %{}) do
    %{flash: %{}}
    |> Map.merge(extra)
    |> PlatformWeb.Layouts.flash_group()
    |> rendered_to_string()
  end

  defp toast(html, id) do
    [tag] = Regex.run(~r{<div[^>]*id="#{id}"[^>]*>}s, html)
    tag
  end

  defp slot_markup(html) do
    [markup] =
      Regex.run(~r{<div[^>]*id="connection-status".*?</span>\s*</span>\s*</div>\s*</div>}s, html)

    markup
  end

  describe "red toasts" do
    for id <- ["client-error", "server-error"] do
      test "##{id} has no stock connection bindings and carries the escalate/clear commands" do
        tag = flash_group() |> toast(unquote(id))

        refute tag =~ "phx-disconnected"
        refute tag =~ "phx-connected"
        assert tag =~ ~s(role="alert")
        assert tag =~ ~r/data-escalate="[^"]*#{unquote(id)}[^"]*"/
        assert tag =~ ~r/data-clear="[^"]*#{unquote(id)}[^"]*"/
        assert tag =~ "hidden"
      end
    end

    test "keep the existing copy" do
      html = flash_group()
      assert html =~ "We can&#39;t find the internet"
      assert html =~ "Something went wrong!"
      assert html =~ "Attempting to reconnect"
    end
  end

  describe "connection_status/1" do
    test "is a polite, ignored status region with no error or warning tokens" do
      html = flash_group()
      markup = slot_markup(html)
      [tag] = Regex.run(~r{<div[^>]*id="connection-status"[^>]*>}s, markup)

      assert tag =~ ~s(role="status")
      assert tag =~ ~s(aria-live="polite")
      assert tag =~ ~s(phx-update="ignore")
      assert tag =~ ~s(data-state="idle")
      refute markup =~ ~r/alert-error|bg-error|text-error|warning/
      assert markup =~ "bg-primary"
      assert markup =~ "bg-base-300 text-base-content"
    end

    test "flash_group renders the fixed window slot by default and none with connection_status: false" do
      html = flash_group()
      assert length(Regex.scan(~r/id="connection-status"/, html)) == 1
      assert slot_markup(html) =~ "fixed"

      refute flash_group(%{connection_status: false}) =~ "connection-status"
    end
  end

  describe "shell layout" do
    defp user! do
      n = System.unique_integer([:positive])

      user =
        %User{}
        |> User.changeset(%{
          email: "connection-status-#{n}@example.com",
          name: "Connection Status #{n}",
          oidc_sub: "oidc-connection-status-#{n}"
        })
        |> Repo.insert!()

      %OrgMembership{}
      |> OrgMembership.changeset(%{
        user_id: user.id,
        org_id: Tenancy.get_org_by_slug!("acme").id,
        role: "admin"
      })
      |> Repo.insert!()

      user
    end

    test "renders exactly one #connection-status, the pane variant inside <main>" do
      html =
        build_conn()
        |> Plug.Test.init_test_session(%{"current_user_id" => user!().id})
        |> get("/tasks")
        |> html_response(200)

      assert length(Regex.scan(~r/id="connection-status"/, html)) == 1

      [main] = Regex.run(~r{<main[^>]*data-scroll-container.*?</main>}s, html)
      assert main =~ ~s(id="connection-status")
      assert main =~ ~r{<main[^>]*class="relative }

      [tag] = Regex.run(~r{<div[^>]*id="connection-status"[^>]*>}s, main)
      assert tag =~ "absolute"
      refute tag =~ "fixed"
    end
  end
end
