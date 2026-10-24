defmodule Platform.Chat.SpaceMemberPresenceTest do
  @moduledoc """
  `Chat.space_member_presence/2`, the Members sheet's People section (task
  01a1557a-8f80 stage 3).

  ONLINE is online anywhere the viewer can see (the per-viewer union of
  `Presence.list_online_for_viewer/1`), or the viewer; AWAY is every other
  user participant. A failed presence read is `{:error, _}` and never a list
  with everybody away.

  `async: false`: the presence tracker is VM-global, and the failure case
  terminates it for real.
  """
  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.Presence, as: ChatPresence
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  defp user!(name) do
    n = System.unique_integer([:positive])

    user =
      %User{}
      |> User.changeset(%{email: "smp-#{n}@example.com", name: name, oidc_sub: "oidc-smp-#{n}"})
      |> Repo.insert!()

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Tenancy.get_org_by_slug!("globex").id,
      role: "member"
    })
    |> Repo.insert!()

    user
  end

  defp channel! do
    {:ok, space} =
      Chat.create_space(%{
        name: "Members",
        slug: "smp-#{System.unique_integer([:positive])}",
        kind: "channel",
        org_id: Tenancy.get_org_by_slug!("globex").id
      })

    space
  end

  defp join!(space, user) do
    {:ok, _} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    :ok
  end

  defp online!(space, user) do
    {:ok, _} =
      ChatPresence.track_in_space(self(), space.id, user.id, %{
        participant_type: "user",
        display_name: user.name
      })

    :ok
  end

  setup do
    viewer = user!("Vera Viewer")
    here = user!("Hana Here")
    elsewhere = user!("Elio Elsewhere")
    away = user!("Abel Away")

    space = channel!()
    for u <- [viewer, here, elsewhere, away], do: join!(space, u)

    # A second space the viewer shares with `elsewhere` only.
    other = channel!()
    for u <- [viewer, elsewhere], do: join!(other, u)

    {:ok, _agent} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: Ecto.UUID.generate(),
        display_name: "Robo",
        joined_at: DateTime.utc_now()
      })

    %{viewer: viewer, here: here, elsewhere: elsewhere, away: away, space: space, other: other}
  end

  test "online here, online in another shared space and the viewer are online; the untracked member is away",
       ctx do
    online!(ctx.space, ctx.here)
    online!(ctx.other, ctx.elsewhere)

    assert {:ok, %{online: online, away: away}} =
             Chat.space_member_presence(ctx.space.id, ctx.viewer)

    # The viewer leads, then by name: "Elio Elsewhere" < "Hana Here".
    assert Enum.map(online, & &1.user_id) == [ctx.viewer.id, ctx.elsewhere.id, ctx.here.id]
    assert Enum.map(away, & &1.user_id) == [ctx.away.id]

    assert [%{you?: true, name: "Vera Viewer"} | rest] = online
    refute Enum.any?(rest ++ away, & &1.you?)
  end

  test "people only: an agent participant is in neither list", ctx do
    assert {:ok, %{online: online, away: away}} =
             Chat.space_member_presence(ctx.space.id, ctx.viewer)

    names = Enum.map(online ++ away, & &1.name)
    # Positive control: the people are there.
    assert "Abel Away" in names
    refute "Robo" in names
    assert length(names) == 4
  end

  test "a presence leave moves the member from online to away", ctx do
    online!(ctx.other, ctx.elsewhere)
    assert {:ok, %{online: online}} = Chat.space_member_presence(ctx.space.id, ctx.viewer)
    assert ctx.elsewhere.id in Enum.map(online, & &1.user_id)

    :ok = ChatPresence.untrack_in_space(self(), ctx.other.id, ctx.elsewhere.id)

    assert {:ok, %{away: away}} = Chat.space_member_presence(ctx.space.id, ctx.viewer)
    assert ctx.elsewhere.id in Enum.map(away, & &1.user_id)
  end

  test "a terminated tracker is {:error, _}, never everybody away", ctx do
    # Positive control on the same fixture: the healthy read answers.
    online!(ctx.space, ctx.here)
    assert {:ok, %{online: [_ | _]}} = Chat.space_member_presence(ctx.space.id, ctx.viewer)

    Process.flag(:trap_exit, true)
    on_exit(&restart_tracker!/0)
    :ok = Supervisor.terminate_child(Platform.Supervisor, ChatPresence)

    {result, log} =
      ExUnit.CaptureLog.with_log(fn -> Chat.space_member_presence(ctx.space.id, ctx.viewer) end)

    assert {:error, _reason} = result
    assert log =~ "presence union read failed"
  end

  defp restart_tracker! do
    case Supervisor.restart_child(Platform.Supervisor, ChatPresence) do
      {:ok, _} -> :ok
      {:ok, _, _} -> :ok
      {:error, :running} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    wait_for_tracker!(100)
  end

  defp wait_for_tracker!(0), do: raise("presence tracker did not come back up")

  defp wait_for_tracker!(attempts) do
    if is_pid(Process.whereis(ChatPresence)) do
      :ok
    else
      :timer.sleep(20)
      wait_for_tracker!(attempts - 1)
    end
  end
end
