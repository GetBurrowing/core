defmodule PlatformWeb.ChatLiveWelcomeEmptyStateTest do
  @moduledoc """
  The brand-new-user "Welcome to Burrow" empty state vs archived channels
  (task 019f4eaa).

  Robin, walking the review: after archiving her orgs, the chat sidebar showed
  "— no spaces yet — / Welcome to Suite. To get started, create a space or
  connect your agent." rendered DIRECTLY ABOVE the ARCHIVED section. The block
  keyed only on `@channels == [] and @dm_conversations == []`, which cannot
  tell a brand-new user from an admin who just archived everything.

  Org-archive is what made it trivial to hit: it empties every channel in an
  org in one click. Having archived channels is proof you are NOT new, so the
  render test now also requires `@archived_channels == []`.

  Both directions matter — the welcome must still appear for a genuinely new
  user, or fixing this would just break onboarding instead.

  Burrow redesign 22 stage 2 deleted the desktop channel rail, and with it the
  only render site of the "Welcome to Burrow." block. The Chat list's own empty
  state (`[data-role="chat-list-empty"]`) is the brand-new-user surface now,
  so this file pins the same two directions on the list: empty for a new user,
  and an archived channel still reachable (never a dead "no channels" end)
  for someone who archived everything.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  @welcome "Welcome to Burrow."

  defp admin_conn(conn) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "welcome-empty-#{n}@example.com",
        name: "Welcome Empty #{n}",
        oidc_sub: "oidc-welcome-empty-#{n}",
        preferences: %{"first_run_goal" => "existing"}
      })

    acme = Tenancy.get_org_by_slug!("acme")

    case Repo.get_by(OrgMembership, user_id: user.id, org_id: acme.id) do
      nil ->
        %OrgMembership{}
        |> OrgMembership.changeset(%{user_id: user.id, org_id: acme.id, role: "admin"})
        |> Repo.insert!()

      existing ->
        existing |> Ecto.Changeset.change(%{role: "admin"}) |> Repo.update!()
    end

    {init_test_session(conn, current_user_id: user.id), user}
  end

  defp channel!(org_slug) do
    n = System.unique_integer([:positive, :monotonic])
    org = Tenancy.get_org_by_slug!(org_slug)

    {:ok, space} =
      Chat.create_space(%{
        name: "Chan #{n}",
        slug: "welcome-chan-#{n}",
        kind: "channel",
        org_id: org.id
      })

    space
  end

  # `/chat` live-redirects to the first ACTIVE channel when one exists, so a
  # bare live/2 returns {:error, {:live_redirect, ...}} rather than a view.
  # Follow it — the Chat list renders on both routes.
  defp mount_chat(conn) do
    case live(conn, ~p"/chat") do
      {:ok, view, _html} -> view
      {:error, {:live_redirect, %{to: path}}} -> live(conn, path) |> elem(1)
    end
  end

  @empty ~s(#chat-list [data-role="chat-list-empty"])

  defp list_row?(view, space),
    do:
      has_element?(
        view,
        ~s(#chat-list-scroller a[data-role="chat-list-row"][data-space-id="#{space.id}"])
      )

  defp show_archived(view) do
    render_click(view, "toggle_archived_section", %{})
    view
  end

  describe "the brand-new-user empty state (Chat list)" do
    test "still shows for a genuinely new user — no channels, no DMs, nothing archived",
         %{conn: conn} do
      {conn, _user} = admin_conn(conn)

      view = mount_chat(conn)

      assert has_element?(view, @empty)
      assert has_element?(view, ~s([data-role="chat-list-empty-new-channel"]))

      # Nothing archived either: showing archived adds no section.
      show_archived(view)
      assert has_element?(view, @empty)
      refute has_element?(view, ~s(#chat-list [data-role="chat-list-archived"]))
    end

    test "an archived channel stays reachable — an archive proves you're not new",
         %{conn: conn} do
      {conn, admin} = admin_conn(conn)
      space = channel!("hooli")

      # Active channel: a list row, no empty state.
      view = mount_chat(conn)
      assert list_row?(view, space)
      refute has_element?(view, @empty)

      # Archive it — @channels goes empty, but @archived_channels does not.
      {:ok, _} = Chat.archive_space(admin, space)

      view = conn |> mount_chat() |> show_archived()

      assert has_element?(view, ~s(#chat-list [data-role="chat-list-archived"])),
             "with everything archived, Show archived must still reveal the Archived section"

      assert list_row?(view, space)
    end

    test "restoring the channel puts it back in the list — there IS a space again",
         %{conn: conn} do
      {conn, admin} = admin_conn(conn)
      space = channel!("hooli")
      {:ok, archived} = Chat.archive_space(admin, space)

      {:ok, _} = Chat.unarchive_space(admin, archived)

      view = mount_chat(conn)
      assert list_row?(view, space)
      refute has_element?(view, @empty)
    end
  end
end
