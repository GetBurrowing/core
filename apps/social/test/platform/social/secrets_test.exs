defmodule Platform.Social.SecretsTest do
  @moduledoc """
  The install-level Zernio key (task 01a14722): one Vault row at
  `"social:zernio:api_key"`, scope `{:integration, nil}`, written only for a
  non-archived human, readable only by its integration owner.
  """
  use Platform.DataCase, async: false

  import Platform.SocialFixtures

  alias Platform.Social.Secrets
  alias Platform.Vault

  @slug "social:zernio:api_key"
  @scope {:integration, nil}

  defp rows, do: [scope: @scope] |> Vault.list() |> Enum.filter(&(&1.slug == @slug))

  test "slug and scope are the install-level constants" do
    assert Secrets.zernio_slug() == @slug
    assert Secrets.zernio_scope() == @scope
  end

  describe "put_zernio_api_key/2" do
    test "first save puts, second save rotates: exactly one row, new value read back" do
      user = user!()
      other = user!()

      assert {:ok, _} = Secrets.put_zernio_api_key("  first-key-not-real \n", user)
      assert [%{scope_type: "integration", scope_id: nil}] = rows()
      assert {:ok, "first-key-not-real"} = Secrets.zernio_api_key()

      assert {:ok, _} = Secrets.put_zernio_api_key("second-key-not-real", other)
      assert [%{rotated_at: %DateTime{}}] = rows()
      assert {:ok, "second-key-not-real"} = Secrets.zernio_api_key()

      assert {:set, %{changed_by_user_id: changed_by}} = Secrets.zernio_key_status()
      assert changed_by == other.id
    end

    test "a blank or whitespace value is refused and writes nothing" do
      user = user!()

      for value <- ["", "   ", "\n\t ", nil] do
        assert {:error, :blank} = Secrets.put_zernio_api_key(value, user)
      end

      assert rows() == []
      assert Secrets.zernio_key_status() == :not_set
    end

    test "a blank value does not overwrite an existing key" do
      user = user!()
      {:ok, _} = Secrets.put_zernio_api_key("kept-key-not-real", user)

      assert {:error, :blank} = Secrets.put_zernio_api_key("   ", user)
      assert {:ok, "kept-key-not-real"} = Secrets.zernio_api_key()
    end

    test "an agent, an archived user, an id or nil is not a human and writes nothing" do
      archived = %{user!() | archived_at: DateTime.utc_now()}
      agent = agent!()

      for who <- [agent, archived, archived.id, nil, %{id: archived.id, archived_at: nil}] do
        assert {:error, :not_a_human} = Secrets.put_zernio_api_key("k-not-real", who)
      end

      assert rows() == []
    end

    test "the access log names the user and never carries the value or its fingerprint" do
      user = user!()
      {:ok, cred} = Secrets.put_zernio_api_key("logged-key-not-real", user)

      log = Vault.access_log(cred)
      assert [%{metadata: metadata}] = Enum.filter(log, &(&1.action == "update"))
      assert metadata == %{"set_by_user_id" => user.id}

      for entry <- log, value <- Map.values(entry.metadata || %{}) do
        refute is_binary(value) and String.contains?(value, "logged-key-not-real")
        refute value == Vault.fingerprint("logged-key-not-real")
      end
    end
  end

  describe "zernio_api_key/0" do
    test "with no row it is unavailable" do
      assert {:error, _} = Secrets.zernio_api_key()
    end

    test "the Vault itself refuses to store a blank value at the install slug" do
      for value <- ["", "   "] do
        assert {:error, %Ecto.Changeset{}} =
                 Vault.put(@slug, :api_key, value, scope: @scope, provider: "social")
      end

      assert rows() == []
      assert {:error, :not_found} = Secrets.zernio_api_key()
    end

    test "an {:agent, id} accessor is denied the install key" do
      {:ok, _} = Secrets.put_zernio_api_key("agent-proof-key-not-real", user!())
      agent = agent!()

      assert {:error, :access_denied} =
               Vault.get_unique(@slug, scope: @scope, accessor: {:agent, agent.id})
    end

    test "a different integration owner is denied the install key" do
      {:ok, _} = Secrets.put_zernio_api_key("owner-proof-key-not-real", user!())

      assert {:error, :access_denied} =
               Vault.get_unique(@slug,
                 scope: @scope,
                 accessor: {:integration, Ecto.UUID.generate()}
               )
    end
  end

  describe "zernio_key_status/0" do
    test ":not_set with no row" do
      assert Secrets.zernio_key_status() == :not_set
    end

    test "is metadata only: it decrypts nothing and bumps no last_used_at" do
      user = user!()
      {:ok, _} = Secrets.put_zernio_api_key("status-key-not-real", user)

      handler = "social-secrets-test-#{System.unique_integer([:positive])}"
      test = self()

      :telemetry.attach(
        handler,
        [:platform, :vault, :credential_used],
        fn _, _, meta, _ -> send(test, {:used, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:set, %{changed_at: %DateTime{}, changed_by_user_id: user_id} = status} =
               Secrets.zernio_key_status()

      assert user_id == user.id
      refute inspect(status) =~ "status-key-not-real"
      refute_received {:used, _}
      assert [%{last_used_at: nil}] = rows()
    end

    test "a key at another scope under the same slug does not count as set" do
      {_profile, account} = social_account!(org_id!(), "linkedin")
      {:ok, _} = Vault.put(@slug, :api_key, "k-not-real", scope: {:integration, account.id})

      assert Secrets.zernio_key_status() == :not_set
    end
  end
end
