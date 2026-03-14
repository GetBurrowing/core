defmodule Platform.Vault.CredentialTest do
  use ExUnit.Case, async: true

  alias Platform.Vault.Credential
  alias Platform.Vault.EncryptedBinary

  describe "changeset/2" do
    test "valid changeset with all required fields" do
      changeset = Credential.changeset(%Credential{}, valid_attrs())

      assert changeset.valid?
    end

    test "missing slug fails validation" do
      changeset = Credential.changeset(%Credential{}, Map.delete(valid_attrs(), :slug))

      refute changeset.valid?
      assert %{slug: ["can't be blank"]} = errors_on(changeset)
    end

    test "missing credential_type fails validation" do
      changeset = Credential.changeset(%Credential{}, Map.delete(valid_attrs(), :credential_type))

      refute changeset.valid?
      assert %{credential_type: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid credential_type value rejected" do
      changeset =
        Credential.changeset(%Credential{}, Map.put(valid_attrs(), :credential_type, "bad"))

      refute changeset.valid?
      assert %{credential_type: [_]} = errors_on(changeset)
    end

    test "invalid scope_type value rejected" do
      changeset = Credential.changeset(%Credential{}, Map.put(valid_attrs(), :scope_type, "bad"))

      refute changeset.valid?
      assert %{scope_type: [_]} = errors_on(changeset)
    end

    test "all credential types are accepted" do
      for credential_type <- ~w(api_key oauth2 token keypair custom) do
        changeset =
          Credential.changeset(
            %Credential{},
            Map.put(valid_attrs(), :credential_type, credential_type)
          )

        assert changeset.valid?, "expected #{credential_type} to be valid"
      end
    end

    test "all scope types are accepted" do
      for scope_type <- ~w(platform workspace agent integration) do
        changeset =
          Credential.changeset(%Credential{}, Map.put(valid_attrs(), :scope_type, scope_type))

        assert changeset.valid?, "expected #{scope_type} to be valid"
      end
    end

    test "encrypted_data field is present in schema" do
      fields = Credential.__schema__(:fields)
      assert :encrypted_data in fields
    end

    test "encrypted_data field uses EncryptedBinary type" do
      assert Credential.__schema__(:type, :encrypted_data) == EncryptedBinary
    end
  end

  defp valid_attrs do
    %{
      workspace_id: Ecto.UUID.generate(),
      slug: "stripe-primary",
      name: "Stripe Primary",
      credential_type: "api_key",
      provider: "stripe",
      encrypted_data: "super-secret-token",
      metadata: %{"env" => "test"},
      scope_type: "workspace",
      scope_id: Ecto.UUID.generate()
    }
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
  end
end
