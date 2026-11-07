defmodule Platform.Prototypes.ReadableByTest do
  @moduledoc """
  `Platform.Prototypes.readable_by?/2` follows the prototype's space or
  canvas, not an `org_memberships` row in its org (task 01a1b70c stage 1).

  The fixture is the reported shape: a tenant org with ZERO membership rows
  that still owns a channel space, and a prototype bound to that space. Every
  case also asserts `list_readable/2`, the call `Platform.Chat.LinkCards`
  makes, so the card and the serve routes cannot disagree.
  """

  use Platform.DataCase, async: true

  import Platform.ExternalUserFixtures
  import Platform.TenancyFixtures

  alias Platform.Access.Grant
  alias Platform.Chat
  alias Platform.Prototypes
  alias Platform.Prototypes.Prototype
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  setup do
    tenant =
      Tenancy.get_org!(tenant_org_id("readable-tenant-#{System.unique_integer([:positive])}"))

    other =
      Tenancy.get_org!(tenant_org_id("readable-other-#{System.unique_integer([:positive])}"))

    space = channel!(%{name: "Relay space", org_id: tenant.id})
    prototype = prototype!(tenant, space_id: space.id)

    # The whole point: nobody holds a membership row in the tenant org.
    assert memberships(tenant) == 0

    %{tenant: tenant, other: other, space: space, prototype: prototype}
  end

  defp prototype!(org, attrs) do
    Repo.insert!(
      struct(
        %Prototype{
          org_id: org.id,
          name: "Tenant prototype #{System.unique_integer([:positive])}",
          latest_version: 1
        },
        attrs
      )
    )
  end

  defp memberships(org),
    do: Repo.aggregate(from(m in OrgMembership, where: m.org_id == ^org.id), :count)

  defp member_of!(org, role \\ "member") do
    user = create_user!()
    plain_member!(user, org, role)
    user
  end

  defp readable?(user, prototype) do
    by_id = Prototypes.list_readable(user, ids: [prototype.id]) |> Enum.map(& &1.id)
    answer = Prototypes.readable_by?(user, prototype)
    # The card call and the route call answer the same question.
    assert by_id == if(answer, do: [prototype.id], else: [])
    answer
  end

  test "a: a participant who is a member of a different org only can read", c do
    user = member_of!(c.other, "admin")
    add_user!(c.space.id, user.id)

    assert readable?(user, c.prototype)
    assert memberships(c.tenant) == 0
  end

  test "b: a signed-in member of another org who is not a participant cannot", c do
    user = member_of!(c.other)

    refute readable?(user, c.prototype)
  end

  test "c: an external user reads only as a participant", c do
    outsider = external_user!(c.other)
    refute readable?(outsider, c.prototype)

    # External users keep the :member path and nothing else, even when they
    # also hold an admin row in the root org.
    root_ext = external_user!(c.other)
    plain_member!(root_ext, Tenancy.get_org!(acme_org_id()), "admin")
    assert Tenancy.root_admin?(root_ext)
    refute readable?(root_ext, c.prototype)

    participant = external_user!(c.other)
    add_user!(c.space.id, participant.id)
    assert readable?(participant, c.prototype)
  end

  test "d: a root admin reads an accessible org channel, and nothing else, without participating",
       c do
    admin = root_admin!()
    assert readable?(admin, c.prototype)

    group = channel!(%{name: "Relay group", kind: "group", org_id: nil})
    refute readable?(admin, prototype!(c.tenant, space_id: group.id))

    dm = channel!(%{name: "Relay dm", kind: "dm", org_id: nil})
    refute readable?(admin, prototype!(c.tenant, space_id: dm.id))

    execution = channel!(%{name: "Relay execution", kind: "execution", org_id: c.tenant.id})
    refute readable?(admin, prototype!(c.tenant, space_id: execution.id))

    archived = channel!(%{name: "Relay archived", org_id: c.tenant.id})
    {:ok, _} = Chat.archive_space(archived)
    refute readable?(admin, prototype!(c.tenant, space_id: archived.id))
  end

  test "d: an org member of the space's org reads the channel without participating", c do
    # Fixture-only membership row, to pin the :org_reader branch for members.
    user = member_of!(c.tenant)
    assert readable?(user, c.prototype)
  end

  test "e: a canvas-owned prototype follows its canvas", c do
    author = add_user!(c.space.id, create_user!().id)
    canvas = canvas!(c.space.id, author.id)
    owned = prototype!(c.tenant, space_id: c.space.id, canvas_id: canvas.id)

    participant = member_of!(c.other)
    add_user!(c.space.id, participant.id)
    assert readable?(participant, owned)

    assert Prototypes.list_readable(participant, canvas_ids: [canvas.id]) |> Enum.map(& &1.id) ==
             [owned.id]

    outsider = member_of!(c.other)
    refute readable?(outsider, owned)
    assert Prototypes.list_readable(outsider, canvas_ids: [canvas.id]) == []
  end

  test "e: reading a canvas-owned prototype through the org reach mints no audit row", c do
    author = add_user!(c.space.id, create_user!().id)
    canvas = canvas!(c.space.id, author.id)
    owned = prototype!(c.tenant, space_id: c.space.id, canvas_id: canvas.id)
    admin = root_admin!()

    ref = :telemetry_test.attach_event_handlers(self(), [[:platform, :chat, :canvas_read]])
    on_exit(fn -> :telemetry.detach(ref) end)

    assert readable?(admin, owned)
    refute_received {[:platform, :chat, :canvas_read], ^ref, _, _}
  end

  test "f: with no space and no canvas, org membership is still required", c do
    bare = prototype!(c.other, [])

    stranger = create_user!()
    add_user!(c.space.id, stranger.id)
    refute readable?(stranger, bare)

    refute readable?(root_admin!(), bare)

    member = member_of!(c.other)
    assert readable?(member, bare)
  end

  test "g: a chat.read deny on the space refuses a participant", c do
    user = member_of!(c.other)
    add_user!(c.space.id, user.id)
    assert readable?(user, c.prototype)

    Repo.insert!(%Grant{
      org_id: c.tenant.id,
      principal_type: "user",
      principal_id: user.id,
      permission: "chat.read",
      resource_type: "space",
      resource_id: c.space.id,
      effect: "deny"
    })

    refute readable?(user, c.prototype)
  end

  test "nil and id-less users are refused", c do
    refute Prototypes.readable_by?(nil, c.prototype)
    refute Prototypes.readable_by?(%{id: nil}, c.prototype)
    refute Prototypes.readable_by?(%{}, c.prototype)
  end
end
