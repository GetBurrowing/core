defmodule PlatformWeb.AccessLiveApplyTest do
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Access.{Grants, Live, Scope}
  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.Org
  alias Platform.Tenancy.OrgMembership

  defp user!(name) do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{
      email: "live-access-#{n}@example.com",
      name: name,
      oidc_sub: "live-access-#{n}"
    })
    |> Repo.insert!()
  end

  defp org! do
    n = System.unique_integer([:positive])

    %Org{}
    |> Org.changeset(%{
      name: "Live Access #{n}",
      slug: "live_access_#{n}",
      parent_org_id: Tenancy.get_org_by_slug!("acme").id
    })
    |> Repo.insert!()
  end

  defp channel!(org, name) do
    n = System.unique_integer([:positive])

    {:ok, channel} =
      Chat.create_space(%{name: name, slug: "live-access-#{n}", kind: "channel", org_id: org.id})

    channel
  end

  defp grant!(principal, space) do
    {:ok, grant} =
      Grants.grant(%{principal: principal, permission: "chat.read", resource: {:space, space.id}})

    grant
  end

  defp conn_for(user),
    do:
      build_conn()
      |> Map.put(:host, "chat.localhost")
      |> init_test_session(current_user_id: user.id)

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  setup do
    org = org!()
    guest = user!("Live Guest")
    {:ok, _} = Tenancy.mark_membership_external(%{user_id: guest.id, org_id: org.id})
    Tenancy.allow_dm(guest, org)
    c = channel!(org, "Live Channel C")
    d = channel!(org, "Live Channel D")

    {:ok, _} =
      Chat.add_participant(d.id, %{
        participant_type: "user",
        participant_id: guest.id,
        joined_at: DateTime.utc_now()
      })

    c_grant = grant!(guest, c)
    grant!(guest, d)
    %{org: org, guest: guest, c: c, d: d, c_grant: c_grant}
  end

  test "guest rail drops a revoked channel in the same open view", ctx do
    {:ok, view, html} = conn_for(ctx.guest) |> live("/chat/#{ctx.d.slug}")
    assert html =~ ctx.c.name
    assert html =~ ctx.d.name
    pid = view.pid

    start = System.monotonic_time(:millisecond)
    assert {:ok, _} = Grants.revoke(ctx.c_grant)
    rendered = render(view)
    elapsed = System.monotonic_time(:millisecond) - start

    refute rendered =~ ctx.c.name
    assert rendered =~ ctx.d.name
    assert view.pid == pid
    assert Process.alive?(pid)
    assert elapsed < 2000
  end

  test "active revoked channel navigates to chat with a flash", ctx do
    {:ok, participant} =
      Chat.add_participant(ctx.c.id, %{
        participant_type: "user",
        participant_id: ctx.guest.id,
        joined_at: DateTime.utc_now()
      })

    {:ok, view, _} = conn_for(ctx.guest) |> live("/chat/#{ctx.c.slug}")
    # The HTTP deep-link gate admits a guest through participation, while the
    # explicit grant keeps the already-open tab readable after that admission
    # row is removed. Revoke then changes the rebuilt scope for the active C.
    assert {:ok, _} = Chat.remove_participant(participant)
    assert render(view) =~ ctx.c.name
    assert {:ok, _} = Grants.revoke(ctx.c_grant)

    assert Phoenix.Flash.get(assert_redirect(view, "/chat"), :error) ==
             "You no longer have access to that channel."
  end

  test "a refused change does not broadcast", ctx do
    Live.subscribe(ctx.guest.id)
    other = user!("No Manager")

    assert {:error, %{rule: :not_granted}} =
             Grants.deny(
               %{principal: ctx.guest, permission: "tasks.read", resource: {:space, ctx.c.id}},
               actor: Scope.for_user(other)
             )

    refute_receive {:access_changed, _}, 50
  end

  test "role changes notify the org's guests and skip its members", ctx do
    other_guest = user!("Other Guest")
    {:ok, _} = Tenancy.mark_membership_external(%{user_id: other_guest.id, org_id: ctx.org.id})
    member = user!("Internal Member")

    %OrgMembership{}
    |> OrgMembership.changeset(%{org_id: ctx.org.id, user_id: member.id, role: "member"})
    |> Repo.insert!()

    parent = self()

    probes =
      for user <- [ctx.guest, other_guest, member] do
        spawn(fn ->
          Live.subscribe(user.id)
          send(parent, {:subscribed, user.id})

          receive do
            message -> send(parent, {:probe, user.id, message})
          after
            300 -> send(parent, {:probe_timeout, user.id})
          end
        end)
      end

    for user <- [ctx.guest, other_guest, member] do
      id = user.id
      assert_receive {:subscribed, ^id}
    end

    assert {:ok, _} =
             Grants.deny(%{
               principal: {:role, "guest"},
               permission: "chat.read",
               resource: {:space, ctx.c.id}
             })

    guest_id = ctx.guest.id
    other_guest_id = other_guest.id
    member_id = member.id
    assert_receive {:probe, ^guest_id, {:access_changed, _}}
    assert_receive {:probe, ^other_guest_id, {:access_changed, _}}
    assert_receive {:probe_timeout, ^member_id}, 500
    Enum.each(probes, &Process.exit(&1, :normal))
  end

  test "an agent principal has no user topic", ctx do
    Live.subscribe(ctx.guest.id)

    assert {:ok, _} =
             Grants.grant(%{
               principal: {:agent, Ecto.UUID.generate()},
               permission: "chat.read",
               resource: {:space, ctx.c.id}
             })

    refute_receive {:access_changed, _}, 50
  end

  test "an internal member's channel deny removes the row live", ctx do
    member = user!("Internal Reader")

    %OrgMembership{}
    |> OrgMembership.changeset(%{org_id: ctx.org.id, user_id: member.id, role: "member"})
    |> Repo.insert!()

    {:ok, view, html} =
      build_conn() |> init_test_session(current_user_id: member.id) |> live("/chat/#{ctx.d.slug}")

    assert html =~ ctx.c.name

    assert {:ok, _} =
             Grants.deny(%{
               principal: member,
               permission: "chat.read",
               resource: {:space, ctx.c.id}
             })

    refute render(view) =~ ctx.c.name
    assert render(view) =~ ctx.d.name
  end

  test "tasks view handles access invalidation in place", ctx do
    member = user!("Task Reader")

    %OrgMembership{}
    |> OrgMembership.changeset(%{org_id: ctx.org.id, user_id: member.id, role: "member"})
    |> Repo.insert!()

    {:ok, view, _} =
      build_conn() |> init_test_session(current_user_id: member.id) |> live("/tasks")

    pid = view.pid
    send(pid, {:access_changed, Ecto.UUID.generate()})
    assert is_binary(render(view))
    assert Process.alive?(pid)
    assert assigns(view).access_scope.actor.id == member.id
  end
end
