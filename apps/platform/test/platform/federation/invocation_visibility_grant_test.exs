defmodule Platform.Federation.InvocationVisibilityGrantTest do
  @moduledoc """
  ADR 0040 — schema-level coverage for the reserved `invocation_visibility_grants`
  table. Stage 1 ships the schema with no callers; tests pin the contract so
  Stage 2's visibility filter can rely on it.
  """

  use Platform.DataCase, async: true

  alias Platform.Federation.InvocationVisibilityGrant
  alias Platform.Repo

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp valid_attrs(overrides \\ %{}) do
    %{
      invocation_id: Ecto.UUID.generate(),
      grantee_user_id: Ecto.UUID.generate(),
      grantee_org_id: Ecto.UUID.generate(),
      granted_by_user_id: Ecto.UUID.generate(),
      granted_by_org_id: Ecto.UUID.generate(),
      scope: "read_thinking_stream"
    }
    |> Map.merge(overrides)
  end

  describe "grant_scopes/0" do
    test "returns the canonical scope values" do
      assert InvocationVisibilityGrant.grant_scopes() == ~w(read_thinking_stream read_audit)
    end
  end

  describe "changeset/2" do
    test "accepts a complete valid grant" do
      changeset = InvocationVisibilityGrant.changeset(%InvocationVisibilityGrant{}, valid_attrs())
      assert changeset.valid?
    end

    test "rejects missing invocation_id" do
      attrs = valid_attrs() |> Map.delete(:invocation_id)
      changeset = InvocationVisibilityGrant.changeset(%InvocationVisibilityGrant{}, attrs)

      refute changeset.valid?
      assert %{invocation_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects missing grantee_user_id" do
      attrs = valid_attrs() |> Map.delete(:grantee_user_id)
      changeset = InvocationVisibilityGrant.changeset(%InvocationVisibilityGrant{}, attrs)

      refute changeset.valid?
      assert %{grantee_user_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects missing granted_by fields" do
      attrs = valid_attrs() |> Map.drop([:granted_by_user_id, :granted_by_org_id])
      changeset = InvocationVisibilityGrant.changeset(%InvocationVisibilityGrant{}, attrs)

      refute changeset.valid?
      errors = errors_on(changeset)
      assert errors[:granted_by_user_id]
      assert errors[:granted_by_org_id]
    end

    test "rejects unknown scope value" do
      changeset =
        InvocationVisibilityGrant.changeset(
          %InvocationVisibilityGrant{},
          valid_attrs(%{scope: "made_up_scope"})
        )

      refute changeset.valid?
      assert %{scope: [_message]} = errors_on(changeset)
    end

    test "accepts both canonical scopes" do
      for scope <- ~w(read_thinking_stream read_audit) do
        changeset =
          InvocationVisibilityGrant.changeset(
            %InvocationVisibilityGrant{},
            valid_attrs(%{scope: scope})
          )

        assert changeset.valid?, "Expected scope=#{scope} to be valid"
      end
    end
  end

  describe "lifecycle fields" do
    test "accepts an optional revoked_at timestamp" do
      revoked = DateTime.utc_now()

      changeset =
        InvocationVisibilityGrant.changeset(
          %InvocationVisibilityGrant{},
          valid_attrs(%{revoked_at: revoked, revocation_reason: "user requested"})
        )

      assert changeset.valid?
    end

    test "accepts an optional expires_at timestamp" do
      expires = DateTime.add(DateTime.utc_now(), 86_400)

      changeset =
        InvocationVisibilityGrant.changeset(
          %InvocationVisibilityGrant{},
          valid_attrs(%{expires_at: expires})
        )

      assert changeset.valid?
    end
  end

  describe "DB persistence (smoke test for migration)" do
    test "a complete grant round-trips through the database" do
      attrs = valid_attrs(%{granted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)})

      {:ok, grant} =
        %InvocationVisibilityGrant{}
        |> InvocationVisibilityGrant.changeset(attrs)
        |> Repo.insert()

      reloaded = Repo.get!(InvocationVisibilityGrant, grant.id)
      assert reloaded.invocation_id == attrs.invocation_id
      assert reloaded.grantee_user_id == attrs.grantee_user_id
      assert reloaded.scope == "read_thinking_stream"
      assert is_nil(reloaded.revoked_at)
    end

    test "unique-active constraint prevents duplicate grants for same (invocation, grantee, scope) tuple" do
      shared = valid_attrs()

      {:ok, _first} =
        %InvocationVisibilityGrant{}
        |> InvocationVisibilityGrant.changeset(shared)
        |> Repo.insert()

      {:error, changeset} =
        %InvocationVisibilityGrant{}
        |> InvocationVisibilityGrant.changeset(shared)
        |> Repo.insert()

      refute changeset.valid?
      # The unique_constraint surfaces under the composite name
      assert errors_on(changeset)[:invocation_id] ||
               errors_on(changeset)[:grantee_user_id] ||
               errors_on(changeset)[:scope]
    end

    test "a revoked grant allows a new active grant for same tuple (partial unique index)" do
      base = valid_attrs()

      {:ok, original} =
        %InvocationVisibilityGrant{}
        |> InvocationVisibilityGrant.changeset(base)
        |> Repo.insert()

      # Revoke
      {:ok, _revoked} =
        original
        |> InvocationVisibilityGrant.changeset(%{
          revoked_at: DateTime.utc_now(),
          revocation_reason: "test"
        })
        |> Repo.update()

      # New grant for the same tuple should succeed (partial index excludes revoked)
      {:ok, new_grant} =
        %InvocationVisibilityGrant{}
        |> InvocationVisibilityGrant.changeset(base)
        |> Repo.insert()

      refute new_grant.id == original.id
    end
  end
end
