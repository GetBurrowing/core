defmodule Platform.Vault.AccessLogTest do
  @moduledoc """
  Retention of the vault access log past the life of the credential it describes.

  The interesting case is the last one: a raw `Repo.delete/1` that never goes
  near `Platform.Vault.delete/2`. If the trail survives that, the guarantee is
  coming from the `ON DELETE SET NULL` constraint rather than from application
  code being polite, which is the whole point of doing this in a migration.

  `Vault.delete/2`'s own retained `"revoke"` entry is asserted in
  `Platform.VaultTest`'s "delete/2 access-log retention" block, alongside
  `Vault.access_log/2`. Deliberately kept there and not duplicated here: this
  module is about the constraint, that one is about the context that relies on
  it. The `"denied"` case below covers `delete/2`'s refusing exit.
  """

  use Platform.DataCase, async: true

  import Ecto.Query

  alias Platform.Vault
  alias Platform.Vault.AccessGrant
  alias Platform.Vault.AccessLog
  alias Platform.Vault.Credential

  defp unique_slug(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp logs_for_slug(slug) do
    from(l in AccessLog, where: l.credential_slug == ^slug, order_by: [asc: l.inserted_at])
    |> Repo.all()
  end

  describe "denormalised credential columns" do
    test "get/2 stamps the credential's slug and scope onto the use entry" do
      owner = Ecto.UUID.generate()
      slug = unique_slug("log-use")
      {:ok, _cred} = Vault.put(slug, :api_key, "v1", scope: {:agent, owner})

      assert {:ok, "v1"} = Vault.get(slug, accessor: {:agent, owner})

      assert [entry] = logs_for_slug(slug)
      assert entry.action == "use"
      assert entry.credential_slug == slug
      assert entry.credential_scope_type == "agent"
      assert entry.accessor_id == owner
    end

    test "rotate/3 stamps the credential's slug and scope onto the rotate entry" do
      slug = unique_slug("log-rotate")
      {:ok, _cred} = Vault.put(slug, :api_key, "v1", scope: {:platform, nil})

      assert {:ok, _} = Vault.rotate(slug, "v2", accessor: {:system, nil})

      assert [entry] = logs_for_slug(slug)
      assert entry.action == "rotate"
      assert entry.credential_slug == slug
      assert entry.credential_scope_type == "platform"
    end

    test "a refused delete stamps the credential's slug and scope onto the denied entry" do
      owner = Ecto.UUID.generate()
      stranger = Ecto.UUID.generate()
      slug = unique_slug("log-denied")
      {:ok, cred} = Vault.put(slug, :api_key, "v1", scope: {:agent, owner})

      assert {:error, :access_denied} = Vault.delete(slug, accessor: {:agent, stranger})

      assert [entry] = logs_for_slug(slug)
      assert entry.action == "denied"
      assert entry.credential_id == cred.id
      assert entry.credential_slug == slug
      assert entry.credential_scope_type == "agent"
      assert entry.accessor_id == stranger
    end
  end

  describe "retention at the database level" do
    test "a raw Repo.delete leaves the log rows in place with credential_id nulled" do
      owner = Ecto.UUID.generate()
      slug = unique_slug("log-retain")
      {:ok, cred} = Vault.put(slug, :api_key, "v1", scope: {:agent, owner})

      assert {:ok, "v1"} = Vault.get(slug, accessor: {:agent, owner})
      assert {:ok, _} = Vault.rotate(slug, "v2", accessor: {:agent, owner})
      assert length(logs_for_slug(slug)) == 2

      # Deliberately NOT Vault.delete/2 — this has to hold for any writer that
      # reaches the table, including a console session or a future context that
      # forgets the vault's rules.
      assert {:ok, _} = Repo.delete(cred)

      assert is_nil(Repo.get(Credential, cred.id))

      entries = logs_for_slug(slug)
      assert length(entries) == 2
      assert Enum.map(entries, & &1.action) == ["use", "rotate"]

      for entry <- entries do
        assert is_nil(entry.credential_id)
        assert entry.credential_slug == slug
        assert entry.credential_scope_type == "agent"
        assert entry.accessor_id == owner
      end
    end

    test "grants are still cascaded away by a raw delete — only the log is retained" do
      owner = Ecto.UUID.generate()
      stranger = Ecto.UUID.generate()
      slug = unique_slug("log-grants")
      {:ok, cred} = Vault.put(slug, :api_key, "v1", scope: {:agent, owner})

      Repo.insert!(%AccessGrant{
        credential_id: cred.id,
        grantee_type: "agent",
        grantee_id: stranger,
        permissions: ["use"]
      })

      assert {:ok, "v1"} = Vault.get(slug, accessor: {:agent, stranger})
      assert {:ok, _} = Repo.delete(cred)

      assert Repo.all(from(g in AccessGrant, where: g.credential_id == ^cred.id)) == []
      assert [entry] = logs_for_slug(slug)
      assert is_nil(entry.credential_id)
      assert entry.accessor_id == stranger
    end

    test "the slug is reusable after deletion and new entries are distinguishable" do
      owner = Ecto.UUID.generate()
      slug = unique_slug("log-reuse")
      {:ok, first} = Vault.put(slug, :api_key, "v1", scope: {:agent, owner})

      assert {:ok, "v1"} = Vault.get(slug, accessor: {:agent, owner})
      assert {:ok, _} = Repo.delete(first)

      # Retention must not block re-creating a credential at the same slug —
      # that is the regression a soft-delete scheme would have introduced.
      assert {:ok, second} = Vault.put(slug, :api_key, "v2", scope: {:agent, owner})
      assert second.id != first.id
      assert {:ok, "v2"} = Vault.get(slug, accessor: {:agent, owner})

      assert [old, new] = logs_for_slug(slug)
      assert is_nil(old.credential_id)
      assert new.credential_id == second.id
    end
  end
end
