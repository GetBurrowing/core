defmodule Platform.Roles.AgentsLeaderRoleTest do
  @moduledoc """
  Contract for the `agents_leader` role added in task
  `01a0b491-0718-7001-8bba-bf50f119bb13` stage 1.

  Asserts the key is admitted by the closed roster (`valid_keys/0` plus
  the changeset's `validate_inclusion`), that the seeded bundle carries
  `agents.goal_heartbeat` (the responsibility stage 3 registers), and —
  as the positive control for the inclusion assertion — that a key
  NOT on the roster is still rejected. Without that control an
  `@valid_keys` accidentally opened to every string would pass the
  first assertion.

  No role assignment is seeded or asserted here: pinning an agent to
  this role is a runtime `role_assignments` operation, deliberately, so
  naming the first leader and reassigning later are the same operation.
  """
  use Platform.DataCase, async: false

  alias Platform.Roles
  alias Platform.Roles.Role
  alias Platform.Roles.Seeds

  test "agents_leader is on the closed roster and a non-roster key is still rejected" do
    assert "agents_leader" in Role.valid_keys()

    ok =
      Role.changeset(%Role{}, %{
        key: "agents_leader",
        name: "Agents Leader",
        description: "d",
        icon: "hero-flag"
      })

    assert ok.valid?

    # Positive control: the roster is still closed.
    bad =
      Role.changeset(%Role{}, %{
        key: "not_a_real_role",
        name: "X",
        description: "d",
        icon: "hero-flag"
      })

    refute bad.valid?
    assert {"is invalid", _} = bad.errors[:key]
  end

  test "the seeded agents_leader bundle contains agents.goal_heartbeat" do
    :ok = Seeds.seed_defaults()

    bundle = Roles.bundle_for("agents_leader")

    assert "agents.goal_heartbeat" in bundle

    # Positive control: bundle_for/1 is not returning a catch-all list.
    refute "architecture.cron_sweep" in bundle
  end
end
