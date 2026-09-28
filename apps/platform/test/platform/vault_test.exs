defmodule Platform.VaultTest do
  use Platform.DataCase, async: true

  import Ecto.Query
  import ExUnit.CaptureLog

  require Logger

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

  defp grant!(%Credential{id: credential_id}, grantee_id, permissions) do
    Repo.insert!(%AccessGrant{
      credential_id: credential_id,
      grantee_type: "agent",
      grantee_id: grantee_id,
      permissions: permissions
    })
  end

  defp logs_for(%Credential{id: credential_id}) do
    from(l in AccessLog, where: l.credential_id == ^credential_id, order_by: [asc: l.inserted_at])
    |> Repo.all()
  end

  # Matches on the denormalised slug rather than the association, so it keeps
  # working after the credential — and therefore credential_id — is gone.
  defp logs_for_slug(slug) do
    from(l in AccessLog,
      where: l.credential_slug == ^slug,
      order_by: [asc: l.inserted_at, asc: l.id]
    )
    |> Repo.all()
  end

  defp actions_for(%Credential{} = cred) do
    cred |> logs_for() |> Enum.map(& &1.action) |> Enum.sort()
  end

  # Both rows are legitimate rotate targets for `owner_id`: it owns the
  # agent-scoped one outright and holds an explicit "rotate" grant on the
  # platform-scoped one. That is what makes the untouched-row assertions
  # below non-vacuous — under a slug-only lookup either row really can be the
  # one that moves, and `insert_order` decides which.
  defp ambiguous_pair!(slug, owner_id, insert_order) do
    {platform, agent} =
      case insert_order do
        :platform_first ->
          p = insert_credential!(slug, value: "PLATFORM-V1", scope: {:platform, nil})
          a = insert_credential!(slug, value: "AGENT-V1", scope: {:agent, owner_id})
          {p, a}

        :agent_first ->
          a = insert_credential!(slug, value: "AGENT-V1", scope: {:agent, owner_id})
          p = insert_credential!(slug, value: "PLATFORM-V1", scope: {:platform, nil})
          {p, a}
      end

    grant!(platform, owner_id, ["use", "rotate"])
    {platform, agent}
  end

  defp reload(%Credential{id: id}), do: Repo.get!(Credential, id)

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

  # ── put/4 slug uniqueness ────────────────────────────────────────────────────

  # `vault_credentials_unique_slug_per_scope` covers
  # `(workspace_id, scope_type, scope_id, slug)`. It shipped without a
  # `nulls_distinct:` option, so Postgres built it NULLS DISTINCT and it skipped
  # the conflict check whenever ANY of those columns was NULL. Two are nullable,
  # and nothing in `lib/` ever passes `:workspace_id`, so in practice it
  # rejected nothing at any scope.
  #
  # `20260829140000_enforce_vault_slug_uniqueness_across_null_scopes` rebuilds it
  # NULLS NOT DISTINCT. These tests pin both halves of that: duplicates within a
  # scope are refused, and the same slug ACROSS scopes still inserts.
  describe "put/4 slug uniqueness within a scope" do
    defp credential_count(slug) do
      Repo.one(from(c in Credential, where: c.slug == ^slug, select: count(c.id)))
    end

    defp assert_slug_taken(result) do
      assert {:error, %Ecto.Changeset{} = changeset} = result
      assert {"has already been taken", meta} = changeset.errors[:slug]

      assert meta[:constraint_name] == "vault_credentials_unique_slug_per_scope",
             "expected the unique-slug index to be the constraint that fired, got #{inspect(meta)}"

      changeset
    end

    test "a second credential with the same slug at {:platform, nil} is refused" do
      slug = unique_slug("dup-platform")

      assert {:ok, _} = Vault.put(slug, :api_key, "first", scope: {:platform, nil})

      assert_slug_taken(Vault.put(slug, :api_key, "second", scope: {:platform, nil}))

      assert credential_count(slug) == 1
      # The row that survives is the one that was already there — a refused
      # insert must not have overwritten the live value.
      assert {:ok, "first"} = Vault.get(slug)
    end

    test "a duplicate at agent scope is refused — a NULL workspace_id alone had disabled the index" do
      # The ticket framed this as a platform-scope defect, on the reasoning that
      # `{:platform, nil}` nulls both `workspace_id` and `scope_id`. Measured on
      # Postgres 16.14, an agent-scoped pair with a populated `scope_id` also
      # inserted twice before the migration: one NULL column is enough.
      slug = unique_slug("dup-agent")
      agent_id = Ecto.UUID.generate()

      assert {:ok, _} = Vault.put(slug, :api_key, "first", scope: {:agent, agent_id})

      assert_slug_taken(Vault.put(slug, :api_key, "second", scope: {:agent, agent_id}))

      assert credential_count(slug) == 1
    end

    test "a duplicate with a populated workspace_id and a NULL scope_id is refused" do
      slug = unique_slug("dup-ws-platform")
      workspace_id = Ecto.UUID.generate()

      assert {:ok, _} =
               Vault.put(slug, :api_key, "first",
                 scope: {:platform, nil},
                 workspace_id: workspace_id
               )

      assert_slug_taken(
        Vault.put(slug, :api_key, "second", scope: {:platform, nil}, workspace_id: workspace_id)
      )

      assert credential_count(slug) == 1
    end

    test "a duplicate with every indexed column populated is refused" do
      # POSITIVE CONTROL for the three tests above. This is the one shape that
      # collided BEFORE the migration too, because no indexed column is NULL.
      # It fails only if the index is missing or misnamed outright, so it
      # discriminates "the constraint mechanism works" from "the NULL handling
      # changed" — the assertions above are about the second.
      slug = unique_slug("dup-full")
      workspace_id = Ecto.UUID.generate()
      agent_id = Ecto.UUID.generate()
      opts = [scope: {:agent, agent_id}, workspace_id: workspace_id]

      assert {:ok, _} = Vault.put(slug, :api_key, "first", opts)

      assert_slug_taken(Vault.put(slug, :api_key, "second", opts))

      assert credential_count(slug) == 1
    end
  end

  describe "put/4 slug uniqueness stays per scope, not global" do
    test "the same slug at three different scope_types all insert" do
      slug = unique_slug("cross-scope")
      agent_id = Ecto.UUID.generate()
      integration_id = Ecto.UUID.generate()

      assert {:ok, _} = Vault.put(slug, :api_key, "platform-value", scope: {:platform, nil})
      assert {:ok, _} = Vault.put(slug, :api_key, "agent-value", scope: {:agent, agent_id})

      assert {:ok, _} =
               Vault.put(slug, :api_key, "integration-value",
                 scope: {:integration, integration_id}
               )

      assert credential_count(slug) == 3
    end

    test "the same slug for two different agents both insert" do
      slug = unique_slug("cross-agent")

      assert {:ok, _} = Vault.put(slug, :api_key, "a", scope: {:agent, Ecto.UUID.generate()})
      assert {:ok, _} = Vault.put(slug, :api_key, "b", scope: {:agent, Ecto.UUID.generate()})

      assert credential_count(slug) == 2
    end

    test "the same slug under two different workspace_ids both insert" do
      # NULLS NOT DISTINCT makes NULL compare equal to NULL. It must not make
      # two DISTINCT non-NULL workspace ids compare equal to each other.
      slug = unique_slug("cross-workspace")

      assert {:ok, _} =
               Vault.put(slug, :api_key, "a",
                 scope: {:platform, nil},
                 workspace_id: Ecto.UUID.generate()
               )

      assert {:ok, _} =
               Vault.put(slug, :api_key, "b",
                 scope: {:platform, nil},
                 workspace_id: Ecto.UUID.generate()
               )

      assert credential_count(slug) == 2
    end

    test "a NULL workspace_id does not collide with a populated one at the same scope" do
      slug = unique_slug("null-vs-ws")

      assert {:ok, _} = Vault.put(slug, :api_key, "no-workspace", scope: {:platform, nil})

      assert {:ok, _} =
               Vault.put(slug, :api_key, "with-workspace",
                 scope: {:platform, nil},
                 workspace_id: Ecto.UUID.generate()
               )

      assert credential_count(slug) == 2
    end
  end

  # Enforcing the constraint makes `put/4`'s `{:error, changeset}` path reachable
  # for the first time, and that changeset carries the submitted value under
  # `changes.encrypted_data` — Cloak encrypts on dump, so in memory it is
  # plaintext. `Platform.Vault.Credential` marks the field `redact: true` so
  # every `inspect/1` of it prints `**redacted**`.
  describe "put/4 rejection does not expose the submitted secret" do
    test "an inspected rejection changeset does not carry the plaintext into the log" do
      slug = unique_slug("redact-log")
      secret = "sk-live-#{System.unique_integer([:positive])}-NEVER-LOG-ME"

      {:ok, _} = Vault.put(slug, :api_key, secret, scope: {:platform, nil})

      log =
        capture_log(fn ->
          assert {:error, %Ecto.Changeset{} = changeset} =
                   Vault.put(slug, :api_key, secret, scope: {:platform, nil})

          Logger.error("vault: could not store #{slug}: #{inspect(changeset)}")
        end)

      # CONTROL. Without these the refutation below would also pass against an
      # empty log, a log that never reached this credential, or a changeset
      # inspected down to `#Ecto.Changeset<...>` with no changes in it at all.
      assert log =~ slug, "the log line must name the credential it is about"
      assert log =~ "has already been taken", "the log line must carry the constraint error"
      assert log =~ "**redacted**", "the changeset must show the field, redacted"

      # REFUTATION.
      refute log =~ secret
    end

    test "the MatchError from a hard-matched put/4 does not carry the plaintext" do
      # `Platform.Agents.Config.import_auth_profile!/4` writes
      # `{:ok, credential} = Platform.Vault.put(...)`. A refused duplicate now
      # raises here, and an exception message is built with `inspect/1`.
      slug = unique_slug("redact-matcherror")
      secret = "sk-live-#{System.unique_integer([:positive])}-NEVER-RAISE-ME"

      {:ok, _} = Vault.put(slug, :api_key, secret, scope: {:platform, nil})

      message =
        try do
          {:ok, _credential} = Vault.put(slug, :api_key, secret, scope: {:platform, nil})
          flunk("expected the duplicate slug to be refused")
        rescue
          error in MatchError -> Exception.message(error)
        end

      # CONTROL: the message really is the inspected rejection changeset.
      assert message =~ "has already been taken"
      assert message =~ slug
      assert message =~ "**redacted**"

      # REFUTATION.
      refute message =~ secret
    end

    test "inspecting the stored credential struct does not print the value" do
      slug = unique_slug("redact-struct")
      secret = "sk-live-#{System.unique_integer([:positive])}-NEVER-INSPECT-ME"

      {:ok, _} = Vault.put(slug, :api_key, secret, scope: {:platform, nil})
      loaded = Repo.get_by!(Credential, slug: slug)

      # CONTROL: the struct is loaded, decrypted and really does hold the value.
      assert loaded.encrypted_data == secret
      rendered = inspect(loaded)
      assert rendered =~ slug

      # REFUTATION.
      refute rendered =~ secret
    end
  end

  # ── put_inline/2 ─────────────────────────────────────────────────────────────

  describe "put_inline/2" do
    test "fresh insert round-trips via Vault.get/2 and strips encrypted_data" do
      slug = unique_slug("inline")

      assert {:ok, cred} = Vault.put_inline(slug, "inline-secret")
      assert cred.slug == slug
      assert cred.scope_type == "platform"
      assert is_nil(cred.scope_id)
      assert cred.credential_type == "api_key"
      assert cred.provider == "external_agent"
      assert cred.name == slug
      assert is_nil(cred.encrypted_data), "encrypted_data must be stripped from put_inline result"

      assert {:ok, "inline-secret"} = Vault.get(slug)
    end

    test "second call with same vault_key updates the secret and bumps rotated_at" do
      slug = unique_slug("inline-rot")

      assert {:ok, _} = Vault.put_inline(slug, "v1")
      first_row = Repo.get_by!(Credential, slug: slug)
      assert is_nil(first_row.rotated_at)
      assert {:ok, "v1"} = Vault.get(slug)

      # Force a measurable time gap so strict-greater comparison is meaningful.
      Process.sleep(5)

      assert {:ok, _} = Vault.put_inline(slug, "v2")
      second_row = Repo.get_by!(Credential, slug: slug)

      assert second_row.id == first_row.id, "upsert must update in-place, not insert a new row"
      assert %DateTime{} = second_row.rotated_at
      assert DateTime.compare(second_row.rotated_at, DateTime.utc_now()) in [:lt, :eq]

      assert {:ok, "v2"} = Vault.get(slug)
    end

    test "idempotent on vault_key — repeated calls yield exactly one row" do
      slug = unique_slug("inline-idem")

      assert {:ok, _} = Vault.put_inline(slug, "a")
      assert {:ok, _} = Vault.put_inline(slug, "b")
      assert {:ok, _} = Vault.put_inline(slug, "c")

      count = Repo.aggregate(from(c in Credential, where: c.slug == ^slug), :count)
      assert count == 1
      assert {:ok, "c"} = Vault.get(slug)
    end

    test "two successive upserts bump rotated_at strictly forward" do
      slug = unique_slug("inline-ts")

      assert {:ok, _} = Vault.put_inline(slug, "v1")
      # Second call sets rotated_at for the first time.
      Process.sleep(5)
      assert {:ok, _} = Vault.put_inline(slug, "v2")
      ts2 = Repo.get_by!(Credential, slug: slug).rotated_at
      assert %DateTime{} = ts2

      Process.sleep(5)
      assert {:ok, _} = Vault.put_inline(slug, "v3")
      ts3 = Repo.get_by!(Credential, slug: slug).rotated_at

      assert DateTime.compare(ts3, ts2) == :gt,
             "rotated_at must move strictly forward across successive upserts"
    end

    test "persists encrypted_data through Cloak (not plaintext at rest)" do
      slug = unique_slug("inline-enc")

      assert {:ok, _} = Vault.put_inline(slug, "plaintext-inline")

      # Query the raw bytes via a select that bypasses the Cloak-decoded field type.
      [raw] =
        from(c in "vault_credentials",
          where: c.slug == ^slug,
          select: c.encrypted_data
        )
        |> Repo.all()

      assert is_binary(raw)
      refute raw == "plaintext-inline", "Cloak must encrypt the value at rest"

      # And confirm the standard read path decrypts to the original.
      assert {:ok, "plaintext-inline"} = Vault.get(slug)
    end

    test "emits credential_created telemetry on initial insert" do
      slug = unique_slug("inline-tel-create")

      ref =
        :telemetry_test.attach_event_handlers(self(), [[:platform, :vault, :credential_created]])

      {:ok, cred} = Vault.put_inline(slug, "secret")

      assert_receive {[:platform, :vault, :credential_created], ^ref, _measurements, meta}
      assert meta.credential_id == cred.id
      assert meta.slug == slug
      assert meta.scope_type == "platform"

      :telemetry.detach(ref)
    end

    test "emits credential_rotated telemetry on upsert" do
      slug = unique_slug("inline-tel-rotate")
      assert {:ok, _} = Vault.put_inline(slug, "v1")

      ref =
        :telemetry_test.attach_event_handlers(self(), [[:platform, :vault, :credential_rotated]])

      {:ok, cred} = Vault.put_inline(slug, "v2")

      assert_receive {[:platform, :vault, :credential_rotated], ^ref, _measurements, meta}
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

    test "without :scope an ambiguous slug is refused and neither row is touched" do
      owner_id = Ecto.UUID.generate()
      slug = unique_slug("get-ambiguous")
      {platform, agent} = ambiguous_pair!(slug, owner_id, :platform_first)

      assert {:error, :ambiguous_slug} = Vault.get(slug, accessor: {:agent, owner_id})

      for cred <- [platform, agent] do
        row = reload(cred)
        assert is_nil(row.last_used_at)
      end

      logs = logs_for_slug(slug)
      refute Enum.any?(logs, &(&1.action == "use"))
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

      assert {:ok, rotated} = Vault.rotate(slug, "new-value", accessor: {:system, nil})
      assert rotated.slug == slug
      assert is_nil(rotated.encrypted_data), "encrypted_data must be stripped from rotate result"

      assert {:ok, "new-value"} = Vault.get(slug)
    end

    test "sets rotated_at timestamp" do
      slug = unique_slug("rotate-ts")
      insert_credential!(slug, value: "value", scope: {:platform, nil})

      before = Repo.get_by!(Credential, slug: slug)
      assert is_nil(before.rotated_at)

      {:ok, _} = Vault.rotate(slug, "new-value", accessor: {:system, nil})

      after_rotate = Repo.get_by!(Credential, slug: slug)
      assert %DateTime{} = after_rotate.rotated_at
    end

    test "emits credential_rotated telemetry" do
      slug = unique_slug("rotate-tel")
      insert_credential!(slug, value: "value", scope: {:platform, nil})

      ref =
        :telemetry_test.attach_event_handlers(self(), [[:platform, :vault, :credential_rotated]])

      {:ok, _} = Vault.rotate(slug, "new-value", accessor: {:system, nil})

      assert_receive {[:platform, :vault, :credential_rotated], ^ref, _measurements, meta}
      assert meta.slug == slug

      :telemetry.detach(ref)
    end

    test "returns :not_found for an unknown slug" do
      assert {:error, :not_found} = Vault.rotate("nonexistent-#{System.unique_integer()}", "v")
    end
  end

  # ── rotate/3 — target selection ──────────────────────────────────────────────
  #
  # Uniqueness is per scope (`vault_credentials_unique_slug_per_scope` covers
  # `(workspace_id, scope_type, scope_id, slug)`), so one slug can name more
  # than one credential and a slug-only `limit: 1` with no `order_by` has no
  # defined target. These tests pin which row moves and, just as importantly,
  # that the other one does not.

  describe "rotate/3 target selection" do
    test "the positive control: an unambiguous slug still rotates, with or without :scope" do
      owner_id = Ecto.UUID.generate()

      unscoped = unique_slug("target-control-unscoped")
      cred = insert_credential!(unscoped, value: "V1", scope: {:agent, owner_id})
      assert {:ok, _} = Vault.rotate(unscoped, "V2", accessor: {:agent, owner_id})
      assert reload(cred).encrypted_data == "V2"

      scoped = unique_slug("target-control-scoped")
      cred2 = insert_credential!(scoped, value: "V1", scope: {:agent, owner_id})

      assert {:ok, _} =
               Vault.rotate(scoped, "V2",
                 scope: {:agent, owner_id},
                 accessor: {:agent, owner_id}
               )

      assert reload(cred2).encrypted_data == "V2"
    end

    test ":scope selects the agent-scoped row and leaves the platform-scoped one untouched" do
      owner_id = Ecto.UUID.generate()
      slug = unique_slug("target-agent")
      {platform, agent} = ambiguous_pair!(slug, owner_id, :platform_first)

      assert {:ok, _} =
               Vault.rotate(slug, "AGENT-V2",
                 scope: {:agent, owner_id},
                 accessor: {:agent, owner_id}
               )

      moved = reload(agent)
      assert moved.encrypted_data == "AGENT-V2"
      assert %DateTime{} = moved.rotated_at

      # The refutation that matters: read the other row's decrypted value and
      # its timestamp, not a row count. This is the assertion that goes red on
      # a slug-only lookup.
      untouched = reload(platform)
      assert untouched.encrypted_data == "PLATFORM-V1"
      assert is_nil(untouched.rotated_at)
    end

    test ":scope selects the platform-scoped row and leaves the agent-scoped one untouched" do
      owner_id = Ecto.UUID.generate()
      admin_id = Ecto.UUID.generate()
      slug = unique_slug("target-platform")
      {platform, agent} = ambiguous_pair!(slug, owner_id, :platform_first)

      assert {:ok, _} =
               Vault.rotate(slug, "PLATFORM-V2",
                 scope: {:platform, nil},
                 accessor: {:platform, admin_id}
               )

      moved = reload(platform)
      assert moved.encrypted_data == "PLATFORM-V2"
      assert %DateTime{} = moved.rotated_at

      untouched = reload(agent)
      assert untouched.encrypted_data == "AGENT-V1"
      assert is_nil(untouched.rotated_at)
    end

    test "insertion order does not decide which row rotates" do
      # The defect in one line: identical fixtures differing only in the order
      # the two rows were written, and a slug-only `limit: 1` follows the heap.
      # With :scope, both orders must land on the agent-scoped row.
      for order <- [:platform_first, :agent_first] do
        owner_id = Ecto.UUID.generate()
        slug = unique_slug("target-order-#{order}")
        {platform, agent} = ambiguous_pair!(slug, owner_id, order)

        assert {:ok, _} =
                 Vault.rotate(slug, "AGENT-V2",
                   scope: {:agent, owner_id},
                   accessor: {:agent, owner_id}
                 )

        assert reload(agent).encrypted_data == "AGENT-V2",
               "insert order #{order}: the agent-scoped row should have rotated"

        assert reload(platform).encrypted_data == "PLATFORM-V1",
               "insert order #{order}: the platform-scoped row must be untouched"

        assert is_nil(reload(platform).rotated_at),
               "insert order #{order}: the platform-scoped row must not be stamped"
      end
    end

    test "without :scope an ambiguous slug is refused and neither row is mutated" do
      owner_id = Ecto.UUID.generate()
      slug = unique_slug("target-ambiguous")
      {platform, agent} = ambiguous_pair!(slug, owner_id, :platform_first)

      assert {:error, :ambiguous_slug} =
               Vault.rotate(slug, "SHOULD-NOT-LAND", accessor: {:agent, owner_id})

      for cred <- [platform, agent] do
        row = reload(cred)
        refute row.encrypted_data == "SHOULD-NOT-LAND"
        assert is_nil(row.rotated_at)
      end

      assert reload(platform).encrypted_data == "PLATFORM-V1"
      assert reload(agent).encrypted_data == "AGENT-V1"
    end

    test "two rows at the SAME scope can no longer be created, so :scope now always resolves" do
      # This test used to build a same-scope pair and assert rotate/3 refused
      # it. `vault_credentials_unique_slug_per_scope` was NULLS DISTINCT, so
      # `(NULL, "platform", NULL, slug)` did not conflict with itself and put/4
      # created the pair happily. Task 01a04e18 rebuilt the index NULLS NOT
      # DISTINCT, so that pair is unreachable through put/4 and a scope
      # predicate now names at most one row by construction.
      #
      # The refusal branch itself still matters for rows that predate the
      # migration, and is covered against a deliberately relaxed index in
      # `Platform.Repo.Migrations.EnforceVaultSlugUniquenessAcrossNullScopesTest`.
      slug = unique_slug("target-same-scope")
      first = insert_credential!(slug, value: "FIRST-V1", scope: {:platform, nil})

      assert {:error, %Ecto.Changeset{} = changeset} =
               Vault.put(slug, :api_key, "SECOND-V1", scope: {:platform, nil})

      assert {"has already been taken", _} = changeset.errors[:slug]

      # And because there is only one row, the scoped rotation lands on it
      # instead of refusing.
      assert {:ok, _} =
               Vault.rotate(slug, "FIRST-V2",
                 scope: {:platform, nil},
                 accessor: {:system, nil}
               )

      assert reload(first).encrypted_data == "FIRST-V2"
    end

    test "the ambiguity refusal names the slug and the scopes but never the new value" do
      owner_id = Ecto.UUID.generate()
      slug = unique_slug("target-log")
      ambiguous_pair!(slug, owner_id, :platform_first)

      secret = "PLAINTEXT-#{System.unique_integer([:positive])}"

      log =
        capture_log(fn ->
          assert {:error, :ambiguous_slug} =
                   Vault.rotate(slug, secret, accessor: {:agent, owner_id})
        end)

      # Positive control on the capture itself: if this assertion passed while
      # the log were empty, the secret check below would prove nothing.
      assert log =~ slug
      assert log =~ "platform:nil"
      refute log =~ secret
    end

    test "a scoped rotation still keeps the row id and its access grants" do
      # #869 pinned this for do_rotate/4; target selection must not cost it.
      owner_id = Ecto.UUID.generate()
      grantee_id = Ecto.UUID.generate()
      slug = unique_slug("target-grants")

      cred = insert_credential!(slug, value: "V1", scope: {:agent, owner_id})
      grant = grant!(cred, grantee_id, ["use", "rotate"])

      assert {:ok, rotated} =
               Vault.rotate(slug, "V2",
                 scope: {:agent, owner_id},
                 accessor: {:agent, owner_id}
               )

      assert rotated.id == cred.id
      assert Repo.get(AccessGrant, grant.id)
      assert Repo.get(AccessGrant, grant.id).permissions == ["use", "rotate"]
    end
  end

  # ── rotate/3 — access control ────────────────────────────────────────────────

  describe "rotate/3 access control" do
    test "the owning agent may rotate its own credential" do
      owner_id = Ecto.UUID.generate()
      slug = unique_slug("rot-owner")
      insert_credential!(slug, value: "v1", scope: {:agent, owner_id})

      assert {:ok, rotated} = Vault.rotate(slug, "v2", accessor: {:agent, owner_id})
      assert is_nil(rotated.encrypted_data)
      assert {:ok, "v2"} = Vault.get(slug, accessor: {:agent, owner_id})
    end

    test "a use-only grantee may read but may not rotate" do
      owner_id = Ecto.UUID.generate()
      grantee_id = Ecto.UUID.generate()
      slug = unique_slug("rot-use-only")

      cred = insert_credential!(slug, value: "v1", scope: {:agent, owner_id})
      grant!(cred, grantee_id, ["use"])

      assert {:error, :access_denied} =
               Vault.rotate(slug, "pwned", accessor: {:agent, grantee_id})

      # Read authority is untouched, and the stored value never changed.
      assert {:ok, "v1"} = Vault.get(slug, accessor: {:agent, grantee_id})
    end

    test "a grantee holding \"rotate\" may rotate" do
      owner_id = Ecto.UUID.generate()
      rotator_id = Ecto.UUID.generate()
      slug = unique_slug("rot-granted")

      cred = insert_credential!(slug, value: "v1", scope: {:agent, owner_id})
      grant!(cred, rotator_id, ["use", "rotate"])

      assert {:ok, _} = Vault.rotate(slug, "v2", accessor: {:agent, rotator_id})
      assert {:ok, "v2"} = Vault.get(slug, accessor: {:agent, rotator_id})
    end

    test "a nil accessor may not rotate an agent-scoped credential" do
      owner_id = Ecto.UUID.generate()
      slug = unique_slug("rot-nil")
      insert_credential!(slug, value: "v1", scope: {:agent, owner_id})

      assert {:error, :access_denied} = Vault.rotate(slug, "pwned")
      assert {:ok, "v1"} = Vault.get(slug, accessor: {:agent, owner_id})
    end

    test "a non-privileged agent may not rotate a platform-scoped credential, but the system accessor may" do
      stranger_id = Ecto.UUID.generate()
      slug = unique_slug("rot-plat")
      insert_credential!(slug, value: "v1", scope: {:platform, nil})

      # Reading a platform credential is open — that is what the shared provider
      # keys depend on — but rotating one is not.
      assert {:ok, "v1"} = Vault.get(slug, accessor: {:agent, stranger_id})

      assert {:error, :access_denied} =
               Vault.rotate(slug, "pwned", accessor: {:agent, stranger_id})

      assert {:ok, "v1"} = Vault.get(slug, accessor: {:agent, stranger_id})

      assert {:ok, _} = Vault.rotate(slug, "v2", accessor: {:system, nil})
      assert {:ok, "v2"} = Vault.get(slug, accessor: {:agent, stranger_id})
    end

    test "a denied rotation leaves the stored value untouched and writes no rotate log row" do
      owner_id = Ecto.UUID.generate()
      stranger_id = Ecto.UUID.generate()
      slug = unique_slug("rot-untouched")

      cred = insert_credential!(slug, value: "v1", scope: {:agent, owner_id})

      assert {:error, :access_denied} =
               Vault.rotate(slug, "pwned", accessor: {:agent, stranger_id})

      row = Repo.get!(Credential, cred.id)
      assert is_nil(row.rotated_at), "a refused rotation must not stamp rotated_at"
      assert {:ok, "v1"} = Vault.get(slug, accessor: {:agent, owner_id})
      assert actions_for(cred) == ["denied", "use"]
    end

    test "a denied rotation writes a denied access-log row naming the accessor" do
      owner_id = Ecto.UUID.generate()
      stranger_id = Ecto.UUID.generate()
      slug = unique_slug("rot-deny-log")

      cred = insert_credential!(slug, value: "v1", scope: {:agent, owner_id})

      assert {:error, :access_denied} =
               Vault.rotate(slug, "pwned", accessor: {:agent, stranger_id})

      assert [log] = logs_for(cred)
      assert log.action == "denied"
      assert log.accessor_type == "agent"
      assert log.accessor_id == stranger_id
    end

    test "a denied rotation emits access_denied telemetry carrying the accessor" do
      owner_id = Ecto.UUID.generate()
      stranger_id = Ecto.UUID.generate()
      slug = unique_slug("rot-deny-tel")

      insert_credential!(slug, value: "v1", scope: {:agent, owner_id})

      ref = :telemetry_test.attach_event_handlers(self(), [[:platform, :vault, :access_denied]])

      assert {:error, :access_denied} =
               Vault.rotate(slug, "pwned", accessor: {:agent, stranger_id})

      assert_receive {[:platform, :vault, :access_denied], ^ref, _measurements, meta}
      assert meta.slug == slug
      assert meta.accessor == {:agent, stranger_id}

      :telemetry.detach(ref)
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

      assert {:ok, _} = Vault.delete(slug, accessor: {:system, nil})
      assert Repo.get_by(Credential, slug: slug) == nil
    end

    test "cascades deletion to access grants" do
      agent_id = Ecto.UUID.generate()
      slug = unique_slug("del-grants")
      {:ok, cred} = Vault.put(slug, :api_key, "secret", scope: {:platform, nil})

      grant!(cred, agent_id, ["use"])

      assert {:ok, _} = Vault.delete(slug, accessor: {:system, nil})

      grants = from(g in AccessGrant, where: g.credential_id == ^cred.id) |> Repo.all()
      assert grants == [], "grants should be deleted along with credential"
    end

    test "emits credential_revoked telemetry" do
      slug = unique_slug("del-tel")
      insert_credential!(slug, scope: {:platform, nil})

      ref =
        :telemetry_test.attach_event_handlers(self(), [[:platform, :vault, :credential_revoked]])

      assert {:ok, _} = Vault.delete(slug, accessor: {:system, nil})

      assert_receive {[:platform, :vault, :credential_revoked], ^ref, _measurements, meta}
      assert meta.slug == slug

      :telemetry.detach(ref)
    end

    test "returns :not_found for an unknown slug" do
      assert {:error, :not_found} = Vault.delete("no-such-cred-#{System.unique_integer()}")
    end

    test "without :scope an ambiguous slug is refused and nothing is deleted" do
      owner_id = Ecto.UUID.generate()
      slug = unique_slug("del-ambiguous")
      {platform, agent} = ambiguous_pair!(slug, owner_id, :platform_first)

      assert {:error, :ambiguous_slug} = Vault.delete(slug, accessor: {:system, nil})

      for cred <- [platform, agent] do
        assert Repo.get(Credential, cred.id) != nil
      end

      assert Repo.all(from(g in AccessGrant, where: g.credential_id == ^platform.id)) != [],
             "the platform row's grant should be untouched by a refused delete"

      logs = logs_for_slug(slug)
      refute Enum.any?(logs, &(&1.action == "revoke"))
    end

    test "a credential at a unique slug still deletes normally" do
      owner_id = Ecto.UUID.generate()
      slug = unique_slug("del-unique")
      cred = insert_credential!(slug, scope: {:agent, owner_id})
      grant!(cred, Ecto.UUID.generate(), ["use"])

      assert {:ok, _} = Vault.delete(slug, accessor: {:agent, owner_id})

      assert Repo.get(Credential, cred.id) == nil
      assert Repo.all(from(g in AccessGrant, where: g.credential_id == ^cred.id)) == []
      assert [%{action: "revoke"}] = logs_for_slug(slug)
    end
  end

  # ── delete/2 — access-log retention ──────────────────────────────────────────
  #
  # The point of the whole task's third defect. delete/2 used to purge these rows
  # in application code, so the "revoke" entry it writes was destroyed
  # microseconds after it was written and there was nothing to assert. The DB
  # half (ON DELETE SET NULL) landed in the previous stage and is proved
  # independently in test/platform/vault/access_log_test.exs via a raw
  # Repo.delete/1; these cases prove Vault.delete/2 itself no longer destroys the
  # trail it just wrote.

  describe "delete/2 access-log retention" do
    test "the revoke entry survives the deletion it recorded" do
      owner_id = Ecto.UUID.generate()
      slug = unique_slug("del-retain-revoke")

      cred = insert_credential!(slug, value: "v1", scope: {:agent, owner_id})

      assert {:ok, _} = Vault.delete(slug, accessor: {:agent, owner_id})
      assert Repo.get(Credential, cred.id) == nil

      assert [revoke] = logs_for_slug(slug)
      assert revoke.action == "revoke"
      assert is_nil(revoke.credential_id), "the FK is SET NULL, not CASCADE"
      assert revoke.credential_slug == slug
      assert revoke.credential_scope_type == "agent"
      assert revoke.accessor_type == "agent"
      assert revoke.accessor_id == owner_id
    end

    test "the pre-delete history survives too, not just the revoke entry" do
      owner_id = Ecto.UUID.generate()
      slug = unique_slug("del-retain-history")

      cred = insert_credential!(slug, value: "v1", scope: {:agent, owner_id})

      assert {:ok, "v1"} = Vault.get(slug, accessor: {:agent, owner_id})
      assert {:ok, "v1"} = Vault.get(slug, accessor: {:agent, owner_id})
      assert {:ok, _} = Vault.rotate(slug, "v2", accessor: {:agent, owner_id})
      assert length(logs_for(cred)) == 3

      assert {:ok, _} = Vault.delete(slug, accessor: {:agent, owner_id})

      entries = logs_for_slug(slug)
      assert Enum.map(entries, & &1.action) == ["use", "use", "rotate", "revoke"]
      assert Enum.all?(entries, &is_nil(&1.credential_id))
      assert Enum.all?(entries, &(&1.credential_slug == slug))
      assert Enum.all?(entries, &(&1.accessor_id == owner_id))
    end

    test "access_log/2 reads the retained trail back after the credential is gone" do
      owner_id = Ecto.UUID.generate()
      slug = unique_slug("del-retain-read")

      insert_credential!(slug, value: "v1", scope: {:agent, owner_id})
      assert {:ok, "v1"} = Vault.get(slug, accessor: {:agent, owner_id})
      assert {:ok, _} = Vault.delete(slug, accessor: {:agent, owner_id})

      # Newest first, so the deletion is the head of the trail.
      assert ["revoke", "use"] = Enum.map(Vault.access_log(slug), & &1.action)
    end

    test "a denied deletion leaves the credential, its grants and the trail intact" do
      owner_id = Ecto.UUID.generate()
      stranger_id = Ecto.UUID.generate()
      slug = unique_slug("del-retain-denied")

      cred = insert_credential!(slug, value: "v1", scope: {:agent, owner_id})
      grant!(cred, stranger_id, ["use"])

      assert {:ok, "v1"} = Vault.get(slug, accessor: {:agent, stranger_id})
      assert {:error, :access_denied} = Vault.delete(slug, accessor: {:agent, stranger_id})

      assert Repo.get(Credential, cred.id) != nil
      assert Repo.all(from(g in AccessGrant, where: g.credential_id == ^cred.id)) != []

      # Still attached to the live credential — nothing was nulled or purged.
      assert ["denied", "use"] = Enum.map(Vault.access_log(slug), & &1.action)
      assert Enum.all?(Vault.access_log(slug), &(&1.credential_id == cred.id))
    end

    test "the slug is re-creatable after a delete and the old trail stays distinguishable" do
      owner_id = Ecto.UUID.generate()
      slug = unique_slug("del-retain-reuse")

      first = insert_credential!(slug, value: "v1", scope: {:agent, owner_id})
      assert {:ok, "v1"} = Vault.get(slug, accessor: {:agent, owner_id})
      assert {:ok, _} = Vault.delete(slug, accessor: {:agent, owner_id})

      second = insert_credential!(slug, value: "v2", scope: {:agent, owner_id})
      assert second.id != first.id
      assert {:ok, "v2"} = Vault.get(slug, accessor: {:agent, owner_id})

      entries = Enum.reverse(Vault.access_log(slug))
      assert Enum.map(entries, & &1.action) == ["use", "revoke", "use"]

      {old, new} = Enum.split(entries, 2)
      assert Enum.all?(old, &is_nil(&1.credential_id)), "history of the destroyed credential"
      assert Enum.all?(new, &(&1.credential_id == second.id)), "history of the live one"
    end
  end

  # ── access_log/2 ─────────────────────────────────────────────────────────────

  describe "access_log/2" do
    test "returns entries newest first" do
      owner_id = Ecto.UUID.generate()
      slug = unique_slug("alog-order")

      insert_credential!(slug, value: "v1", scope: {:agent, owner_id})
      assert {:ok, "v1"} = Vault.get(slug, accessor: {:agent, owner_id})
      assert {:ok, _} = Vault.rotate(slug, "v2", accessor: {:agent, owner_id})

      assert ["rotate", "use"] = Enum.map(Vault.access_log(slug), & &1.action)
    end

    test "accepts a %Credential{} as well as a slug" do
      owner_id = Ecto.UUID.generate()
      slug = unique_slug("alog-struct")

      cred = insert_credential!(slug, value: "v1", scope: {:agent, owner_id})
      assert {:ok, "v1"} = Vault.get(slug, accessor: {:agent, owner_id})

      assert Enum.map(Vault.access_log(cred), & &1.id) ==
               Enum.map(Vault.access_log(slug), & &1.id)
    end

    test "honours :limit, keeping the newest entries" do
      owner_id = Ecto.UUID.generate()
      slug = unique_slug("alog-limit")

      insert_credential!(slug, value: "v1", scope: {:agent, owner_id})
      for _ <- 1..3, do: assert({:ok, "v1"} = Vault.get(slug, accessor: {:agent, owner_id}))
      assert {:ok, _} = Vault.rotate(slug, "v2", accessor: {:agent, owner_id})

      assert length(Vault.access_log(slug)) == 4
      assert ["rotate", "use"] = Enum.map(Vault.access_log(slug, limit: 2), & &1.action)
    end

    test "returns [] for a slug that never existed" do
      assert Vault.access_log("no-such-cred-#{System.unique_integer([:positive])}") == []
    end

    test "finds rows written before the denormalised columns existed" do
      owner_id = Ecto.UUID.generate()
      slug = unique_slug("alog-legacy")
      cred = insert_credential!(slug, value: "v1", scope: {:agent, owner_id})

      # A pre-migration-shaped row: credential_id set, slug/scope null. The
      # backfill covered these, but a row can only be found by id while its
      # credential lives, which is why the query unions the two.
      Repo.insert!(%AccessLog{
        credential_id: cred.id,
        accessor_type: "agent",
        accessor_id: owner_id,
        action: "use",
        metadata: %{}
      })

      assert [entry] = Vault.access_log(slug)
      assert entry.credential_id == cred.id
      assert is_nil(entry.credential_slug)
    end
  end

  # ── delete/2 — access control ────────────────────────────────────────────────

  describe "delete/2 access control" do
    test "the owning agent may delete its own credential" do
      owner_id = Ecto.UUID.generate()
      slug = unique_slug("del-owner")
      insert_credential!(slug, value: "v1", scope: {:agent, owner_id})

      assert {:ok, _} = Vault.delete(slug, accessor: {:agent, owner_id})
      assert Repo.get_by(Credential, slug: slug) == nil
    end

    test "a use-only grantee may read but may not delete" do
      owner_id = Ecto.UUID.generate()
      grantee_id = Ecto.UUID.generate()
      slug = unique_slug("del-use-only")

      cred = insert_credential!(slug, value: "v1", scope: {:agent, owner_id})
      grant!(cred, grantee_id, ["use"])

      assert {:error, :access_denied} = Vault.delete(slug, accessor: {:agent, grantee_id})

      assert Repo.get(Credential, cred.id) != nil
      assert {:ok, "v1"} = Vault.get(slug, accessor: {:agent, grantee_id})
    end

    test "rotate authority does not imply revoke authority" do
      owner_id = Ecto.UUID.generate()
      rotator_id = Ecto.UUID.generate()
      slug = unique_slug("del-rot-grant")

      cred = insert_credential!(slug, value: "v1", scope: {:agent, owner_id})
      grant!(cred, rotator_id, ["use", "rotate"])

      assert {:ok, _} = Vault.rotate(slug, "v2", accessor: {:agent, rotator_id})
      assert {:error, :access_denied} = Vault.delete(slug, accessor: {:agent, rotator_id})
      assert Repo.get(Credential, cred.id) != nil
    end

    test "a grantee holding \"revoke\" may delete" do
      owner_id = Ecto.UUID.generate()
      revoker_id = Ecto.UUID.generate()
      slug = unique_slug("del-revoke-grant")

      cred = insert_credential!(slug, value: "v1", scope: {:agent, owner_id})
      grant!(cred, revoker_id, ["use", "revoke"])

      assert {:ok, _} = Vault.delete(slug, accessor: {:agent, revoker_id})
      assert Repo.get(Credential, cred.id) == nil
    end

    test "a nil accessor may not delete an agent-scoped credential" do
      owner_id = Ecto.UUID.generate()
      slug = unique_slug("del-nil")
      cred = insert_credential!(slug, value: "v1", scope: {:agent, owner_id})

      assert {:error, :access_denied} = Vault.delete(slug)
      assert Repo.get(Credential, cred.id) != nil
    end

    test "a non-privileged agent may not delete a platform-scoped credential, but the system accessor may" do
      stranger_id = Ecto.UUID.generate()
      slug = unique_slug("del-plat")
      cred = insert_credential!(slug, value: "v1", scope: {:platform, nil})

      assert {:error, :access_denied} = Vault.delete(slug, accessor: {:agent, stranger_id})
      assert Repo.get(Credential, cred.id) != nil
      assert {:ok, "v1"} = Vault.get(slug, accessor: {:agent, stranger_id})

      assert {:ok, _} = Vault.delete(slug, accessor: {:system, nil})
      assert Repo.get(Credential, cred.id) == nil
    end

    test "a denied deletion destroys nothing and writes a denied log row instead of a revoke row" do
      owner_id = Ecto.UUID.generate()
      stranger_id = Ecto.UUID.generate()
      slug = unique_slug("del-deny-log")

      cred = insert_credential!(slug, value: "v1", scope: {:agent, owner_id})
      grant!(cred, stranger_id, ["use"])

      assert {:error, :access_denied} = Vault.delete(slug, accessor: {:agent, stranger_id})

      assert [log] = logs_for(cred)
      assert log.action == "denied"
      assert log.accessor_type == "agent"
      assert log.accessor_id == stranger_id

      refute "revoke" in actions_for(cred)
      assert Repo.get(Credential, cred.id) != nil

      grants = from(g in AccessGrant, where: g.credential_id == ^cred.id) |> Repo.all()
      assert length(grants) == 1, "a refused deletion must not cascade to grants"
    end

    test "a denied deletion emits access_denied telemetry carrying the accessor" do
      owner_id = Ecto.UUID.generate()
      stranger_id = Ecto.UUID.generate()
      slug = unique_slug("del-deny-tel")

      insert_credential!(slug, value: "v1", scope: {:agent, owner_id})

      ref = :telemetry_test.attach_event_handlers(self(), [[:platform, :vault, :access_denied]])

      assert {:error, :access_denied} = Vault.delete(slug, accessor: {:agent, stranger_id})

      assert_receive {[:platform, :vault, :access_denied], ^ref, _measurements, meta}
      assert meta.slug == slug
      assert meta.accessor == {:agent, stranger_id}

      :telemetry.detach(ref)
    end
  end

  # ── workspace scope ──────────────────────────────────────────────────────────

  describe "workspace-scoped credentials" do
    test "get/2 is denied for agent, system and nil accessors, and logs every refusal" do
      slug = unique_slug("ws-get")

      cred =
        insert_credential!(slug, value: "ws-secret", scope: {:workspace, Ecto.UUID.generate()})

      assert {:error, :access_denied} = Vault.get(slug, accessor: {:agent, Ecto.UUID.generate()})
      assert {:error, :access_denied} = Vault.get(slug, accessor: {:system, nil})
      assert {:error, :access_denied} = Vault.get(slug)

      assert actions_for(cred) == ["denied", "denied", "denied"],
             "every refused read must leave a trace"
    end

    test "get/2 denial emits access_denied telemetry" do
      slug = unique_slug("ws-get-tel")
      agent_id = Ecto.UUID.generate()
      insert_credential!(slug, value: "ws-secret", scope: {:workspace, Ecto.UUID.generate()})

      ref = :telemetry_test.attach_event_handlers(self(), [[:platform, :vault, :access_denied]])

      assert {:error, :access_denied} = Vault.get(slug, accessor: {:agent, agent_id})

      assert_receive {[:platform, :vault, :access_denied], ^ref, _measurements, meta}
      assert meta.slug == slug
      assert meta.accessor == {:agent, agent_id}

      :telemetry.detach(ref)
    end

    test "rotate/3 is denied for agent, system and nil accessors and mutates nothing" do
      slug = unique_slug("ws-rotate")

      cred =
        insert_credential!(slug, value: "ws-secret", scope: {:workspace, Ecto.UUID.generate()})

      assert {:error, :access_denied} =
               Vault.rotate(slug, "pwned", accessor: {:agent, Ecto.UUID.generate()})

      assert {:error, :access_denied} = Vault.rotate(slug, "pwned", accessor: {:system, nil})
      assert {:error, :access_denied} = Vault.rotate(slug, "pwned")

      assert Repo.get(Credential, cred.id).encrypted_data == "ws-secret"
      assert is_nil(Repo.get(Credential, cred.id).rotated_at)
      assert actions_for(cred) == ["denied", "denied", "denied"]
      refute "rotate" in actions_for(cred)
    end

    test "delete/2 is denied for agent, system and nil accessors and destroys nothing" do
      slug = unique_slug("ws-delete")

      cred =
        insert_credential!(slug, value: "ws-secret", scope: {:workspace, Ecto.UUID.generate()})

      grant!(cred, Ecto.UUID.generate(), ["use"])

      assert {:error, :access_denied} =
               Vault.delete(slug, accessor: {:agent, Ecto.UUID.generate()})

      assert {:error, :access_denied} = Vault.delete(slug, accessor: {:system, nil})
      assert {:error, :access_denied} = Vault.delete(slug)

      assert Repo.get(Credential, cred.id) != nil
      assert actions_for(cred) == ["denied", "denied", "denied"]
      refute "revoke" in actions_for(cred)

      grants = from(g in AccessGrant, where: g.credential_id == ^cred.id) |> Repo.all()
      assert length(grants) == 1, "a refused deletion must not cascade to grants"
    end

    test "an explicit grant is an open path, so the escape hatch is not the only one" do
      slug = unique_slug("ws-grant")
      reader_id = Ecto.UUID.generate()
      rotator_id = Ecto.UUID.generate()

      cred =
        insert_credential!(slug, value: "ws-secret", scope: {:workspace, Ecto.UUID.generate()})

      grant!(cred, reader_id, ["use"])
      grant!(cred, rotator_id, ["use", "rotate"])

      assert {:ok, "ws-secret"} = Vault.get(slug, accessor: {:agent, reader_id})
      assert {:error, :access_denied} = Vault.rotate(slug, "v2", accessor: {:agent, reader_id})

      assert {:ok, _} = Vault.rotate(slug, "v2", accessor: {:agent, rotator_id})
      assert {:ok, "v2"} = Vault.get(slug, accessor: {:agent, rotator_id})
      assert {:error, :access_denied} = Vault.delete(slug, accessor: {:agent, rotator_id})
    end

    test "the escape hatch restores access for every accessor and logs a warning" do
      slug = unique_slug("ws-hatch")
      agent_id = Ecto.UUID.generate()
      insert_credential!(slug, value: "ws-secret", scope: {:workspace, Ecto.UUID.generate()})

      # Application config is global; only workspace-scoped credentials read this
      # key and this module is the only place that creates one, so flipping it
      # here cannot leak into a concurrently running test module.
      original = Application.get_env(:platform, Vault, [])
      on_exit(fn -> Application.put_env(:platform, Vault, original) end)

      Application.put_env(
        :platform,
        Vault,
        Keyword.put(original, :allow_unscoped_workspace_access, true)
      )

      log =
        capture_log(fn ->
          assert {:ok, "ws-secret"} = Vault.get(slug, accessor: {:agent, agent_id})
          # The hatch restores the old behaviour verbatim, nil accessor included.
          assert {:ok, "ws-secret"} = Vault.get(slug)
        end)

      assert log =~ slug
      assert log =~ "allow_unscoped_workspace_access"
      assert log =~ agent_id
      assert log =~ "temporary"
    end

    test "the escape hatch ships off" do
      refute Application.get_env(:platform, Vault, [])[:allow_unscoped_workspace_access],
             "allow_unscoped_workspace_access must default to false"
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

  # ── UUID boundary (task 019fa129 stage 4) ────────────────────────────────
  describe "UUID boundary: normalize_uuid does not FABRICATE an accessor id" do
    # Fabricated-value site, not a raise site. `parse_accessor/1` feeds the
    # AccessLog's NOT NULL `accessor_id` column. A bare `Ecto.UUID.cast/1`
    # hex-encodes any 16-byte accessor id into a well-formed but INVENTED
    # uuid, which is then WRITTEN to the audit row — a real-looking actor
    # belonging to nobody, and an audit trail that silently lies.
    #
    # Nothing raises, so assert on the PERSISTED VALUE, not on an exception.
    @slug_16 "higginshigginsxx"
    @system_accessor_id "00000000-0000-0000-0000-000000000000"

    test "a 16-character accessor id is logged as the system sentinel" do
      slug = unique_slug("vault-boundary")
      insert_credential!(slug, value: "s3cret", scope: {:platform, nil})
      cred = Repo.get_by!(Credential, slug: slug)

      {:ok, _} = Vault.get(slug, accessor: {:agent, @slug_16})

      log =
        from(l in AccessLog, where: l.credential_id == ^cred.id and l.action == "use", limit: 1)
        |> Repo.one()

      assert log.accessor_id == @system_accessor_id

      # The negative form is the point: NOT the hex-encoding of the slug.
      {:ok, fabricated} = Ecto.UUID.cast(@slug_16)
      refute log.accessor_id == fabricated
    end

    test "a canonical accessor uuid is still logged verbatim" do
      slug = unique_slug("vault-boundary-ok")
      insert_credential!(slug, value: "s3cret", scope: {:platform, nil})
      cred = Repo.get_by!(Credential, slug: slug)
      accessor_id = Ecto.UUID.generate()

      {:ok, _} = Vault.get(slug, accessor: {:agent, accessor_id})

      log =
        from(l in AccessLog, where: l.credential_id == ^cred.id and l.action == "use", limit: 1)
        |> Repo.one()

      assert log.accessor_id == accessor_id
    end
  end
end
