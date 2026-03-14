defmodule Platform.VaultTest do
  use Platform.DataCase, async: true

  import Ecto.Query

  alias Platform.Vault
  alias Platform.Vault.AccessGrant
  alias Platform.Vault.AccessLog
  alias Platform.Vault.Credential

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp unique_slug(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp insert_credential!(slug, opts) do
    value = Keyword.get(opts, :value, "default-secret")
    scope = Keyword.get(opts, :scope, {:platform, nil})
    extra = Keyword.drop(opts, [:value])
    {:ok, cred} = Vault.put(slug, :api_key, value, [scope: scope] ++ extra)
    cred
  end

  # ── put/4 ────────────────────────────────────────────────────────────────────

  describe "put/4" do
    test "stores a credential and returns without decrypted data" do
      slug = unique_slug("put")

      assert {:ok, cred} =
               Vault.put(slug, :api_key, "super-secret",
                 scope: {:platform, nil},
                 provider: "stripe",
                 name: "Stripe API Key"
               )

      assert cred.slug == slug
      assert cred.credential_type == "api_key"
      assert cred.provider == "stripe"
      assert cred.name == "Stripe API Key"
      assert cred.scope_type == "platform"
      assert is_nil(cred.encrypted_data), "encrypted_data must be stripped from put result"
      assert is_binary(cred.id)
    end

    test "value is encrypted at rest (round-trips correctly via get)" do
      slug = unique_slug("enc")
      {:ok, _} = Vault.put(slug, :token, "plaintext-secret", scope: {:platform, nil})

      # The raw DB row should have encrypted bytes, not the plaintext string.
      # We verify the round-trip: get/2 should return the original plaintext.
      assert {:ok, "plaintext-secret"} = Vault.get(slug)
    end

    test "emits credential_created telemetry" do
      slug = unique_slug("tel")

      ref =
        :telemetry_test.attach_event_handlers(self(), [[:platform, :vault, :credential_created]])

      {:ok, cred} = Vault.put(slug, :api_key, "value", scope: {:platform, nil})

      assert_receive {[:platform, :vault, :credential_created], ^ref, _measurements, meta}
      assert meta.credential_id == cred.id
      assert meta.slug == slug

      :telemetry.detach(ref)
    end
  end

  # ── get/2 ────────────────────────────────────────────────────────────────────

  describe "get/2" do
    setup do
      slug = unique_slug("get")
      insert_credential!(slug, value: "my-secret-value", scope: {:platform, nil})
      %{slug: slug}
    end

    test "decrypts and returns value for a valid accessor", %{slug: slug} do
      assert {:ok, "my-secret-value"} = Vault.get(slug)
    end

    test "returns :not_found for an unknown slug" do
      assert {:error, :not_found} = Vault.get("does-not-exist-#{System.unique_integer()}")
    end

    test "updates last_used_at on successful access", %{slug: slug} do
      before_get = Repo.get_by!(Credential, slug: slug)
      assert is_nil(before_get.last_used_at)

      {:ok, _} = Vault.get(slug)

      after_get = Repo.get_by!(Credential, slug: slug)
      assert %DateTime{} = after_get.last_used_at
    end

    test "emits credential_used telemetry", %{slug: slug} do
      ref = :telemetry_test.attach_event_handlers(self(), [[:platform, :vault, :credential_used]])

      {:ok, _} = Vault.get(slug)

      assert_receive {[:platform, :vault, :credential_used], ^ref, _measurements, meta}
      assert meta.slug == slug

      :telemetry.detach(ref)
    end

    test "writes an access log entry on successful get", %{slug: slug} do
      cred = Repo.get_by!(Credential, slug: slug)
      agent_id = Ecto.UUID.generate()

      {:ok, _} = Vault.get(slug, accessor: {:agent, agent_id})

      log =
        from(l in AccessLog,
          where: l.credential_id == ^cred.id and l.action == "use",
          limit: 1
        )
        |> Repo.one()

      assert log != nil
      assert log.accessor_type == "agent"
      assert log.accessor_id == agent_id
    end
  end

  # ── get/2 — access control ───────────────────────────────────────────────────

  describe "get/2 access control" do
    test "platform-scoped credential is accessible by any accessor" do
      slug = unique_slug("plat")
      insert_credential!(slug, value: "platform-secret", scope: {:platform, nil})

      agent_id = Ecto.UUID.generate()

      # nil accessor (anonymous)
      assert {:ok, "platform-secret"} = Vault.get(slug)
      # named accessor
      assert {:ok, "platform-secret"} = Vault.get(slug, accessor: {:agent, agent_id})
    end

    test "agent-scoped credential is accessible only by the owning agent" do
      owner_id = Ecto.UUID.generate()
      other_id = Ecto.UUID.generate()
      slug = unique_slug("agt")

      insert_credential!(slug, value: "agent-secret", scope: {:agent, owner_id})

      assert {:ok, "agent-secret"} = Vault.get(slug, accessor: {:agent, owner_id})
      assert {:error, :access_denied} = Vault.get(slug, accessor: {:agent, other_id})
    end

    test "agent-scoped credential is denied when no accessor is given" do
      owner_id = Ecto.UUID.generate()
      slug = unique_slug("agt-nil")

      insert_credential!(slug, value: "secret", scope: {:agent, owner_id})

      assert {:error, :access_denied} = Vault.get(slug)
    end

    test "explicit grant allows cross-scope access" do
      owner_id = Ecto.UUID.generate()
      grantee_id = Ecto.UUID.generate()
      slug = unique_slug("grant")

      {:ok, cred} = Vault.put(slug, :api_key, "granted-secret", scope: {:agent, owner_id})

      Repo.insert!(%AccessGrant{
        credential_id: cred.id,
        grantee_type: "agent",
        grantee_id: grantee_id,
        permissions: ["use"]
      })

      # Grantee can access even though the credential is scoped to a different agent.
      assert {:ok, "granted-secret"} = Vault.get(slug, accessor: {:agent, grantee_id})
    end

    test "no explicit grant means access is denied for cross-scope access" do
      owner_id = Ecto.UUID.generate()
      stranger_id = Ecto.UUID.generate()
      slug = unique_slug("no-grant")

      insert_credential!(slug, value: "secret", scope: {:agent, owner_id})

      assert {:error, :access_denied} = Vault.get(slug, accessor: {:agent, stranger_id})
    end

    test "emits access_denied telemetry when access is refused" do
      owner_id = Ecto.UUID.generate()
      other_id = Ecto.UUID.generate()
      slug = unique_slug("deny-tel")

      insert_credential!(slug, value: "secret", scope: {:agent, owner_id})

      ref =
        :telemetry_test.attach_event_handlers(self(), [[:platform, :vault, :access_denied]])

      assert {:error, :access_denied} = Vault.get(slug, accessor: {:agent, other_id})

      assert_receive {[:platform, :vault, :access_denied], ^ref, _measurements, meta}
      assert meta.slug == slug

      :telemetry.detach(ref)
    end
  end

  # ── rotate/3 ─────────────────────────────────────────────────────────────────

  describe "rotate/3" do
    test "replaces the encrypted value; old slug still resolves to new value" do
      slug = unique_slug("rotate")
      insert_credential!(slug, value: "old-value", scope: {:platform, nil})

      assert {:ok, "old-value"} = Vault.get(slug)

      assert {:ok, rotated} = Vault.rotate(slug, "new-value")
      assert rotated.slug == slug
      assert is_nil(rotated.encrypted_data), "encrypted_data must be stripped from rotate result"

      assert {:ok, "new-value"} = Vault.get(slug)
    end

    test "sets rotated_at timestamp" do
      slug = unique_slug("rotate-ts")
      insert_credential!(slug, value: "value", scope: {:platform, nil})

      before = Repo.get_by!(Credential, slug: slug)
      assert is_nil(before.rotated_at)

      {:ok, _} = Vault.rotate(slug, "new-value")

      after_rotate = Repo.get_by!(Credential, slug: slug)
      assert %DateTime{} = after_rotate.rotated_at
    end

    test "emits credential_rotated telemetry" do
      slug = unique_slug("rotate-tel")
      insert_credential!(slug, value: "value", scope: {:platform, nil})

      ref =
        :telemetry_test.attach_event_handlers(self(), [[:platform, :vault, :credential_rotated]])

      {:ok, _} = Vault.rotate(slug, "new-value")

      assert_receive {[:platform, :vault, :credential_rotated], ^ref, _measurements, meta}
      assert meta.slug == slug

      :telemetry.detach(ref)
    end

    test "returns :not_found for an unknown slug" do
      assert {:error, :not_found} = Vault.rotate("nonexistent-#{System.unique_integer()}", "v")
    end
  end

  # ── list/1 ───────────────────────────────────────────────────────────────────

  describe "list/1" do
    setup do
      s1 = unique_slug("list-gh")
      s2 = unique_slug("list-st")
      s3 = unique_slug("list-agt")
      agent_id = Ecto.UUID.generate()

      insert_credential!(s1, value: "gh-secret", provider: "github", scope: {:platform, nil})
      insert_credential!(s2, value: "st-secret", provider: "stripe", scope: {:platform, nil})
      insert_credential!(s3, value: "agt-secret", scope: {:agent, agent_id})

      %{github_slug: s1, stripe_slug: s2, agent_slug: s3, agent_id: agent_id}
    end

    test "returns credential metadata without encrypted_data keys", %{
      github_slug: s1,
      stripe_slug: s2
    } do
      results = Vault.list()
      slugs = Enum.map(results, & &1.slug)

      assert s1 in slugs
      assert s2 in slugs

      Enum.each(results, fn r ->
        refute Map.has_key?(r, :encrypted_data),
               "list/1 must not expose encrypted_data; got: #{inspect(Map.keys(r))}"
      end)
    end

    test "filters by provider", %{github_slug: s1, stripe_slug: s2} do
      results = Vault.list(provider: "github")
      slugs = Enum.map(results, & &1.slug)

      assert s1 in slugs
      refute s2 in slugs
    end

    test "filters by credential_type" do
      token_slug = unique_slug("list-tok")
      insert_credential!(token_slug, scope: {:platform, nil})

      results = Vault.list(credential_type: :api_key)
      slugs = Enum.map(results, & &1.slug)

      assert token_slug in slugs
    end

    test "filters by scope", %{agent_slug: s3, agent_id: agent_id} do
      results = Vault.list(scope: {:agent, agent_id})
      slugs = Enum.map(results, & &1.slug)

      assert s3 in slugs
    end
  end

  # ── delete/2 ─────────────────────────────────────────────────────────────────

  describe "delete/2" do
    test "removes the credential" do
      slug = unique_slug("del")
      insert_credential!(slug, scope: {:platform, nil})

      assert {:ok, _} = Vault.delete(slug)
      assert Repo.get_by(Credential, slug: slug) == nil
    end

    test "cascades deletion to access grants" do
      agent_id = Ecto.UUID.generate()
      slug = unique_slug("del-grants")
      {:ok, cred} = Vault.put(slug, :api_key, "secret", scope: {:platform, nil})

      Repo.insert!(%AccessGrant{
        credential_id: cred.id,
        grantee_type: "agent",
        grantee_id: agent_id,
        permissions: ["use"]
      })

      assert {:ok, _} = Vault.delete(slug)

      grants = from(g in AccessGrant, where: g.credential_id == ^cred.id) |> Repo.all()
      assert grants == [], "grants should be deleted along with credential"
    end

    test "emits credential_revoked telemetry" do
      slug = unique_slug("del-tel")
      insert_credential!(slug, scope: {:platform, nil})

      ref =
        :telemetry_test.attach_event_handlers(self(), [[:platform, :vault, :credential_revoked]])

      assert {:ok, _} = Vault.delete(slug)

      assert_receive {[:platform, :vault, :credential_revoked], ^ref, _measurements, meta}
      assert meta.slug == slug

      :telemetry.detach(ref)
    end

    test "returns :not_found for an unknown slug" do
      assert {:error, :not_found} = Vault.delete("no-such-cred-#{System.unique_integer()}")
    end
  end

  # ── expiring_soon/1 ───────────────────────────────────────────────────────────

  describe "expiring_soon/1" do
    test "finds credentials expiring within the default 7-day window" do
      # Expires in 3 days — within default window.
      soon_slug = unique_slug("exp-soon")

      soon_at = DateTime.add(DateTime.utc_now(), 3 * 86_400, :second)
      insert_credential!(soon_slug, scope: {:platform, nil}, expires_at: soon_at)

      # Expires in 30 days — outside default window.
      later_slug = unique_slug("exp-later")
      later_at = DateTime.add(DateTime.utc_now(), 30 * 86_400, :second)
      insert_credential!(later_slug, scope: {:platform, nil}, expires_at: later_at)

      results = Vault.expiring_soon()
      slugs = Enum.map(results, & &1.slug)

      assert soon_slug in slugs
      refute later_slug in slugs
    end

    test "respects a custom :within window" do
      slug = unique_slug("exp-custom")
      # Expires in 2 days.
      at = DateTime.add(DateTime.utc_now(), 2 * 86_400, :second)
      insert_credential!(slug, scope: {:platform, nil}, expires_at: at)

      # 1-day window — not found.
      result_1d = Vault.expiring_soon(within: {1, :days})
      refute slug in Enum.map(result_1d, & &1.slug)

      # 3-day window — found.
      result_3d = Vault.expiring_soon(within: {3, :days})
      assert slug in Enum.map(result_3d, & &1.slug)
    end

    test "does not include credentials without an expiry date" do
      slug = unique_slug("exp-nil")
      insert_credential!(slug, scope: {:platform, nil})

      results = Vault.expiring_soon()
      refute slug in Enum.map(results, & &1.slug)
    end

    test "returns stripped credentials (no encrypted_data)" do
      slug = unique_slug("exp-strip")
      at = DateTime.add(DateTime.utc_now(), 1 * 86_400, :second)
      insert_credential!(slug, scope: {:platform, nil}, expires_at: at)

      results = Vault.expiring_soon(within: {2, :days})
      match = Enum.find(results, &(&1.slug == slug))

      assert match != nil
      assert is_nil(match.encrypted_data)
    end
  end
end
