defmodule Platform.Tasks.SponsorAssignedInboxTest do
  @moduledoc """
  Behavioral matrix for the M4 (task 019f9251) `task_sponsor_assigned` inbox
  producer wired into `Platform.Tasks` — the create + update write seams, the
  self-sponsor exclusion, and the VAPID push fan-out.

  Push is asserted via a Recorder double injected through the
  `:notifications_module` app env (mirroring
  `Platform.Meetings.MeetingNotifierTest.Recorder`): `fan_out_to_user/3` is
  captured as `{:notif, user_id, payload, opts}` so a push-expected case can
  `assert_receive` and a no-push case can `refute_receive`. The producer now
  targets the sponsor by *user id* (endpoint-dedup happens inside
  `Platform.Push.send_to_user/2`), not by a pre-resolved participant-row list.
  `async: false` because the test swaps `Application` env.
  """

  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Inbox
  alias Platform.Repo
  alias Platform.Tasks

  @kind "task_sponsor_assigned"

  defmodule Recorder do
    @moduledoc """
    Test double for `Platform.Notifications`. Records each `fan_out_to_user/3`
    call as `{:notif, user_id, payload, opts}`.
    """
    def install(pid \\ self()) do
      :persistent_term.put({__MODULE__, :owner}, pid)
    end

    def fan_out_to_user(user_id, payload, opts \\ []) do
      case :persistent_term.get({__MODULE__, :owner}, nil) do
        nil -> :ok
        owner -> send(owner, {:notif, user_id, payload, opts})
      end

      :ok
    end
  end

  setup do
    Application.put_env(:platform, :notifications_module, Recorder)
    Recorder.install(self())

    on_exit(fn -> Application.delete_env(:platform, :notifications_module) end)

    {:ok, project} = Tasks.create_project(%{name: "Proj #{uniq()}"})
    %{project: project}
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp uniq, do: System.unique_integer([:positive])

  defp insert_user do
    n = uniq()

    Repo.insert!(%Platform.Accounts.User{
      name: "Sponsor #{n}",
      email: "sponsor-#{n}@example.com",
      oidc_sub: "sub-sponsor-#{n}"
    })
  end

  # Give a user a user-typed chat_participants row (a realistic push target).
  # Endpoint-dedup resolution now lives in `Platform.Push.send_to_user/2`; the
  # Recorder double captures the user-targeted call, so this row exists mainly
  # to make the fixture realistic. Returns the participant ROW id.
  defp push_target!(user) do
    n = System.unique_integer([:positive, :monotonic])
    {:ok, space} = Chat.create_space(%{name: "Space #{n}", slug: "sp-#{n}", kind: "channel"})

    {:ok, p} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        joined_at: DateTime.utc_now()
      })

    p.id
  end

  defp rows_for(user_id), do: Inbox.list_unread_for_user(user_id, kind: @kind)

  # ── Case 1: create_task with a sponsor + long description ────────────────────

  test "create_task with a sponsor emits ONE row + push with correct fields", %{
    project: project
  } do
    sponsor = insert_user()
    _participant_id = push_target!(sponsor)
    desc = String.duplicate("A", 150) <> String.duplicate("B", 100)

    {:ok, task} =
      Tasks.create_task(
        %{
          project_id: project.id,
          title: "Ship the thing",
          sponsor_user_id: sponsor.id,
          description: desc
        },
        actor: {:agent, Ecto.UUID.generate()}
      )

    # Inbox row correctness (spot-check subsumes case 8).
    assert [item] = rows_for(sponsor.id)
    assert item.user_id == sponsor.id
    assert item.kind == @kind
    assert item.source_type == "task"
    assert item.source_id == task.id
    assert item.title == "You're now sponsoring: Ship the thing"
    assert item.url == "/tasks/#{task.id}"
    assert item.body == String.slice(desc, 0, 200)
    assert String.length(item.body) == 200

    # Push fan-out invoked once, targeting the sponsor by user id, with a
    # payload matching the row.
    assert_receive {:notif, target_user_id, payload, _opts}
    assert target_user_id == sponsor.id
    assert payload == %{title: item.title, body: item.body, url: item.url}
    refute_receive {:notif, _, _, _}
  end

  # ── Case 2: update nil → user ────────────────────────────────────────────────

  test "update_task nil→user emits one row + push", %{project: project} do
    sponsor = insert_user()
    _participant_id = push_target!(sponsor)
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "T"})

    {:ok, updated} =
      Tasks.update_task(task, %{sponsor_user_id: sponsor.id},
        actor: {:agent, Ecto.UUID.generate()}
      )

    assert updated.sponsor_user_id == sponsor.id
    assert [item] = rows_for(sponsor.id)
    assert item.source_id == task.id
    assert_receive {:notif, target_user_id, %{title: _, body: _, url: _}, _}
    assert target_user_id == sponsor.id
    refute_receive {:notif, _, _, _}
  end

  # ── Case 3: update userA → userB ─────────────────────────────────────────────

  test "update_task userA→userB emits for B only, no new row for A", %{project: project} do
    user_a = insert_user()
    user_b = insert_user()
    _pa = push_target!(user_a)
    _pb = push_target!(user_b)

    # Create already sponsored by A — drain A's create push + row.
    {:ok, task} =
      Tasks.create_task(%{project_id: project.id, title: "T", sponsor_user_id: user_a.id})

    assert_receive {:notif, _, _, _}
    assert [_a_row] = rows_for(user_a.id)

    {:ok, updated} =
      Tasks.update_task(task, %{sponsor_user_id: user_b.id},
        actor: {:agent, Ecto.UUID.generate()}
      )

    assert updated.sponsor_user_id == user_b.id
    # B gets exactly one row + push; A gets no NEW row.
    assert [b_row] = rows_for(user_b.id)
    assert b_row.source_id == task.id
    assert_receive {:notif, target_user_id, _payload, _}
    assert target_user_id == user_b.id
    refute_receive {:notif, _, _, _}
    assert length(rows_for(user_a.id)) == 1
  end

  # ── Case 4: self-sponsor exclusion ───────────────────────────────────────────

  test "self-sponsor (actor == new sponsor) emits NO row + NO push, write still succeeds", %{
    project: project
  } do
    user = insert_user()
    _p = push_target!(user)
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "T"})

    {:ok, updated} =
      Tasks.update_task(task, %{sponsor_user_id: user.id}, actor: {:user, user.id})

    assert updated.sponsor_user_id == user.id
    assert rows_for(user.id) == []
    refute_receive {:notif, _, _, _}
  end

  # ── Case 5: unrelated-field update ───────────────────────────────────────────

  test "unrelated update (sponsor unchanged) emits NO row + NO push", %{project: project} do
    sponsor = insert_user()
    _p = push_target!(sponsor)

    {:ok, task} =
      Tasks.create_task(%{project_id: project.id, title: "T", sponsor_user_id: sponsor.id})

    assert_receive {:notif, _, _, _}
    assert [_one] = rows_for(sponsor.id)

    {:ok, _updated} =
      Tasks.update_task(task, %{title: "New title"}, actor: {:agent, Ecto.UUID.generate()})

    refute_receive {:notif, _, _, _}
    assert length(rows_for(sponsor.id)) == 1
  end

  # ── Case 6: clear sponsor user → nil ─────────────────────────────────────────

  test "clearing sponsor (user→nil) emits NO row + NO push, clear persists", %{project: project} do
    sponsor = insert_user()
    _p = push_target!(sponsor)

    {:ok, task} =
      Tasks.create_task(%{project_id: project.id, title: "T", sponsor_user_id: sponsor.id})

    assert_receive {:notif, _, _, _}

    {:ok, updated} =
      Tasks.update_task(task, %{sponsor_user_id: nil}, actor: {:agent, Ecto.UUID.generate()})

    assert is_nil(updated.sponsor_user_id)
    refute_receive {:notif, _, _, _}
    # No NEW row from the clear (the create's row is unaffected).
    assert length(rows_for(sponsor.id)) == 1
  end

  # ── Case 7: no-op re-set of the SAME sponsor ─────────────────────────────────

  test "re-setting the same sponsor (no change) emits NO row + NO push", %{project: project} do
    sponsor = insert_user()
    _p = push_target!(sponsor)

    {:ok, task} =
      Tasks.create_task(%{project_id: project.id, title: "T", sponsor_user_id: sponsor.id})

    assert_receive {:notif, _, _, _}

    {:ok, _updated} =
      Tasks.update_task(task, %{sponsor_user_id: sponsor.id},
        actor: {:agent, Ecto.UUID.generate()}
      )

    refute_receive {:notif, _, _, _}
    assert length(rows_for(sponsor.id)) == 1
  end
end
