defmodule PlatformWeb.ChatLiveAccessScopeGuestTest do
  @moduledoc """
  The ExternalScope switch hazard guard (task 01a1386d-e528 stage 3,
  `0058-rbac-v2-roles-scopes-and-agent-capping.md § Permission model`).

  ChatLive's read-scope is LiveAuth's `%Platform.Access.Scope{}` since this
  stage. A Scope never matches `%ExternalScope{external?: true}`, so a guest
  flag derived by that struct match reads every guest as internal and hands
  them the unscoped archived-channel list. `PlatformWeb.ChatLive.ReadScope`
  asks `Platform.Access.Scope.guest?/1` instead.

  The guard below was written failing-first: with `ReadScope.guest?/1`'s
  Scope clause replaced by `match?(%ExternalScope{external?: true}, scope)`,
  "a guest's mount holds ZERO archived channels while an internal user's
  holds them" fails (recorded in the stage report).
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Access.Grants
  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.Org

  defp with_chat_host(conn), do: %{conn | host: "chat.localhost"}
  defp authed(conn, user), do: init_test_session(conn, current_user_id: user.id)

  defp user!(name) do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{email: "asg-#{n}@example.com", name: name, oidc_sub: "oidc-asg-#{n}"})
    |> Repo.insert!()
  end

  defp tenant_org! do
    n = System.unique_integer([:positive])

    %Org{}
    |> Org.changeset(%{
      name: "Tenant #{n}",
      slug: "tenant_asg_#{n}",
      parent_org_id: Tenancy.get_org_by_slug!("acme").id
    })
    |> Repo.insert!()
  end

  defp channel!(name, opts \\ []) do
    n = System.unique_integer([:positive])
    attrs = Map.merge(%{name: name, slug: "asg-ch-#{n}", kind: "channel"}, Map.new(opts))
    {:ok, ch} = Chat.create_space(attrs)
    ch
  end

  defp join!(channel, user) do
    {:ok, _} =
      Chat.add_participant(channel.id, %{
        participant_type: "user",
        participant_id: user.id,
        joined_at: DateTime.utc_now()
      })

    channel
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  setup do
    org = tenant_org!()
    guest = user!("Gale Guest")
    {:ok, _} = Tenancy.mark_membership_external(%{user_id: guest.id, org_id: org.id})
    allowed = channel!("Guest Allowed Room", org_id: org.id) |> join!(guest)
    {:ok, archived} = Chat.archive_space(channel!("Retired Archive Room"))
    %{org: org, guest: guest, allowed: allowed, archived: archived}
  end

  test "a guest's mount holds ZERO archived channels while an internal user's holds them", ctx do
    {:ok, view, html} =
      build_conn() |> with_chat_host() |> authed(ctx.guest) |> live("/chat/#{ctx.allowed.slug}")

    a = assigns(view)

    # Precondition: the read-scope IS the Access Scope (the switch this
    # guard exists for happened), and it is a guest's.
    assert %Platform.Access.Scope{} = a.external_scope
    assert Platform.Access.Scope.guest?(a.external_scope)

    assert a.external? == true
    assert a.archived_channels == []
    refute html =~ ctx.archived.name

    # Positive control: the same archived channel IS delivered to an
    # internal user, through the same mount.
    internal = user!("Ivo Internal")
    home = channel!("Internal Home Room") |> join!(internal)
    {:ok, int_view, _} = build_conn() |> authed(internal) |> live("/chat/#{home.slug}")
    int = assigns(int_view)

    assert %Platform.Access.Scope{} = int.external_scope
    assert int.external? == false
    assert ctx.archived.id in Enum.map(int.archived_channels, & &1.id)
  end

  test "a chat.read grant on a channel reaches the guest's rail; a deny removes it", ctx do
    granted = channel!("Granted Briefing Room", org_id: ctx.org.id)

    rail = fn ->
      {:ok, view, _} =
        build_conn() |> with_chat_host() |> authed(ctx.guest) |> live("/chat/#{ctx.allowed.slug}")

      Enum.map(assigns(view).channels, & &1.id)
    end

    before = rail.()
    assert ctx.allowed.id in before
    refute granted.id in before, "positive control: a guest does not see a non-member channel"

    {:ok, _} =
      Grants.grant(%{
        principal: ctx.guest,
        permission: "chat.read",
        resource: {:space, granted.id}
      })

    assert granted.id in rail.()
    assert ctx.allowed.id in rail.()

    {:ok, _} =
      Grants.deny(%{
        principal: ctx.guest,
        permission: "chat.read",
        resource: {:space, ctx.allowed.id}
      })

    after_deny = rail.()
    refute ctx.allowed.id in after_deny
    assert granted.id in after_deny
  end
end
