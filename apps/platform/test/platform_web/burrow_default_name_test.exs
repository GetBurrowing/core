defmodule PlatformWeb.BurrowDefaultNameTest do
  @moduledoc """
  The default product name is "Burrow" everywhere it is user-visible, and an
  admin-set name still wins over it (task `01a120c5` stage 3).

  ## Where "Burrow" comes from

  Not from a constant. The create migration seeded the singleton
  `install_branding` row as ('Suite', '#171b25', '#171b25');
  `20261009150000_rebrand_install_branding_defaults_to_burrow` moves the
  still-seeded values to ('Burrow', '#191b20', '#191b20'). The test DB is
  built by those migrations, so "a freshly migrated DB" is the DB these
  tests start from.

  ## What each mutation detonates

    * Make `Platform.Branding.app_name/0` return the literal "Burrow" (drop
      the row read): "an admin-set name wins on every surface" goes red, on
      `app_name/0` first and on every surface after it.
    * Put the literal "Startup Suite" back in the rail label
      (`sidebar.ex`): both shell tests go red.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Branding
  alias Platform.Chat.AttentionRouter
  alias Platform.Chat.Message
  alias Platform.Chat.Space
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  defp root_admin! do
    n = System.unique_integer([:positive])

    user =
      %User{}
      |> User.changeset(%{
        email: "burrow-name-#{n}@example.com",
        name: "Burrow Name Admin",
        oidc_sub: "oidc-burrow-name-#{n}"
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

  # The full document (root layout + shell), from the dead render.
  defp shell_html(conn, user) do
    conn |> init_test_session(current_user_id: user.id) |> get("/chat") |> html_response(200)
  end

  defp spans_ending_in_burrow(doc, selector) do
    doc
    |> LazyHTML.query(selector)
    |> Enum.count(&(&1 |> LazyHTML.text() |> String.trim() |> String.ends_with?("Burrow")))
  end

  defp rail_label(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("#sidebar-brand span")
    |> LazyHTML.text()
    |> String.trim()
  end

  defp title_tag(html) do
    [tag] = Regex.run(~r/<title\b[^>]*>.*?<\/title>/s, html)
    tag
  end

  defp meta(html, name) do
    Regex.run(~r/<meta name="#{name}" content="([^"]*)"/, html) |> Enum.at(1)
  end

  defp dm_push_title(sender) do
    dm = %Space{id: Ecto.UUID.generate(), name: nil, kind: "dm", slug: nil}
    message = %Message{id: Ecto.UUID.generate(), content: "hi"}
    AttentionRouter.push_notification(sender, message, :mention, dm, []).title
  end

  describe "a freshly migrated DB" do
    test "app_name/0 and the manifest read Burrow on the new dark surface", %{conn: conn} do
      assert Branding.app_name() == "Burrow"

      body = conn |> get("/manifest.json") |> json_response(200)
      assert body["name"] == "Burrow"
      assert body["short_name"] == "Burrow"
      assert body["theme_color"] == "#191b20"
      assert body["background_color"] == "#191b20"
    end

    test "the shell's rail label, title and home-screen title read Burrow, never Startup Suite",
         %{conn: conn} do
      user = root_admin!()
      html = shell_html(conn, user)

      assert rail_label(html) == "Burrow"
      # /chat sets page_title "Chat"; the app name is the title's default.
      assert title_tag(html) =~ ~s(data-default="Burrow")
      assert meta(html, "apple-mobile-web-app-title") == "Burrow"
      assert meta(html, "theme-color") == "#191b20"
      refute html =~ "Startup Suite"

      # The connected render carries the same label.
      {:ok, _view, live_html} =
        build_conn() |> init_test_session(current_user_id: user.id) |> live("/chat")

      assert rail_label(live_html) == "Burrow"
      refute live_html =~ "Startup Suite"
    end

    test "a push for a space with no name names the install" do
      assert dm_push_title("Sam") == "Sam in Burrow"
      assert AttentionRouter.notification_title("Alex", :here) == "Alex @here in Burrow"
    end
  end

  describe "an admin-set name wins on every surface" do
    test "app_name/0, manifest, title, rail label and push title read Acme Ops",
         %{conn: conn} do
      admin = root_admin!()
      {:ok, _} = Branding.update_identity(admin, %{app_name: "Acme Ops"})

      assert Branding.app_name() == "Acme Ops"

      body = conn |> get("/manifest.json") |> json_response(200)
      assert body["name"] == "Acme Ops"
      assert body["short_name"] == "Acme Ops"

      html = shell_html(build_conn(), admin)
      assert rail_label(html) == "Acme Ops"
      assert title_tag(html) =~ ~s(data-default="Acme Ops")
      assert meta(html, "apple-mobile-web-app-title") == "Acme Ops"
      # The theme picker's preset names ("Burrow", "Burrow midnight", ...) are
      # design-system names, not the install's (task 01a1557a stage 4), so
      # they are the only spans allowed to end in the default product name.
      doc = LazyHTML.from_document(html)
      picker_names = spans_ending_in_burrow(doc, "[data-theme-option] span")
      assert picker_names > 0
      assert spans_ending_in_burrow(doc, "span") == picker_names

      assert dm_push_title("Sam") == "Sam in Acme Ops"
    end
  end

  describe "the pure title builder" do
    test "takes the app name as an argument and never compiles one in" do
      alias Platform.Push.Notification

      assert Notification.chat_title("A", nil, :mention, "Fathom") == "A in Fathom"
      assert Notification.chat_title("A", "General", :mention, "Fathom") == "A in General"
      assert Notification.chat_title("A", nil, :here, "Fathom") == "A @here in Fathom"
      assert Notification.chat_title("A", nil, :mention) == "A"
      assert Notification.chat_title(nil, "", :here, nil) == "Someone @here"
    end
  end
end
