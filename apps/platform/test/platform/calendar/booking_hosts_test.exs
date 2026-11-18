defmodule Platform.Calendar.BookingHostsTest do
  @moduledoc """
  Task 01a1eff0-6880 stage 1: the co-host set of a booking link, its
  invite/accept/decline/leave/remove/reinvite transitions, the readiness rule
  every slot read will use, and the Inbox row an invite emits.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Access.{Grants, Scope}
  alias Platform.Accounts.User
  alias Platform.Calendar.{BookingHosts, BookingLinkHost, BookingLinks}
  alias Platform.Inbox.Item
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership

  defp user!(name) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "booking-host-#{n}@example.com",
      oidc_sub: "booking-host-#{n}",
      name: name
    })
  end

  defp member!(user, org_id, extra \\ %{}) do
    Repo.insert!(struct(%OrgMembership{user_id: user.id, org_id: org_id, role: "member"}, extra))
    user
  end

  defp link!(owner, extra \\ %{}) do
    date = Date.add(Date.utc_today(), 7)

    {:ok, link} =
      BookingLinks.create(
        Scope.for_user(owner),
        Map.merge(
          %{
            title: "Office hours",
            time_zone: "Etc/UTC",
            duration_minutes: 30,
            start_date: date,
            end_date: Date.add(date, 30),
            windows: [
              %{"weekday" => Date.day_of_week(date), "start" => "09:00", "end" => "12:00"}
            ]
          },
          extra
        )
      )

    link
  end

  defp scope(user), do: Scope.for_user(Repo.get!(User, user.id))

  defp invite_rows(user_id) do
    Repo.all(
      from(i in Item,
        where: i.user_id == ^user_id and i.kind == "booking_cohost_invite",
        order_by: [asc: i.inserted_at, asc: i.id]
      )
    )
  end

  defp status(host), do: Repo.get!(BookingLinkHost, host.id).status

  setup do
    n = System.unique_integer([:positive])
    org = Platform.TenancyFixtures.tenant_org_id("booking_hosts_#{n}")
    owner = "Ryan Milvenan" |> user!() |> member!(org)
    jordan = "Jordan Coombs" |> user!() |> member!(org)
    link = link!(owner)
    %{org: org, owner: owner, jordan: jordan, link: link}
  end

  describe "invite/3" do
    test "creates a pending row and emits one Inbox invite to the co-host", ctx do
      assert {:ok, host} = BookingHosts.invite(scope(ctx.owner), ctx.link.id, ctx.jordan.id)
      assert host.status == "pending"
      assert host.invited_by_id == ctx.owner.id
      assert [%BookingLinkHost{id: id}] = BookingHosts.list_for_link(ctx.link)
      assert id == host.id

      assert [item] = invite_rows(ctx.jordan.id)
      assert item.source_type == "booking_link_host"
      assert item.source_id == host.id
      assert item.title == ~s(Ryan invited you to co-host "Office hours")
      assert item.url == "/calendar/booking?cohost=#{host.id}"
      assert item.body =~ "Guests never see your calendar."
      assert is_nil(item.dismissed_at)
      assert invite_rows(ctx.owner.id) == []
    end

    test "the owner cannot co-host their own link", ctx do
      assert {:error, :owner_cannot_cohost} =
               BookingHosts.invite(scope(ctx.owner), ctx.link.id, ctx.owner.id)

      assert BookingHosts.list_for_link(ctx.link) == []
    end

    test "a user sharing no org with the owner is refused", ctx do
      stranger = user!("Sam Stranger")

      other_org =
        Platform.TenancyFixtures.tenant_org_id(
          "booking_hosts_other_#{System.unique_integer([:positive])}"
        )

      member!(stranger, other_org)

      assert {:error, :not_org_member} =
               BookingHosts.invite(scope(ctx.owner), ctx.link.id, stranger.id)

      assert BookingHosts.list_for_link(ctx.link) == []
      assert invite_rows(stranger.id) == []
    end

    test "an external member of the owner's org is refused", ctx do
      guest = "Gale Guest" |> user!() |> member!(ctx.org, %{external: true})

      assert {:error, :not_org_member} =
               BookingHosts.invite(scope(ctx.owner), ctx.link.id, guest.id)

      assert BookingHosts.list_for_link(ctx.link) == []
    end

    test "a revoked link, a duplicate, and another owner's link are refused", ctx do
      assert {:ok, _} = BookingHosts.invite(scope(ctx.owner), ctx.link.id, ctx.jordan.id)

      assert {:error, :already_invited} =
               BookingHosts.invite(scope(ctx.owner), ctx.link.id, ctx.jordan.id)

      assert {:error, :not_found} =
               BookingHosts.invite(scope(ctx.jordan), ctx.link.id, ctx.owner.id)

      other = link!(ctx.owner, %{title: "Revoked"})
      {:ok, _} = BookingLinks.revoke(scope(ctx.owner), other.id)

      assert {:error, :revoked} = BookingHosts.invite(scope(ctx.owner), other.id, ctx.jordan.id)
      assert length(invite_rows(ctx.jordan.id)) == 1
    end
  end

  describe "transitions" do
    setup ctx do
      {:ok, host} = BookingHosts.invite(scope(ctx.owner), ctx.link.id, ctx.jordan.id)
      %{host: host}
    end

    test "accept moves pending to accepted and dismisses the invite row", ctx do
      assert {:ok, accepted} = BookingHosts.accept(scope(ctx.jordan), ctx.host.id)
      assert accepted.status == "accepted"
      assert accepted.responded_at
      assert [%Item{dismissed_at: %DateTime{}}] = invite_rows(ctx.jordan.id)

      assert {:error, :invalid_transition} = BookingHosts.accept(scope(ctx.jordan), ctx.host.id)
    end

    test "decline moves pending to declined and dismisses the invite row", ctx do
      assert {:ok, declined} = BookingHosts.decline(scope(ctx.jordan), ctx.host.id)
      assert declined.status == "declined"
      assert [%Item{dismissed_at: %DateTime{}}] = invite_rows(ctx.jordan.id)
      assert {:error, :invalid_transition} = BookingHosts.leave(scope(ctx.jordan), ctx.host.id)
    end

    test "leave moves accepted to left; a pending row cannot be left", ctx do
      assert {:error, :invalid_transition} = BookingHosts.leave(scope(ctx.jordan), ctx.host.id)
      {:ok, _} = BookingHosts.accept(scope(ctx.jordan), ctx.host.id)
      assert {:ok, left} = BookingHosts.leave(scope(ctx.jordan), ctx.host.id)
      assert left.status == "left"
    end

    test "only the invited user can answer the invite", ctx do
      assert {:error, :not_found} = BookingHosts.accept(scope(ctx.owner), ctx.host.id)
      assert {:error, :not_found} = BookingHosts.decline(scope(ctx.owner), ctx.host.id)
      assert {:error, :not_found} = BookingHosts.accept(scope(ctx.jordan), "not-a-uuid")
      assert status(ctx.host) == "pending"
    end

    test "remove deletes the row and dismisses the invite row", ctx do
      assert {:error, :not_found} =
               BookingHosts.remove(scope(ctx.jordan), ctx.link.id, ctx.jordan.id)

      assert {:ok, _} = BookingHosts.remove(scope(ctx.owner), ctx.link.id, ctx.jordan.id)
      assert BookingHosts.list_for_link(ctx.link) == []
      assert [%Item{dismissed_at: %DateTime{}}] = invite_rows(ctx.jordan.id)

      assert {:error, :not_found} =
               BookingHosts.remove(scope(ctx.owner), ctx.link.id, ctx.jordan.id)
    end

    test "reinvite and invite set a declined or left row back to pending with a fresh row",
         ctx do
      assert {:error, :already_invited} =
               BookingHosts.reinvite(scope(ctx.owner), ctx.link.id, ctx.jordan.id)

      {:ok, _} = BookingHosts.decline(scope(ctx.jordan), ctx.host.id)
      assert {:ok, again} = BookingHosts.reinvite(scope(ctx.owner), ctx.link.id, ctx.jordan.id)
      assert again.id == ctx.host.id
      assert again.status == "pending"
      assert is_nil(again.responded_at)

      assert [%Item{dismissed_at: %DateTime{}}, %Item{dismissed_at: nil}] =
               invite_rows(ctx.jordan.id)

      {:ok, _} = BookingHosts.accept(scope(ctx.jordan), ctx.host.id)
      {:ok, _} = BookingHosts.leave(scope(ctx.jordan), ctx.host.id)

      assert {:ok, %{status: "pending"}} =
               BookingHosts.invite(scope(ctx.owner), ctx.link.id, ctx.jordan.id)

      other = user!("Nobody Here")

      assert {:error, :not_found} =
               BookingHosts.reinvite(scope(ctx.owner), ctx.link.id, other.id)
    end

    test "list_for_user lists pending and accepted co-hosted links only", ctx do
      assert [%BookingLinkHost{id: id, link: %{owner: %User{}}}] =
               BookingHosts.list_for_user(scope(ctx.jordan))

      assert id == ctx.host.id
      {:ok, _} = BookingHosts.accept(scope(ctx.jordan), ctx.host.id)
      assert [_] = BookingHosts.list_for_user(ctx.jordan.id)
      {:ok, _} = BookingHosts.leave(scope(ctx.jordan), ctx.host.id)
      assert BookingHosts.list_for_user(ctx.jordan.id) == []
      assert BookingHosts.list_for_user(ctx.owner.id) == []
    end
  end

  describe "hosts_ready/1" do
    test "a link with zero co-hosts is ready with only its owner", ctx do
      assert {:ok, [%User{id: id}]} = BookingHosts.hosts_ready(ctx.link)
      assert id == ctx.owner.id
    end

    test "a pending co-host is not ready", ctx do
      {:ok, _} = BookingHosts.invite(scope(ctx.owner), ctx.link.id, ctx.jordan.id)
      assert {:error, :hosts_not_ready} = BookingHosts.hosts_ready(ctx.link)
    end

    test "ready once every co-host has accepted, owner first", ctx do
      nathan = "Nathan Third" |> user!() |> member!(ctx.org)
      {:ok, j} = BookingHosts.invite(scope(ctx.owner), ctx.link.id, ctx.jordan.id)
      {:ok, n} = BookingHosts.invite(scope(ctx.owner), ctx.link.id, nathan.id)
      {:ok, _} = BookingHosts.accept(scope(ctx.jordan), j.id)
      assert {:error, :hosts_not_ready} = BookingHosts.hosts_ready(ctx.link)
      {:ok, _} = BookingHosts.accept(scope(nathan), n.id)

      assert {:ok, users} = BookingHosts.hosts_ready(ctx.link)
      assert Enum.map(users, & &1.id) == [ctx.owner.id, ctx.jordan.id, nathan.id]
    end

    test "a declined co-host is not ready", ctx do
      {:ok, host} = BookingHosts.invite(scope(ctx.owner), ctx.link.id, ctx.jordan.id)
      {:ok, _} = BookingHosts.decline(scope(ctx.jordan), host.id)
      assert {:error, :hosts_not_ready} = BookingHosts.hosts_ready(ctx.link)
    end

    test "a co-host who left is not ready; removing them makes the link ready again", ctx do
      {:ok, host} = BookingHosts.invite(scope(ctx.owner), ctx.link.id, ctx.jordan.id)
      {:ok, _} = BookingHosts.accept(scope(ctx.jordan), host.id)
      {:ok, _} = BookingHosts.leave(scope(ctx.jordan), host.id)
      assert {:error, :hosts_not_ready} = BookingHosts.hosts_ready(ctx.link)

      {:ok, _} = BookingHosts.remove(scope(ctx.owner), ctx.link.id, ctx.jordan.id)
      assert {:ok, [_owner]} = BookingHosts.hosts_ready(ctx.link)
    end

    test "an archived accepted co-host is not ready", ctx do
      accepted!(ctx)

      ctx.jordan
      |> Ecto.Changeset.change(archived_at: DateTime.utc_now())
      |> Repo.update!()

      assert {:error, :hosts_not_ready} = BookingHosts.hosts_ready(ctx.link)
    end

    test "an accepted co-host who lost calendar.write is not ready", ctx do
      accepted!(ctx)

      {:ok, _} =
        Grants.deny(%{
          principal: {:user, ctx.jordan.id},
          permission: "calendar",
          resource: {:module, ctx.org}
        })

      refute Platform.Access.can?(scope(ctx.jordan), "calendar.write")
      assert {:error, :hosts_not_ready} = BookingHosts.hosts_ready(ctx.link)
    end

    test "an accepted co-host who no longer shares an internal org is not ready", ctx do
      accepted!(ctx)

      Repo.update_all(
        from(m in OrgMembership, where: m.user_id == ^ctx.jordan.id and m.org_id == ^ctx.org),
        set: [external: true]
      )

      assert {:error, :hosts_not_ready} = BookingHosts.hosts_ready(ctx.link)
    end
  end

  describe "lock_hosts/1" do
    test "locks each distinct user once, in sorted id order", ctx do
      ids = [ctx.jordan.id, ctx.owner.id, ctx.jordan.id]

      {:ok, locked} = Repo.transaction(fn -> BookingHosts.lock_hosts(ids) end)
      assert Enum.map(locked, & &1.id) == Enum.sort(Enum.uniq(ids))
    end
  end

  defp accepted!(ctx) do
    {:ok, host} = BookingHosts.invite(scope(ctx.owner), ctx.link.id, ctx.jordan.id)
    {:ok, _} = BookingHosts.accept(scope(ctx.jordan), host.id)
    assert {:ok, [_, _]} = BookingHosts.hosts_ready(ctx.link)
    host
  end
end
