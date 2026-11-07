defmodule PlatformWeb.AdminUpdatesLiveTest do
  @moduledoc """
  `/admin/updates` (task 01a1b7b6 stage 3): the root admin's toggle, Update
  now and last result, over `Platform.Updates`' tmp inbox and status file.
  The view re-checks root admin on mount and on every event.
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Platform.InsightFixtures, only: [person!: 1]
  import Platform.TenancyFixtures
  import Platform.UpdaterFixtures

  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership

  setup :setup_updater_dirs

  defp conn_for(conn, user), do: init_test_session(conn, %{"current_user_id" => user.id})

  defp inbox(core), do: core |> Path.join("inbox") |> File.ls!() |> Enum.sort()

  defp read_inbox(core, name),
    do: core |> Path.join("inbox") |> Path.join(name) |> File.read!() |> Jason.decode!()

  defp mount_root(ctx) do
    {:ok, view, _html} = ctx.conn |> conn_for(root_admin!()) |> live(~p"/admin/updates")
    view
  end

  test "the normal state: one toggle, the channel as text, Update now, the last result", ctx do
    write_status!(ctx.status_path)
    view = mount_root(ctx)

    assert has_element?(view, ~s([data-role="updates-channel"]), "stable")
    assert has_element?(view, ~s([data-role="updates-meta"]), "running 061fbe1")

    assert has_element?(
             view,
             ~s(input[type="checkbox"][data-role="updates-auto-update"][checked])
           )

    assert view
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.query(~s(input[type="checkbox"]))
           |> Enum.count() == 1

    assert has_element?(
             view,
             ~s{button[data-role="updates-update-now"]:not([disabled])},
             "Update now"
           )

    assert has_element?(view, ~s(button[data-role="updates-update-now"].btn-primary))
    assert has_element?(view, ~s([data-role="updates-last-result"][data-result="ok"]), "updated")
    assert has_element?(view, ~s([data-role="updates-last-result"]), "2026-11-07T20:00 UTC")
    # The channel is host config: there is no control for it.
    refute has_element?(view, ~s(select))
    refute has_element?(view, ~s([data-role="updates-not-installed"]))
  end

  test "the root admin's toggle writes settings.json", ctx do
    write_status!(ctx.status_path)
    view = mount_root(ctx)

    view |> form("#admin-updates-form", updates: %{auto_update: "false"}) |> render_change()
    assert read_inbox(ctx.core_dir, "settings.json") == %{"auto_update" => false}
    refute has_element?(view, ~s([data-role="updates-auto-update"][checked]))
    assert has_element?(view, ~s([data-role="updates-auto-note"]), "Saved.")

    view |> form("#admin-updates-form", updates: %{auto_update: "true"}) |> render_change()
    assert read_inbox(ctx.core_dir, "settings.json") == %{"auto_update" => true}
  end

  test "Update now writes request.json with action update", ctx do
    write_status!(ctx.status_path)
    view = mount_root(ctx)

    view |> element(~s(button[data-role="updates-update-now"])) |> render_click()

    body = read_inbox(ctx.core_dir, "request.json")
    assert body["action"] == "update"
    assert Map.keys(body) |> Enum.sort() == ["action", "request_id", "requested_at"]
    assert has_element?(view, ~s([data-role="updates-requested"]))
  end

  test "a non-admin cannot mount the page", ctx do
    write_status!(ctx.status_path)

    assert {:error, {_, %{to: "/access-denied?module=admin"}}} =
             ctx.conn |> conn_for(person!("member")) |> live(~p"/admin/updates")
  end

  test "an admin-module holder who is not root admin is sent away on mount", ctx do
    write_status!(ctx.status_path)
    user = root_admin!()
    demote!(user)

    # Still holds the admin module through another grant? Either gate refuses.
    assert {:error, {_, %{to: to}}} = ctx.conn |> conn_for(user) |> live(~p"/admin/updates")
    assert to in ["/admin", "/access-denied?module=admin"]
    assert inbox(ctx.core_dir) == []
  end

  test "a forged event from a user who is no longer root admin writes nothing", ctx do
    write_status!(ctx.status_path)
    user = root_admin!()
    {:ok, view, _html} = ctx.conn |> conn_for(user) |> live(~p"/admin/updates")
    demote!(user)

    html = render_click(view, "update_now", %{})
    assert html =~ "Only this install&#39;s root admin can manage updates."

    render_click(view, "set_auto_update", %{"updates" => %{"auto_update" => "false"}})
    render_click(view, "unknown_event", %{})

    assert inbox(ctx.core_dir) == []
    assert File.ls!(Path.join(ctx.core_dir, "staging")) == []
  end

  test "pinned disables Update now and says so", ctx do
    write_status!(ctx.status_path, %{"channel" => "pinned", "last_result" => "pinned"})
    view = mount_root(ctx)

    assert has_element?(view, ~s(button[data-role="updates-update-now"][disabled]))

    assert has_element?(
             view,
             ~s([data-role="updates-pinned"]),
             "Pinned: this server does not move."
           )

    # A forged click on the disabled button writes nothing.
    render_click(view, "update_now", %{})
    assert inbox(ctx.core_dir) == []
  end

  test "not installed: says so, points at the docs, no controls", ctx do
    view = mount_root(ctx)

    assert has_element?(
             view,
             ~s([data-role="updates-not-installed"]),
             "The updater isn't installed on this server yet"
           )

    assert has_element?(view, ~s([data-role="updates-not-installed"]), "installs.md")
    refute has_element?(view, ~s(button))
    refute has_element?(view, ~s(input))
    refute has_element?(view, ~s(form))
  end

  test "deferred: the waiting line with its since time; Update now stays enabled", ctx do
    write_status!(ctx.status_path, %{
      "last_result" => "deferred_meeting_live",
      "deferred_since" => "2026-11-07T19:42:00Z"
    })

    view = mount_root(ctx)

    assert has_element?(view, ~s([data-role="updates-deferred"]), "Waiting: a meeting is live")
    assert has_element?(view, ~s([data-role="updates-deferred"]), "2026-11-07T19:42 UTC")

    assert has_element?(
             view,
             ~s([data-role="updates-deferred"]),
             "Starts when the live meeting ends."
           )

    assert has_element?(view, ~s{button[data-role="updates-update-now"]:not([disabled])})
  end

  test "held_irreversible: the confirm text is on Update now", ctx do
    write_status!(ctx.status_path, %{
      "last_result" => "held_irreversible",
      "pending_irreversible" => ["20261201000000"]
    })

    view = mount_root(ctx)

    assert has_element?(
             view,
             ~s([data-role="updates-held"]),
             "This release can't be rolled back automatically."
           )

    assert has_element?(
             view,
             ~s(button[data-role="updates-update-now"][data-confirm*="This release can't be rolled back automatically."])
           )
  end

  test "a rollback is a warning line, never red; a failure always carries its reason", ctx do
    write_status!(ctx.status_path, %{
      "last_result" => "rolled_back",
      "last_rollback" => %{
        "at" => "2026-11-07T03:10:00Z",
        "from" => "913287c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6",
        "to" => "061fbe1d2c3b4a5968778695a4b3c2d1e0f9a8b7"
      }
    })

    view = mount_root(ctx)
    assert has_element?(view, ~s([data-role="updates-last-rollback"]), "913287c → 061fbe1")
    assert has_element?(view, ~s([data-role="updates-last-rollback"] .text-warning))
    refute has_element?(view, ~s([data-role="updates-card"] .text-error))

    write_status!(ctx.status_path, %{"last_result" => "failed_rollback_blocked"})
    send(view.pid, :refresh)

    assert has_element?(
             view,
             ~s([data-role="updates-last-result"] .text-error),
             "update failed · rollback blocked by migration"
           )
  end

  test "the page re-reads status.json on refresh", ctx do
    write_status!(ctx.status_path, %{
      "last_result" => "checked",
      "available" => %{"digest" => "x"}
    })

    view = mount_root(ctx)

    assert has_element?(
             view,
             ~s([data-role="updates-headline"]),
             "A newer stable release is ready."
           )

    write_status!(ctx.status_path, %{"last_result" => "up_to_date", "auto_update" => false})
    send(view.pid, :refresh)

    assert has_element?(
             view,
             ~s([data-role="updates-headline"]),
             "You are on the latest stable release."
           )

    refute has_element?(view, ~s([data-role="updates-auto-update"][checked]))
  end

  test "the admin index links here", ctx do
    {:ok, view, _html} = ctx.conn |> conn_for(root_admin!()) |> live(~p"/admin")
    assert has_element?(view, ~s(a[data-role="admin-updates-link"][href="/admin/updates"]))
  end

  defp demote!(user) do
    from(m in OrgMembership, where: m.user_id == ^user.id)
    |> Repo.update_all(set: [role: "member"])
  end
end
