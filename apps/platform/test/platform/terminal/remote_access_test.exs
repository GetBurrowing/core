defmodule Platform.Federation.RemoteAccessTest do
  use ExUnit.Case, async: true

  alias Platform.Federation.RemoteAccess

  test "today there is exactly one allowed kind" do
    assert RemoteAccess.allowed_kinds() == [:own_agent_in_member_install]
  end

  test "the owner's own agent is the allowed kind; anyone else is not" do
    owner = Ecto.UUID.generate()
    runtime = %{owner_user_id: owner}

    assert RemoteAccess.kind_for(runtime, owner) == :own_agent_in_member_install
    assert RemoteAccess.kind_for(runtime, Ecto.UUID.generate()) == :other_federation
    assert RemoteAccess.kind_for(runtime, nil) == :other_federation
    assert RemoteAccess.kind_for(nil, owner) == :other_federation
    assert RemoteAccess.kind_for(%{owner_user_id: nil}, nil) == :other_federation
  end

  test "an allowed kind still needs the opt-in" do
    refute RemoteAccess.permitted?(:own_agent_in_member_install, false)
    refute RemoteAccess.permitted?(:own_agent_in_member_install, nil)
    assert RemoteAccess.permitted?(:own_agent_in_member_install, true)
  end

  test "a non-owner kind cannot be switched on, even with opt-in true" do
    for kind <- RemoteAccess.kinds() -- RemoteAccess.allowed_kinds() do
      refute RemoteAccess.permitted?(kind, true), "#{inspect(kind)} must stay locked"
    end

    # A kind added tomorrow (marketplace, guest) starts locked until someone
    # edits the allowlist on purpose.
    for kind <- [:marketplace_agent, :guest, :peer_install, "own_agent_in_member_install", nil] do
      refute RemoteAccess.permitted?(kind, true)
      refute RemoteAccess.allowed_kind?(kind)
    end

    assert :other_federation in RemoteAccess.kinds()
    refute :other_federation in RemoteAccess.allowed_kinds()
  end
end
