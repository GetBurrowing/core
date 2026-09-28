defmodule Platform.VaultGetUniqueTest do
  @moduledoc """
  `Platform.Vault.get_unique/2` — the refusing read (task 01a0cf21 stage 1).

  `get_unique/2` resolves a slug the way `rotate/3` does and refuses instead
  of guessing when the slug matches more than one credential. `get/2` now
  refuses the same way (task 019f9cb8 stage 1) — the two are behaviourally
  equivalent for target selection. Every mail secret read goes through
  `get_unique/2`.
  """
  use Platform.DataCase, async: true

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Platform.Vault
  alias Platform.Vault.AccessLog
  alias Platform.Vault.Credential

  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"

  defp put!(slug, value, scope) do
    {:ok, cred} = Vault.put(slug, :custom, value, scope: scope)
    cred
  end

  defp reload(%Credential{id: id}), do: Repo.get!(Credential, id)

  defp use_logs(%Credential{id: id}) do
    from(l in AccessLog, where: l.credential_id == ^id and l.action == "use") |> Repo.all()
  end

  # The same slug at an integration scope AND at platform scope. Both are
  # readable by the integration owner (platform :use is open to anyone), so
  # a guessing lookup WOULD return a decrypted value here — which is what
  # makes the refusal assertion below non-vacuous.
  defp ambiguous_pair! do
    integration_id = Ecto.UUID.generate()
    slug = unique_slug("mail-ambiguous")
    integration = put!(slug, "INTEGRATION-SECRET", {:integration, integration_id})
    platform = put!(slug, "PLATFORM-SECRET", {:platform, nil})
    %{slug: slug, integration_id: integration_id, integration: integration, platform: platform}
  end

  describe "get_unique/2 with an ambiguous slug" do
    test "refuses without :scope, decrypting nothing and bumping nothing" do
      %{slug: slug, integration_id: iid, integration: i, platform: p} = ambiguous_pair!()

      log =
        capture_log(fn ->
          assert {:error, :ambiguous_slug} =
                   Vault.get_unique(slug, accessor: {:integration, iid})
        end)

      assert is_nil(reload(i).last_used_at)
      assert is_nil(reload(p).last_used_at)
      assert use_logs(i) == []
      assert use_logs(p) == []

      # Positive control on the capture, then the scopes it names, then no value.
      assert log =~ "refusing to read #{slug}"
      assert log =~ "integration:#{inspect(iid)}"
      assert log =~ "platform:nil"
      refute log =~ "INTEGRATION-SECRET"
      refute log =~ "PLATFORM-SECRET"
    end

    test "with :scope reads exactly the named row" do
      %{slug: slug, integration_id: iid, integration: i, platform: p} = ambiguous_pair!()

      assert {:ok, "INTEGRATION-SECRET"} =
               Vault.get_unique(slug,
                 scope: {:integration, iid},
                 accessor: {:integration, iid}
               )

      refute is_nil(reload(i).last_used_at)
      assert is_nil(reload(p).last_used_at)
      assert length(use_logs(i)) == 1

      assert {:ok, "PLATFORM-SECRET"} =
               Vault.get_unique(slug, scope: {:platform, nil}, accessor: {:integration, iid})
    end

    test "get/2 now refuses the same ambiguous slug (task 019f9cb8 stage 1)" do
      %{slug: slug, integration_id: iid} = ambiguous_pair!()

      assert {:error, :ambiguous_slug} = Vault.get(slug, accessor: {:integration, iid})
    end
  end

  describe "get_unique/2 with a single row" do
    test "returns the value with the same bookkeeping as get/2" do
      iid = Ecto.UUID.generate()
      slug = unique_slug("mail-single")
      cred = put!(slug, "ONLY", {:integration, iid})

      assert {:ok, "ONLY"} = Vault.get_unique(slug, accessor: {:integration, iid})
      refute is_nil(reload(cred).last_used_at)
      assert length(use_logs(cred)) == 1
    end

    test "still enforces :use — a foreign integration is denied" do
      iid = Ecto.UUID.generate()
      slug = unique_slug("mail-denied")
      cred = put!(slug, "ONLY", {:integration, iid})

      assert {:error, :access_denied} =
               Vault.get_unique(slug,
                 scope: {:integration, iid},
                 accessor: {:integration, Ecto.UUID.generate()}
               )

      assert is_nil(reload(cred).last_used_at)
    end

    test "an unknown slug is :not_found" do
      assert {:error, :not_found} = Vault.get_unique(unique_slug("mail-missing"))
    end
  end
end
