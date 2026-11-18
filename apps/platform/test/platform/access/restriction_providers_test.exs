defmodule Platform.Access.RestrictionProvidersTest do
  @moduledoc """
  The restriction-provider hook in `Platform.Access` (task 01a1ea5b stage 2):
  a configured module's `restricted_space_ids(scope, ids)` is merged into
  `Platform.Access.restricted_space_ids/2`, so every decision that reads it
  (`can?/3`, `within?/4`, `check/3`, `restriction_ids/3` and through it
  `Platform.Access.Query`) honours it; with no provider configured nothing
  changes; `:system` is never restricted.

  async: false — swaps `config :platform, Platform.Access` for a stub.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.ExternalUserFixtures
  import Platform.TenancyFixtures

  alias Platform.Access
  alias Platform.Access.Query, as: AccessQuery
  alias Platform.Access.Scope
  alias Platform.Chat.Space

  defmodule StubProvider do
    @moduledoc false
    def restricted_space_ids(_scope, :all), do: stubbed()
    def restricted_space_ids(_scope, ids), do: Enum.filter(stubbed(), &(&1 in ids))
    defp stubbed, do: Application.get_env(:platform, :restriction_provider_stub_ids, [])
  end

  setup do
    previous = Application.get_env(:platform, Access)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:platform, Access, previous),
        else: Application.delete_env(:platform, Access)

      Application.delete_env(:platform, :restriction_provider_stub_ids)
    end)

    user = create_user!()
    plain_member!(user, Platform.Tenancy.get_org!(acme_org_id()))
    space = channel!(%{org_id: acme_org_id()})
    other = channel!(%{org_id: acme_org_id()})
    add_user!(space.id, user.id)
    add_user!(other.id, user.id)

    %{scope: Scope.for_user(Platform.Accounts.get_user(user.id)), space: space, other: other}
  end

  defp providers!(list), do: Application.put_env(:platform, Access, restriction_providers: list)
  defp stub!(ids), do: Application.put_env(:platform, :restriction_provider_stub_ids, ids)

  defp listed(scope, ids) do
    from(s in Space, where: s.id in ^ids)
    |> AccessQuery.restrict(scope, "chat.read", :space, %{id: :id})
    |> select([s], s.id)
    |> Repo.all()
    |> MapSet.new()
  end

  test "the default configuration names Platform.Mail.Ownership as the provider" do
    assert Access.restriction_providers() == [Platform.Mail.Ownership]
  end

  test "a provider's ids are honoured by every decision that reads restrictions", c do
    providers!([StubProvider])
    stub!([])

    # Positive control: nothing stubbed, every read admits.
    assert Access.can?(c.scope, "chat.read", c.space.id)
    assert Access.check(c.scope, "chat.read", {:space, c.space.id}) == :ok
    assert listed(c.scope, [c.space.id, c.other.id]) == MapSet.new([c.space.id, c.other.id])

    stub!([c.space.id])

    assert Access.restricted_space_ids(c.scope, [c.space.id, c.other.id]) ==
             MapSet.new([c.space.id])

    assert Access.provider_restricted_space_ids(c.scope, :all) == MapSet.new([c.space.id])
    refute Access.can?(c.scope, "chat.read", c.space.id)
    refute Access.within?(c.scope, "chat.read", {:space, c.space.id}, true)
    # A grant-less Scope: check/3 refuses on a provider even so.
    refute Scope.has_grants?(c.scope)
    assert Access.check(c.scope, "chat.read", {:space, c.space.id}) == {:error, :denied}
    assert c.space.id in Access.restriction_ids(c.scope, "chat.read", :space)
    assert listed(c.scope, [c.space.id, c.other.id]) == MapSet.new([c.other.id])

    # The unrestricted neighbour is untouched, and a write is not a read.
    assert Access.can?(c.scope, "chat.read", c.other.id)
    assert Access.check(c.scope, "chat.write", {:space, c.space.id}) == :ok
  end

  test "with no providers configured, a stubbed id restricts nothing", c do
    providers!([])
    stub!([c.space.id])

    assert Access.restriction_providers() == []
    assert Access.restricted_space_ids(c.scope, [c.space.id]) == MapSet.new()
    assert Access.provider_restricted_space_ids(c.scope, :all) == MapSet.new()
    assert Access.can?(c.scope, "chat.read", c.space.id)
    assert Access.check(c.scope, "chat.read", {:space, c.space.id}) == :ok
    refute c.space.id in Access.restriction_ids(c.scope, "chat.read", :space)
    assert listed(c.scope, [c.space.id]) == MapSet.new([c.space.id])
  end

  test ":system is never restricted by a provider", c do
    providers!([StubProvider])
    stub!([c.space.id])

    assert Access.restricted_space_ids(Scope.system(), [c.space.id]) == MapSet.new()
    assert Access.can?(Scope.system(), "chat.read", c.space.id)
    assert Access.check(Scope.system(), "chat.read", {:space, c.space.id}) == :ok
    # Positive control: the same stub does restrict a user.
    refute Access.can?(c.scope, "chat.read", c.space.id)
  end
end
