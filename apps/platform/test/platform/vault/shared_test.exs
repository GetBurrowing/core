defmodule Platform.Vault.SharedTest do
  @moduledoc """
  Task 01a131c5 stage 1 — `Platform.Vault.Shared`, the admin context behind
  `/admin/vault`: root-admin gating, one-save create with grants, grant
  diffing, slug refusal and write-only listing.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.VaultFixtures

  alias Platform.Repo
  alias Platform.Vault
  alias Platform.Vault.Credential
  alias Platform.Vault.Shared

  @value "fake-admin-pasted-value"

  setup do
    %{admin: admin!(), agent_a: agent!(), agent_b: agent!()}
  end

  describe "authorization" do
    test "a non-admin is refused every write and read, and nothing is written", ctx do
      user = non_admin!()
      slug = unique_slug()

      assert {:error, :unauthorized} =
               Shared.create(user, %{slug: slug, value: @value}, [ctx.agent_a.id])

      refute Repo.exists?(from(c in Credential, where: c.slug == ^slug))

      {:ok, cred} = Shared.create(ctx.admin, %{slug: slug, value: @value}, [])

      assert {:error, :unauthorized} = Shared.rotate(user, slug, "fake-other")
      assert {:error, :unauthorized} = Shared.revoke(user, slug)
      assert {:error, :unauthorized} = Shared.set_grants(user, cred.id, [ctx.agent_a.id])
      assert {:error, :unauthorized} = Shared.list(user)
      assert {:error, :unauthorized} = Shared.access_log(user, slug)
      assert {:error, :unauthorized} = Shared.list(nil)

      assert grants_for(cred.id) == []
      assert Repo.get(Credential, cred.id)
    end
  end

  describe "create/3" do
    test "creates a shared secret and one use grant per agent", ctx do
      slug = unique_slug()

      assert {:ok, summary} =
               Shared.create(
                 ctx.admin,
                 %{slug: slug, value: @value, note: "for the install test"},
                 [ctx.agent_a.id, ctx.agent_b.id]
               )

      refute inspect(summary) =~ @value
      assert summary.scope_type == "shared"
      assert summary.note == "for the install test"
      assert summary.fingerprint == Vault.fingerprint(@value)

      grants = grants_for(summary.id)
      assert length(grants) == 2
      assert Enum.all?(grants, &(&1.permissions == ["use"] and &1.granted_by == ctx.admin.id))

      assert Enum.sort(Enum.map(grants, & &1.grantee_id)) ==
               Enum.sort([ctx.agent_a.id, ctx.agent_b.id])

      cred = Repo.get!(Credential, summary.id)
      assert cred.scope_type == "shared"
      assert is_nil(cred.scope_id)
    end

    test "refuses a slug that already exists as a shared secret and writes nothing", ctx do
      slug = unique_slug()
      {:ok, _} = Shared.create(ctx.admin, %{slug: slug, value: @value}, [])
      before = logs_for_slug(slug)

      assert {:error, :slug_taken} =
               Shared.create(ctx.admin, %{slug: slug, value: "fake-second"}, [ctx.agent_a.id])

      assert Repo.aggregate(from(c in Credential, where: c.slug == ^slug), :count) == 1
      assert logs_for_slug(slug) == before
    end

    test "refuses a slug that already exists at platform scope and writes nothing", ctx do
      slug = unique_slug()
      {:ok, platform} = Vault.put(slug, :api_key, "fake-platform-value")

      assert {:error, :slug_taken} =
               Shared.create(ctx.admin, %{slug: slug, value: @value}, [ctx.agent_a.id])

      assert [%Credential{id: id}] = Repo.all(from(c in Credential, where: c.slug == ^slug))
      assert id == platform.id
      assert grants_for(platform.id) == []
    end

    test "refuses a malformed slug and an unknown agent id, writing nothing", ctx do
      assert {:error, :invalid_slug} =
               Shared.create(ctx.admin, %{slug: "Bad Name", value: @value}, [])

      slug = unique_slug()

      assert {:error, :unknown_agent} =
               Shared.create(ctx.admin, %{slug: slug, value: @value}, [Ecto.UUID.generate()])

      refute Repo.exists?(from(c in Credential, where: c.slug == ^slug))
    end
  end

  describe "set_grants/3" do
    test "removing one agent deletes only that grant and logs update/removed", ctx do
      slug = unique_slug()

      {:ok, cred} =
        Shared.create(ctx.admin, %{slug: slug, value: @value}, [ctx.agent_a.id, ctx.agent_b.id])

      [b_grant] = Enum.filter(grants_for(cred.id), &(&1.grantee_id == ctx.agent_b.id))

      assert :ok = Shared.set_grants(ctx.admin, cred.id, [ctx.agent_b.id])

      assert [remaining] = grants_for(cred.id)
      assert remaining.id == b_grant.id

      removed =
        slug
        |> logs_for_slug()
        |> Enum.filter(&(&1.action == "update" and &1.metadata["grant"] == "removed"))

      assert [%{metadata: %{"agent_id" => agent_id}}] = removed
      assert agent_id == ctx.agent_a.id

      assert {:error, :access_denied} =
               Vault.get(slug, scope: {:shared, nil}, accessor: {:agent, ctx.agent_a.id})

      assert {:ok, @value} =
               Vault.get(slug, scope: {:shared, nil}, accessor: {:agent, ctx.agent_b.id})
    end

    test "re-saving the same set changes nothing and logs nothing", ctx do
      slug = unique_slug()
      {:ok, cred} = Shared.create(ctx.admin, %{slug: slug, value: @value}, [ctx.agent_a.id])
      before = logs_for_slug(slug)

      assert :ok = Shared.set_grants(ctx.admin, cred.id, [ctx.agent_a.id])
      assert logs_for_slug(slug) == before
    end

    test "refuses a non-shared credential", ctx do
      {:ok, platform} = Vault.put(unique_slug(), :api_key, "fake-platform-value")
      assert {:error, :not_found} = Shared.set_grants(ctx.admin, platform.id, [ctx.agent_a.id])
      assert grants_for(platform.id) == []
    end
  end

  describe "list/1" do
    test "never contains a value key or the value, and carries grants and refusals", ctx do
      slug = unique_slug()
      {:ok, cred} = Shared.create(ctx.admin, %{slug: slug, value: @value}, [ctx.agent_a.id])
      {:error, :access_denied} = Vault.get(slug, accessor: {:agent, ctx.agent_b.id})

      assert {:ok, rows} = Shared.list(ctx.admin)
      row = Enum.find(rows, &(&1.id == cred.id))

      refute Map.has_key?(row, :encrypted_data)
      refute Map.has_key?(row, :value)
      refute inspect(rows) =~ @value
      assert row.granted_agent_ids == [ctx.agent_a.id]
      assert row.refused_7d == 1
    end

    test "the fingerprint changes on rotate", ctx do
      slug = unique_slug()
      {:ok, cred} = Shared.create(ctx.admin, %{slug: slug, value: @value}, [])

      assert {:ok, rotated} = Shared.rotate(ctx.admin, slug, "fake-rotated-value")
      refute rotated.fingerprint == cred.fingerprint
      refute inspect(rotated) =~ "fake-rotated-value"

      {:ok, rows} = Shared.list(ctx.admin)
      row = Enum.find(rows, &(&1.id == cred.id))
      assert row.fingerprint == Vault.fingerprint("fake-rotated-value")
    end
  end

  describe "revoke/2" do
    test "destroys the secret and grants, keeps the log, returns no value", ctx do
      slug = unique_slug()
      {:ok, cred} = Shared.create(ctx.admin, %{slug: slug, value: @value}, [ctx.agent_a.id])

      assert {:ok, result} = Shared.revoke(ctx.admin, slug)
      refute inspect(result) =~ @value
      assert Repo.get(Credential, cred.id) == nil
      assert grants_for(cred.id) == []
      assert {:ok, [%{action: "revoke"} | _]} = Shared.access_log(ctx.admin, slug)
    end
  end
end
