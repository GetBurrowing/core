defmodule PlatformWeb.GuestLiveRedirectTasksTest do
  @moduledoc """
  Guest bug 01a13b84 (task 01a14721 stage 1): a guest who is already inside
  the `:authenticated` live_session on the APP host (their own `/chat/<slug>`)
  must not reach `/tasks` by a client-side `live_redirect`, which re-mounts
  without passing back through the HTTP plugs.

  The refusal is `PlatformWeb.ModuleGate` in the `:authenticated` on_mount
  list: `Access.module_access?(guest, :tasks)` is false. Mutation P-guest
  (remove `{PlatformWeb.ModuleGate, :default}` from that list) must turn this
  test red; before this file no test asserted it (journal 2026-10-15, the P2
  coverage finding).
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task
  alias Platform.Tenancy
  alias Platform.Tenancy.Org

  defp user!(name) do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{email: "glr-#{n}@example.com", name: name, oidc_sub: "oidc-glr-#{n}"})
    |> Repo.insert!()
  end

  setup do
    n = System.unique_integer([:positive])

    org =
      %Org{}
      |> Org.changeset(%{
        name: "Guest Redirect #{n}",
        slug: "guest_redirect_#{n}",
        parent_org_id: Tenancy.get_org_by_slug!("acme").id
      })
      |> Repo.insert!()

    guest = user!("Gwen Guest")
    {:ok, _} = Tenancy.mark_membership_external(%{user_id: guest.id, org_id: org.id})

    {:ok, room} =
      Chat.create_space(%{
        name: "Guest Room #{n}",
        slug: "glr-#{n}",
        kind: "channel",
        org_id: org.id
      })

    {:ok, _} =
      Chat.add_participant(room.id, %{
        participant_type: "user",
        participant_id: guest.id,
        joined_at: DateTime.utc_now()
      })

    {:ok, project} = Tasks.create_project(%{name: "Guest Redirect P #{n}", org_id: org.id})

    task =
      Repo.insert!(%Task{
        project_id: project.id,
        title: "Guest redirect secret task #{n}",
        status: "backlog"
      })

    %{guest: guest, room: room, task: task}
  end

  test "a guest's live_redirect from their chat to /tasks is refused by the module gate", ctx do
    conn = build_conn() |> init_test_session(current_user_id: ctx.guest.id)

    {:ok, view, html} = live(conn, "/chat/#{ctx.room.slug}")
    refute html =~ ctx.task.title

    refute render(view) =~ ctx.task.title

    # The redirect tuple carries no rendered page: the mount halted before
    # TasksLive rendered anything.
    assert {:error, {:redirect, %{to: "/access-denied?module=tasks"} = redirect}} =
             live_redirect(view, to: "/tasks")

    refute inspect(redirect) =~ ctx.task.title
  end

  test "positive control: an internal member's live_redirect to /tasks mounts the board", ctx do
    member = user!("Ivy Internal")

    %Platform.Tenancy.OrgMembership{}
    |> Platform.Tenancy.OrgMembership.changeset(%{
      user_id: member.id,
      org_id: Tenancy.get_org_by_slug!("acme").id,
      role: "member"
    })
    |> Repo.insert!()

    {:ok, home} =
      Chat.create_space(%{name: "Member Home", slug: "glr-home-#{ctx.task.id}", kind: "channel"})

    conn = build_conn() |> init_test_session(current_user_id: member.id)
    {:ok, view, _} = live(conn, "/chat/#{home.slug}")

    assert {:ok, tasks_view, _html} = live_redirect(view, to: "/tasks")
    assert render(tasks_view) =~ ctx.task.title
  end
end
