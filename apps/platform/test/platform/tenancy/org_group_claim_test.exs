defmodule Platform.Tenancy.OrgGroupClaimTest do
  @moduledoc """
  Coverage for the org group-claim mapping table, its schema, and
  `Platform.Tenancy.resolve_org_from_groups/1`.

  All org names and group values here are INVENTED — `core` is a public
  repo and no real client, hostname, or address belongs in it.

  The resolver's pre-selection trio (one match / zero / two) is asserted
  at this layer because this is the layer that decides. A single
  happy-path test would pass for an implementation that always returns
  the first org; the trio is what makes the coverage non-vacuous.
  """

  use Platform.DataCase, async: true

  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.Org
  alias Platform.Tenancy.OrgGroupClaim

  # `Platform.DataCase` does not export an `errors_on/1`, so this test
  # carries its own.
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), "") |> to_string()
      end)
    end)
  end

  defp create_org!(name) do
    n = System.unique_integer([:positive])

    %Org{}
    |> Org.changeset(%{
      name: "#{name} #{n}",
      slug: "#{name |> String.downcase() |> String.replace(~r/[^a-z]/, "-")}-#{n}",
      parent_org_id: Tenancy.get_org_by_slug!("fabrikam").id
    })
    |> Repo.insert!()
  end

  defp claim!(org, value) do
    {:ok, claim} = Tenancy.create_group_claim(%{org_id: org.id, claim_value: value})
    claim
  end

  describe "changeset normalization" do
    test "claim_value is trimmed and downcased on cast" do
      org = create_org!("example-client")
      claim = claim!(org, "  Example-Client-Group  ")

      assert claim.claim_value == "example-client-group"
    end

    test "a case/whitespace variant of a stored value is rejected by the unique index" do
      org = create_org!("example-client")
      claim!(org, "example-client-group")

      assert {:error, changeset} =
               Tenancy.create_group_claim(%{org_id: org.id, claim_value: "Example-Client-Group "})

      assert %{claim_value: ["has already been taken"]} = errors_on(changeset)
    end

    test "a duplicate claim_value for a DIFFERENT org is rejected too" do
      org_a = create_org!("example-client")
      org_b = create_org!("second-client")
      claim!(org_a, "shared-group")

      assert {:error, changeset} =
               Tenancy.create_group_claim(%{org_id: org_b.id, claim_value: "shared-group"})

      assert %{claim_value: ["has already been taken"]} = errors_on(changeset)
    end

    test "both fields are required" do
      changeset = OrgGroupClaim.changeset(%OrgGroupClaim{}, %{})
      errors = errors_on(changeset)

      assert errors[:org_id]
      assert errors[:claim_value]
    end

    test "an unknown org_id is rejected by the foreign key" do
      assert {:error, changeset} =
               Tenancy.create_group_claim(%{
                 org_id: Platform.Types.UUIDv7.generate(),
                 claim_value: "orphan-group"
               })

      assert errors_on(changeset)[:org_id]
    end
  end

  describe "resolve_org_from_groups/1 — the pre-selection trio" do
    test "exactly one matching org returns {:ok, org}" do
      org = create_org!("example-client")
      other = create_org!("second-client")
      claim!(org, "example-client-group")
      claim!(other, "second-client-group")

      assert {:ok, resolved} =
               Tenancy.resolve_org_from_groups(["example-client-group", "unmapped-group"])

      assert resolved.id == org.id
    end

    test "zero matching orgs returns :none — never a default, first, or root org" do
      # A mapped org EXISTS, so an implementation that falls back to "the
      # first org" or the root org would return {:ok, _} here.
      claim!(create_org!("example-client"), "example-client-group")

      assert Tenancy.resolve_org_from_groups(["totally-unmapped-group"]) == :none
    end

    test "two distinct matching orgs returns {:ambiguous, orgs} and does NOT pick one" do
      org_a = create_org!("example-client")
      org_b = create_org!("second-client")
      claim!(org_a, "example-client-group")
      claim!(org_b, "second-client-group")

      assert {:ambiguous, orgs} =
               Tenancy.resolve_org_from_groups(["example-client-group", "second-client-group"])

      assert Enum.sort(Enum.map(orgs, & &1.id)) == Enum.sort([org_a.id, org_b.id])
    end
  end

  describe "resolve_org_from_groups/1 — dedupe by org id" do
    test "two claim values for the SAME org resolve to {:ok, org}, not ambiguous" do
      org = create_org!("example-client")
      claim!(org, "example-client-group")
      claim!(org, "example-client-admins")

      assert {:ok, resolved} =
               Tenancy.resolve_org_from_groups(["example-client-group", "example-client-admins"])

      assert resolved.id == org.id
    end

    test "three values across two orgs is still ambiguous" do
      org_a = create_org!("example-client")
      org_b = create_org!("second-client")
      claim!(org_a, "example-client-group")
      claim!(org_a, "example-client-admins")
      claim!(org_b, "second-client-group")

      assert {:ambiguous, orgs} =
               Tenancy.resolve_org_from_groups([
                 "example-client-group",
                 "example-client-admins",
                 "second-client-group"
               ])

      assert length(orgs) == 2
    end
  end

  describe "resolve_org_from_groups/1 — input tolerance" do
    test "a bare string resolves like a single-element list" do
      org = create_org!("example-client")
      claim!(org, "example-client-group")

      assert {:ok, resolved} = Tenancy.resolve_org_from_groups("example-client-group")
      assert resolved.id == org.id
    end

    test "a bare string is normalized before lookup" do
      org = create_org!("example-client")
      claim!(org, "example-client-group")

      assert {:ok, resolved} = Tenancy.resolve_org_from_groups(" Example-Client-Group ")
      assert resolved.id == org.id
    end

    test "nil, empty list, empty string and non-string input return :none without raising" do
      claim!(create_org!("example-client"), "example-client-group")

      assert Tenancy.resolve_org_from_groups(nil) == :none
      assert Tenancy.resolve_org_from_groups([]) == :none
      assert Tenancy.resolve_org_from_groups("") == :none
      assert Tenancy.resolve_org_from_groups(["  "]) == :none
      assert Tenancy.resolve_org_from_groups(%{"groups" => "x"}) == :none
      assert Tenancy.resolve_org_from_groups(123) == :none
    end

    test "non-binary members of a list are dropped, not raised on" do
      org = create_org!("example-client")
      claim!(org, "example-client-group")

      assert {:ok, resolved} =
               Tenancy.resolve_org_from_groups([nil, 42, "example-client-group"])

      assert resolved.id == org.id
    end
  end

  describe "listing" do
    test "list_group_claims/0 preloads :org" do
      org = create_org!("example-client")
      claim!(org, "example-client-group")

      found = Enum.find(Tenancy.list_group_claims(), &(&1.claim_value == "example-client-group"))

      assert %Org{} = found.org
      assert found.org.id == org.id
    end

    test "list_group_claims_for_org/1 scopes to one org and accepts a struct or id" do
      org = create_org!("example-client")
      other = create_org!("second-client")
      claim!(org, "example-client-group")
      claim!(org, "example-client-admins")
      claim!(other, "second-client-group")

      assert Enum.map(Tenancy.list_group_claims_for_org(org), & &1.claim_value) ==
               ["example-client-admins", "example-client-group"]

      assert Enum.map(Tenancy.list_group_claims_for_org(other.id), & &1.claim_value) ==
               ["second-client-group"]
    end

    test "delete_group_claim/1 removes the mapping and the resolver stops matching" do
      org = create_org!("example-client")
      claim = claim!(org, "example-client-group")

      assert {:ok, resolved} = Tenancy.resolve_org_from_groups(["example-client-group"])
      assert resolved.id == org.id

      assert {:ok, _} = Tenancy.delete_group_claim(claim)
      assert Tenancy.resolve_org_from_groups(["example-client-group"]) == :none
    end
  end
end
