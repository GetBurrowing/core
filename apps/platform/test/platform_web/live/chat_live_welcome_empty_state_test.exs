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
        oidc_sub: "oidc-welcome-empty-#{n}"
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
  # Follow it — the sidebar (and therefore the welcome block) renders either
  # way, and that's what we're asserting on.
  defp mount_chat(conn) do
    case live(conn, ~p"/chat") do
      {:ok, _view, html} -> html
      {:error, {:live_redirect, %{to: path}}} -> live(conn, path) |> elem(2)
    end
  end

  describe "\"Welcome to Suite\" empty state" do
    test "still shows for a genuinely new user — no channels, no DMs, nothing archived",
         %{conn: conn} do
      {conn, _user} = admin_conn(conn)

      {:ok, _view, html} = live(conn, ~p"/chat")

      assert html =~ @welcome
      assert html =~ "— no spaces yet —"
    end

    test "does NOT show once a channel is archived — an archive proves you're not new",
         %{conn: conn} do
      {conn, admin} = admin_conn(conn)
      space = channel!("paragon")

      # Active channel: no welcome (there are spaces).
      refute mount_chat(conn) =~ @welcome

      # Archive it — @channels goes empty, but @archived_channels does not.
      {:ok, _} = Chat.archive_space(admin, space)

      refute mount_chat(conn) =~ @welcome,
             "the brand-new-user welcome must not render above an ARCHIVED section"
    end

    test "does NOT show when an ORG archive cascade-hides the only channel",
         %{conn: conn} do
      # Robin's exact path: archive the org, not the channel.
      {conn, admin} = admin_conn(conn)
      _space = channel!("paragon")

      {:ok, _} = Tenancy.archive_org(admin, Tenancy.get_org_by_slug!("paragon"))

      refute mount_chat(conn) =~ @welcome
    end

    test "restoring the channel leaves the welcome hidden — there IS a space again",
         %{conn: conn} do
      {conn, admin} = admin_conn(conn)
      space = channel!("paragon")
      {:ok, archived} = Chat.archive_space(admin, space)

      refute mount_chat(conn) =~ @welcome

      # Unarchived -> an active channel again, so still no welcome. The welcome
      # is only for having NOTHING at all, active or archived.
      {:ok, _} = Chat.unarchive_space(admin, archived)

      refute mount_chat(conn) =~ @welcome
    end
  end
end
