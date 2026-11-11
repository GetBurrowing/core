defmodule Platform.Access.SpaceInFenceTest do
  @moduledoc """
  `Access.space_in_fence?/2` is the point check for ONE space; it must agree
  with the list rule the mount applies, `space_id in fenced_ids(scope, :space)`
  (or `:unfenced`), for every kind of viewer.
  """
  use Platform.DataCase, async: true

  import Ecto.Query

  alias Platform.Access
  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.Org
  alias Platform.Tenancy.OrgMembership

  defp user!(label) do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{
      email: "sif-#{label}-#{n}@example.com",
      name: "Sif #{label} #{n}",
      oidc_sub: "oidc-sif-#{label}-#{n}"
    })
    |> Repo.insert!()
  end

  defp sub_org! do
    n = System.unique_integer([:positive])

    %Org{}
    |> Org.changeset(%{
      name: "SIF #{n}",
      slug: "sif_#{n}",
      parent_org_id: Tenancy.get_org_by_slug!("acme").id
    })
    |> Repo.insert!()
  end

  defp member!(user, org) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: "member"})
    |> Repo.insert!()
  end

  defp space_in!(org) do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{name: "sif-#{n}", slug: "sif-#{n}", kind: "channel"})

    {1, _} =
      Repo.update_all(from(s in Platform.Chat.Space, where: s.id == ^space.id),
        set: [org_id: org && org.id]
      )

    Chat.get_space(space.id)
  end

  defp seat!(space, user) do
    {:ok, _} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        joined_at: DateTime.utc_now()
      })
  end

  defp scope_of(user_id), do: user_id |> Platform.Accounts.get_user() |> Access.scope_for()

  defp list_rule(scope, space_id) do
    case Access.fenced_ids(scope, :space) do
      :unfenced -> true
      ids -> space_id in ids
    end
  end

  test "agrees with the list rule for every viewer kind and space" do
    org_a = sub_org!()
    org_b = sub_org!()
    root = Tenancy.get_org_by_slug!("acme")

    spaces = [space_in!(org_a), space_in!(org_b), space_in!(root), space_in!(nil)]
    [space_a, space_b | _] = spaces

    root_member = user!("root") |> tap(&member!(&1, root))
    own_org = user!("own") |> tap(&member!(&1, org_a))
    seated_out = user!("seated-out") |> tap(&member!(&1, org_a)) |> tap(&seat!(space_b, &1))
    no_member = user!("none")
    seated_none = user!("seated-none") |> tap(&seat!(space_a, &1))
    guest = user!("guest")
    {:ok, _} = Tenancy.mark_membership_external(%{user_id: guest.id, org_id: org_a.id})
    external_seated = user!("ext") |> tap(&seat!(space_b, &1))
    {:ok, _} = Tenancy.mark_membership_external(%{user_id: external_seated.id, org_id: org_a.id})
    deleted = user!("deleted")
    Repo.delete!(deleted)

    viewers = [
      root_member: root_member,
      own_org: own_org,
      seated_outside: seated_out,
      no_memberships: no_member,
      seated_no_memberships: seated_none,
      guest: guest,
      external_invited_seated: external_seated,
      deleted: deleted
    ]

    outcomes =
      for {label, user} <- viewers, space <- spaces do
        scope = scope_of(user.id)
        point = Access.space_in_fence?(scope, space.id)
        assert point == list_rule(scope, space.id), "#{label} vs space #{space.id}"
        {label, space.id == space_b.id, point}
      end

    # the table has teeth: both answers occur, and a sub-org member is denied
    # a foreign org's space while a seated one is not.
    assert Enum.any?(outcomes, &match?({_, _, true}, &1))
    assert Enum.any?(outcomes, &match?({_, _, false}, &1))
    refute Access.space_in_fence?(scope_of(own_org.id), space_b.id)
    assert Access.space_in_fence?(scope_of(seated_out.id), space_b.id)
    assert Access.space_in_fence?(scope_of(no_member.id), space_b.id)
  end
end
