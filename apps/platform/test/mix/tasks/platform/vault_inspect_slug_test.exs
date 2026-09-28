defmodule Mix.Tasks.Platform.Vault.InspectSlugTest do
  @moduledoc """
  Tests for the read-only `mix platform.vault.inspect_slug` diagnostic
  (task 019f9cb8 stage 3, Part B).

  Covers: it finds every row for a slug across scopes, it never prints
  `encrypted_data` (plaintext or ciphertext), and it prints nothing —
  `Repo.all/1` only — when the slug has no rows.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Platform.Vault.InspectSlug
  alias Platform.Vault

  test "fetch_all/1 returns every row for the slug, across scopes, with encrypted_data stripped" do
    slug = "inspect-slug-multi-#{System.unique_integer([:positive])}"
    agent_id = Ecto.UUID.generate()

    {:ok, _} =
      Vault.put(slug, :api_key, "plaintext-a", scope: {:platform, nil})

    {:ok, _} =
      Vault.put(slug, :api_key, "plaintext-b", scope: {:agent, agent_id})

    rows = InspectSlug.fetch_all(slug)

    assert length(rows) == 2
    assert Enum.all?(rows, &(&1.slug == slug))
    assert Enum.all?(rows, &is_nil(&1.encrypted_data))

    scope_types = Enum.map(rows, & &1.scope_type) |> Enum.sort()
    assert scope_types == ["agent", "platform"]
  end

  test "fetch_all/1 returns an empty list for a slug with no rows" do
    assert [] == InspectSlug.fetch_all("no-such-slug-#{System.unique_integer([:positive])}")
  end

  test "report/1 never prints the plaintext or a ciphertext blob, only metadata" do
    slug = "inspect-slug-secret-#{System.unique_integer([:positive])}"
    secret_value = "super-secret-value-#{System.unique_integer([:positive])}"

    {:ok, _} = Vault.put(slug, :api_key, secret_value, scope: {:platform, nil})

    output =
      slug
      |> InspectSlug.fetch_all()
      |> InspectSlug.report()
      |> Enum.join("\n")

    refute output =~ secret_value
    refute output =~ "encrypted_data"
    assert output =~ slug
    assert output =~ "scope_type"
  end

  test "report/1 on an empty list says so without claiming a row exists" do
    output = InspectSlug.report([]) |> Enum.join("\n")

    assert output =~ "no vault_credentials row"
  end

  test "report/1 does not rank or recommend a row as authoritative when ambiguous" do
    slug = "inspect-slug-ambiguous-#{System.unique_integer([:positive])}"
    agent_id = Ecto.UUID.generate()

    {:ok, _} = Vault.put(slug, :api_key, "value-a", scope: {:platform, nil})
    {:ok, _} = Vault.put(slug, :api_key, "value-b", scope: {:agent, agent_id})

    output =
      slug
      |> InspectSlug.fetch_all()
      |> InspectSlug.report()
      |> Enum.join("\n")

    assert output =~ "2 row(s) matched"
    refute output =~ "authoritative row"
    refute output =~ "keep this one"
    refute output =~ "winner"
  end

  test "run/1 with a matching slug prints the rows via Mix.shell()" do
    slug = "inspect-slug-run-#{System.unique_integer([:positive])}"
    {:ok, _} = Vault.put(slug, :api_key, "plaintext-run", scope: {:platform, nil})

    output = capture_io(fn -> InspectSlug.run([slug]) end)

    assert output =~ slug
    assert output =~ "1 row(s) matched"
    refute output =~ "plaintext-run"
  end

  test "run/1 with no args raises rather than silently doing nothing" do
    assert_raise Mix.Error, ~r/usage: mix platform.vault.inspect_slug/, fn ->
      InspectSlug.run([])
    end
  end
end
