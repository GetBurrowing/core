defmodule Platform.Roles.SeedsTest do
  @moduledoc """
  Tests for `Platform.Roles.Seeds` (M4 stage 4 of task
  `019ef65b-a361-7873-871b-3375bf60ead7`).

  Confirms:

    * `seed_defaults/0` inserts the four canonical roles and their
      bundled responsibility keys on a fresh DB.
    * Re-running `seed_defaults/0` is idempotent — the second call
      neither errors nor duplicates rows.
    * Each role's bundle round-trips through
      `Platform.Roles.bundle_for/1`.
    * The seeded list matches `Platform.Roles.Role.valid_keys/0` so
      the closed-roster invariant (Decision 2) holds.

  Deep behavioural coverage (resolver semantics, override-wins
  cascades) lives in `Platform.RolesTest`; this file is the seed-shape
  contract.
  """
  use Platform.DataCase, async: false

  alias Platform.Repo
  alias Platform.Roles
  alias Platform.Roles.Role
  alias Platform.Roles.RoleResponsibility
  alias Platform.Roles.Seeds

  describe "default_roles/0" do
    test "exposes the four canonical role keys aligned with the closed roster" do
      seeded_keys =
        Seeds.default_roles()
        |> Enum.map(& &1.key)
        |> Enum.sort()

      valid_keys = Enum.sort(Role.valid_keys())

      assert seeded_keys == valid_keys,
             """
             Seeded role keys must match the closed roster from
             `Platform.Roles.Role.valid_keys/0` (Decision 2 from the M4
             stack). Drift here means either Stage 1 added a key the
             seeds didn't follow, or Stage 4 invented a key the schema
             doesn't allow.
             Seeded: #{inspect(seeded_keys)}
             Valid:  #{inspect(valid_keys)}
             """
    end

    test "each role has 2+ bundled responsibility keys" do
      for role <- Seeds.default_roles() do
        assert length(role.bundle) >= 2,
               "role #{role.key} must bundle at least two responsibilities"
      end
    end
  end

  describe "seed_defaults/0" do
    test "inserts four roles and twelve bundle rows on a fresh DB" do
      assert :ok = Seeds.seed_defaults()

      assert Repo.aggregate(Role, :count, :key) == 4
      assert Repo.aggregate(RoleResponsibility, :count, :id) == 12
    end

    test "is idempotent — calling twice does not duplicate rows" do
      assert :ok = Seeds.seed_defaults()
      assert :ok = Seeds.seed_defaults()

      assert Repo.aggregate(Role, :count, :key) == 4
      assert Repo.aggregate(RoleResponsibility, :count, :id) == 12
    end

    test "each role's bundle round-trips via Platform.Roles.bundle_for/1" do
      :ok = Seeds.seed_defaults()

      for role_attrs <- Seeds.default_roles() do
        expected = Enum.sort(role_attrs.bundle)
        actual = Roles.bundle_for(role_attrs.key)

        assert actual == expected,
               """
               bundle_for/1 mismatch for role #{role_attrs.key}.
               Expected (sorted): #{inspect(expected)}
               Actual:            #{inspect(actual)}
               """
      end
    end

    test "each role row carries the canonical name / description / icon from the seed list" do
      :ok = Seeds.seed_defaults()

      for role_attrs <- Seeds.default_roles() do
        role = Roles.get_role!(role_attrs.key)

        assert role.name == role_attrs.name
        assert role.description == role_attrs.description
        assert role.icon == role_attrs.icon
      end
    end
  end
end
