defmodule PlatformWeb.ChatLivePresenceScopeTest do
  @moduledoc """
  rbac-external-users M10 stage 2 — the ChatLive presence/typing subscribe
  scope.

  `PlatformWeb.ChatLive.presence_subscribe_space_ids/2` is the decision that
  confines which space topics an external user's ChatLive process subscribes
  to. It INTERSECTS the (workspace-wide) space set with the user's allowlisted
  membership scope: an external user is subscribed only to spaces they
  participate in, while an internal user is unrestricted (no regression).
  """
  use Platform.DataCase, async: true

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.{Org, OrgMembership}
  alias PlatformWeb.ChatLive

  defp create_user! do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{email: "u-#{n}@example.com", name: "User #{n}", oidc_sub: "oidc-#{n}"})
    |> Repo.insert!()
  end

  defp tenant_org! do
    n = System.unique_integer([:positive])

    %Org{}
    |> Org.changeset(%{
      name: "Tenant #{n}",
      slug: "tenant_#{n}",
      parent_org_id: Tenancy.get_org_by_slug!("fabrikam").id
    })
    |> Repo.insert!()
  end

  defp plain_membership!(user, org) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: "member"})
    |> Repo.insert!()
  end

  defp channel do
    {:ok, space} =
      Chat.create_space(%{
        name: "Chan",
        slug: "chan-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    space
  end

  defp add_user(space_id, user_id) do
    {:ok, _} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: user_id,
        joined_at: DateTime.utc_now()
      })
  end

  setup do
    org = tenant_org!()

    ext_user = create_user!()
    {:ok, _} = Tenancy.mark_membership_external(%{user_id: ext_user.id, org_id: org.id})

    int_user = create_user!()
    plain_membership!(int_user, org)

    # A: external user is a participant. B: internal-only (external user is NOT
    # a participant). Both are surfaced workspace-wide in the subscribe input.
    a = channel()
    b = channel()
    add_user(a.id, ext_user.id)
    add_user(a.id, int_user.id)
    add_user(b.id, int_user.id)

    %{ext_user: ext_user, int_user: int_user, a: a, b: b}
  end

  describe "presence_subscribe_space_ids/2" do
    test "external user is subscribed only to allowlisted spaces (intersect)", %{
      ext_user: ext_user,
      a: a,
      b: b
    } do
      ids = ChatLive.presence_subscribe_space_ids([a, b], ext_user.id)

      assert ids == [a.id]
      refute b.id in ids
    end

    test "internal user is subscribed to every space (no regression)", %{
      int_user: int_user,
      a: a,
      b: b
    } do
      ids = ChatLive.presence_subscribe_space_ids([a, b], int_user.id)

      assert Enum.sort(ids) == Enum.sort([a.id, b.id])
    end

    test "external subscribe set drops an archived member space", %{
      ext_user: ext_user,
      a: a
    } do
      archived = channel()
      add_user(archived.id, ext_user.id)
      {:ok, _} = Chat.archive_space(archived)

      ids = ChatLive.presence_subscribe_space_ids([a, archived], ext_user.id)

      assert ids == [a.id]
      refute archived.id in ids
    end
  end
end
