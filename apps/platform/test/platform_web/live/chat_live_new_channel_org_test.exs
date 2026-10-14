defmodule PlatformWeb.ChatLiveNewChannelOrgTest do
  @moduledoc """
  The "+ New channel" dialog files the channel into an ORG (task 01a00910
  stage 5).

  Before this, `NewChannelComponent` called `Chat.create_channel/1` with no
  `org_id` and the dialog had no org control at all — so the control could
  never create an org-scoped channel, and the org-less row it did create was
  then DUPLICATED by ChatLive's org-scoped mount lookup.

  Every assertion here counts rows in `chat_spaces` and reads `org_id` off
  them. `Repo.insert` returns a struct whether or not the row you meant was
  written, so the struct is not the evidence.
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat.Space
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  defp create_user!(suffix) do
    Repo.insert!(%User{
      email: "new_chan_org_#{suffix}@example.com",
      name: "New Chan Org #{suffix}",
      oidc_sub: "oidc-new-chan-org-#{suffix}"
    })
  end

  defp membership!(user, org) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: "member"})
    |> Repo.insert!()
  end

  defp rows_for(slug), do: Repo.all(from(s in Space, where: s.slug == ^slug))

  defp open_dialog(conn) do
    {:ok, view, _html} = live(conn, ~p"/chat")
    render_click(view, "new_channel_open", %{})
    view
  end

  defp submit(view, params) do
    view
    |> element("#chat-new-channel form")
    |> render_submit(params)
  catch
    # The successful path `push_navigate`s to the new channel; LiveViewTest
    # raises that redirect out of `render_submit`. The row is what we assert.
    :throw, {:error, {:live_redirect, _}} -> :redirected
  end

  describe "the dialog's org destination" do
    test "defaults to the mounting user's active org", %{conn: conn} do
      user = create_user!("default")
      acme = Tenancy.get_org_by_slug!("acme")
      membership!(user, acme)

      conn = init_test_session(conn, current_user_id: user.id)
      view = open_dialog(conn)

      html = render(view)
      assert html =~ ~s(name="org_id")

      submit(view, %{"name" => "Default Org Chan", "description" => "", "org_id" => acme.id})

      assert [%Space{org_id: org_id}] = rows_for("default-org-chan")
      assert org_id == acme.id
    end

    test "creating into SXI yields exactly one row, filed to SXI", %{conn: conn} do
      user = create_user!("sxi")
      sxi = Tenancy.get_org_by_slug!("sxi")
      membership!(user, sxi)

      conn = init_test_session(conn, current_user_id: user.id)
      view = open_dialog(conn)

      submit(view, %{"name" => "Livechan One", "description" => "", "org_id" => sxi.id})

      rows = rows_for("livechan-one")
      assert length(rows) == 1
      assert [%Space{org_id: org_id}] = rows
      assert org_id == sxi.id
    end

    test "an org the viewer cannot see is refused and falls back to the active org",
         %{conn: conn} do
      user = create_user!("forged")
      acme = Tenancy.get_org_by_slug!("acme")
      sxi = Tenancy.get_org_by_slug!("sxi")
      membership!(user, acme)

      conn = init_test_session(conn, current_user_id: user.id)
      view = open_dialog(conn)

      # A forged select value naming an org this (non-admin) member has no
      # membership in. The server-built option list is the authority.
      submit(view, %{"name" => "Forged Dest Chan", "description" => "", "org_id" => sxi.id})

      assert [%Space{org_id: org_id}] = rows_for("forged-dest-chan")
      refute org_id == sxi.id
      assert org_id == acme.id
    end
  end

  # Task 01a0fd62-a7ef-7001-8477-bd17e47bbaca stage 1. Before this the dialog
  # never stamped `created_by`, so the creator's only row came from
  # `ensure_participant/2` on first navigation, with the default `member` role.
  describe "the dialog's creator" do
    test "is seated once, as admin, and navigation adds no second row", %{conn: conn} do
      user = create_user!("creator-admin")
      acme = Tenancy.get_org_by_slug!("acme")
      membership!(user, acme)

      conn = init_test_session(conn, current_user_id: user.id)
      view = open_dialog(conn)

      submit(view, %{"name" => "Creator Admin Chan", "description" => ""})

      # The dialog asks the parent to navigate (`{:new_channel_navigate, path}`),
      # so the redirect surfaces on the view, not out of `render_submit`.
      {to, _flash} = assert_redirect(view)

      assert [%Space{id: space_id, created_by: created_by}] = rows_for("creator-admin-chan")
      assert created_by == user.id

      # Follow the navigation the dialog requested: this is where
      # `ensure_participant/2` would have inserted a second, member row.
      {:ok, _view, _html} = live(conn, to)

      rows =
        Repo.all(
          from(p in Platform.Chat.Participant,
            where:
              p.space_id == ^space_id and p.participant_type == "user" and
                p.participant_id == ^user.id
          )
        )

      assert [%{role: "admin"}] = rows
    end
  end
end
