defmodule Platform.Vault.SharedScopeTest do
  @moduledoc """
  Task 01a131c5 stage 1 — the `shared` scope's access rule.

  The property: who may READ a shared secret is decided by `scope_type` plus
  `AccessGrant` rows and nothing else. There is no privileged read bypass,
  and no metadata write can widen access, because no shared clause reads
  metadata. The platform `:use` clause is pinned unchanged as a regression.
  """
  use Platform.DataCase, async: true

  import Platform.VaultFixtures

  alias Platform.Repo
  alias Platform.Vault
  alias Platform.Vault.Credential

  @value "fake-shared-value-for-tests"
  @scope {:shared, nil}

  defp shared!(slug \\ unique_slug()) do
    {:ok, cred} = Vault.put(slug, :api_key, @value, scope: @scope)
    cred
  end

  defp get(cred, accessor), do: Vault.get(cred.slug, scope: @scope, accessor: accessor)

  describe "no grant" do
    test "every accessor is refused :use, including privileged ones" do
      cred = shared!()
      agent_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()

      assert {:error, :access_denied} = get(cred, {:agent, agent_id})
      assert {:error, :access_denied} = get(cred, {:system, nil})
      assert {:error, :access_denied} = get(cred, {:platform, user_id})
      assert {:error, :access_denied} = get(cred, nil)

      actions = cred.slug |> logs_for_slug() |> Enum.map(& &1.action)
      assert actions == ~w(denied denied denied denied)
    end

    test "still refused after a rotation" do
      cred = shared!()
      agent_id = Ecto.UUID.generate()

      assert {:ok, _} =
               Vault.rotate(cred.slug, "fake-rotated-value",
                 scope: @scope,
                 accessor: {:platform, Ecto.UUID.generate()}
               )

      assert {:error, :access_denied} = get(cred, {:agent, agent_id})
    end

    test "still refused after a direct write that wipes metadata" do
      cred = shared!()
      agent_id = Ecto.UUID.generate()

      {:ok, _} =
        Credential
        |> Repo.get!(cred.id)
        |> Credential.changeset(%{metadata: %{}})
        |> Repo.update()

      assert {:error, :access_denied} = get(cred, {:agent, agent_id})

      # And a metadata write naming the agent does not open it either.
      {:ok, _} =
        Credential
        |> Repo.get!(cred.id)
        |> Credential.changeset(%{metadata: %{"grant_required" => false, "agents" => [agent_id]}})
        |> Repo.update()

      assert {:error, :access_denied} = get(cred, {:agent, agent_id})
    end
  end

  describe "with a use grant" do
    test "the granted agent reads it; another agent does not" do
      cred = shared!()
      agent_id = Ecto.UUID.generate()
      grant!(cred.id, agent_id, ["use"])

      assert {:ok, @value} = get(cred, {:agent, agent_id})
      assert {:error, :access_denied} = get(cred, {:agent, Ecto.UUID.generate()})
    end

    test "a use-only grantee cannot rotate or revoke" do
      cred = shared!()
      agent_id = Ecto.UUID.generate()
      grant!(cred.id, agent_id, ["use"])

      assert {:error, :access_denied} =
               Vault.rotate(cred.slug, "fake-new", scope: @scope, accessor: {:agent, agent_id})

      assert {:error, :access_denied} =
               Vault.delete(cred.slug, scope: @scope, accessor: {:agent, agent_id})

      assert {:ok, @value} = get(cred, {:agent, agent_id})
    end
  end

  describe "privileged writes" do
    test "{:platform, user_id} may rotate and delete" do
      cred = shared!()
      admin = {:platform, Ecto.UUID.generate()}

      assert {:ok, _} = Vault.rotate(cred.slug, "fake-new", scope: @scope, accessor: admin)
      assert {:ok, _} = Vault.delete(cred.slug, scope: @scope, accessor: admin)
      assert Repo.get(Credential, cred.id) == nil
    end

    test "a nil accessor is denied every permission" do
      cred = shared!()

      assert {:error, :access_denied} = Vault.get(cred.slug, scope: @scope)
      assert {:error, :access_denied} = Vault.rotate(cred.slug, "fake-new", scope: @scope)
      assert {:error, :access_denied} = Vault.delete(cred.slug, scope: @scope)
      assert {:error, :access_denied} = Vault.authorize(cred.slug, nil, :use, scope: @scope)
      assert Repo.get(Credential, cred.id)
    end
  end

  describe "regression: platform scope unchanged" do
    test "a platform-scoped credential is still readable by any accessor" do
      slug = unique_slug("platform")
      {:ok, _} = Vault.put(slug, :api_key, @value)

      assert {:ok, @value} = Vault.get(slug, accessor: {:agent, Ecto.UUID.generate()})
      assert {:ok, @value} = Vault.get(slug, accessor: nil)
    end
  end

  describe "slug uniqueness" do
    test "two shared rows with one slug and different scope_ids violate the partial index" do
      slug = unique_slug()

      {:ok, _} = Vault.put(slug, :api_key, @value, scope: {:shared, Ecto.UUID.generate()})

      assert {:error, changeset} =
               Vault.put(slug, :api_key, @value, scope: {:shared, Ecto.UUID.generate()})

      assert {_, opts} = changeset.errors[:slug]
      assert opts[:constraint_name] == "vault_credentials_unique_shared_slug"
    end

    test "a shared slug may not repeat even at a different workspace_id" do
      slug = unique_slug()
      {:ok, _} = Vault.put(slug, :api_key, @value, scope: @scope)

      assert {:error, changeset} =
               Vault.put(slug, :api_key, @value,
                 scope: @scope,
                 workspace_id: Ecto.UUID.generate()
               )

      assert {_, opts} = changeset.errors[:slug]
      assert opts[:constraint_name] == "vault_credentials_unique_shared_slug"
    end
  end

  describe "fingerprint" do
    test "put stores it and rotate replaces it, merged into existing metadata" do
      slug = unique_slug()

      {:ok, cred} =
        Vault.put(slug, :api_key, "fake-one", scope: @scope, metadata: %{"note" => "n"})

      assert cred.metadata["fingerprint"] == Vault.fingerprint("fake-one")
      assert cred.metadata["note"] == "n"
      assert "sha256 .." <> <<_::binary-size(4)>> = cred.metadata["fingerprint"]

      {:ok, rotated} =
        Vault.rotate(slug, "fake-two", scope: @scope, accessor: {:system, nil})

      assert rotated.metadata["fingerprint"] == Vault.fingerprint("fake-two")
      assert rotated.metadata["note"] == "n"
      refute rotated.metadata["fingerprint"] == cred.metadata["fingerprint"]
      refute inspect(rotated.metadata) =~ "fake-two"
    end
  end
end
