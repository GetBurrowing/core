defmodule Platform.Tenancy.TenantPriorityTest do
  @moduledoc """
  `Platform.Tenancy.tenant_priority/0` is install config, read at runtime,
  with no default (task 01a14dd9 stage 1). An install sets it through the
  `TENANT_ORG_PRIORITY` env var, which `config/runtime.exs` parses with
  `Platform.Tenancy.parse_tenant_priority/1`.

  `async: false`: every test here rewrites the global `:tenant_priority`
  key, and restores whatever the suite pinned (test_helper.exs) afterwards.
  """

  use Platform.DataCase, async: false

  import Platform.TenancyFixtures, only: [tenant_org_id: 1]

  alias Platform.Projects
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.Org

  setup do
    original = Application.fetch_env(:platform, :tenant_priority)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:platform, :tenant_priority, value)
        :error -> Application.delete_env(:platform, :tenant_priority)
      end
    end)

    # Placeholder tenants, created out of alphabetical order so neither
    # insertion order nor id order can pass for the expected sequence.
    for slug <- ~w(wonka hooli initech globex), do: tenant_org_id(slug)

    :ok
  end

  defp slugs(orgs), do: Enum.map(orgs, & &1.slug)

  defp root_slug, do: Tenancy.get_root_org().slug

  defp project_for(%Org{} = org), do: %{org: org, archived_at: nil, name: "p-#{org.slug}"}

  describe "(a) with the key unset" do
    test "tenant_priority/0 is [] and every tenant sorts slug-alphabetically after the root" do
      Application.delete_env(:platform, :tenant_priority)

      assert Tenancy.tenant_priority() == []
      assert Tenancy.tenant_priority_index("hooli") == 9_999

      ordered = slugs(Tenancy.list_orgs_in_priority_order())
      [first | rest] = ordered

      assert first == root_slug()
      assert rest == Enum.sort_by(rest, &String.downcase/1)
      assert Enum.sort(ordered) == Enum.sort(slugs(Repo.all(Org)))

      assert Enum.filter(rest, &(&1 in ~w(globex hooli initech wonka))) ==
               ~w(globex hooli initech wonka)
    end

    test "Projects.group_by_org/1 agrees: root, then tenants alphabetically" do
      Application.delete_env(:platform, :tenant_priority)

      orgs = Repo.all(Org)
      groups = orgs |> Enum.map(&project_for/1) |> Projects.group_by_org()
      [{first, _, _} | rest] = groups
      rest_slugs = Enum.map(rest, &elem(&1, 0))

      assert first == root_slug()
      assert rest_slugs == Enum.sort(rest_slugs)
    end
  end

  describe "(b) with a configured list" do
    test "listed tenants come first in list order, then the unknown ones alphabetically" do
      Application.put_env(:platform, :tenant_priority, ["wonka", "hooli"])

      assert Tenancy.tenant_priority() == ["wonka", "hooli"]
      assert Tenancy.tenant_priority_index("wonka") == 0
      assert Tenancy.tenant_priority_index("hooli") == 1
      assert Tenancy.tenant_priority_index("initech") == 9_999

      [first, second, third | rest] = slugs(Tenancy.list_orgs_in_priority_order())

      assert first == root_slug()
      assert [second, third] == ["wonka", "hooli"]
      assert rest == Enum.sort_by(rest, &String.downcase/1)
      assert Enum.filter(rest, &(&1 in ~w(globex initech))) == ~w(globex initech)
    end

    test "Projects.group_by_org/1 orders buckets the same way" do
      Application.put_env(:platform, :tenant_priority, ["wonka", "hooli"])

      expected = slugs(Tenancy.list_orgs_in_priority_order())

      groups =
        Repo.all(Org)
        |> Enum.shuffle()
        |> Enum.map(&project_for/1)
        |> Projects.group_by_org()

      assert Enum.map(groups, &elem(&1, 0)) == expected
    end
  end

  describe "(c) parse_tenant_priority/1" do
    test "trims entries, drops blanks and keeps the order" do
      assert Tenancy.parse_tenant_priority(" a , ,b ") == ["a", "b"]
      assert Tenancy.parse_tenant_priority("hooli,wonka") == ["hooli", "wonka"]
      assert Tenancy.parse_tenant_priority("wonka , hooli,") == ["wonka", "hooli"]
    end

    test "an empty, blank or absent value gives no list, so runtime.exs writes no key" do
      assert Tenancy.parse_tenant_priority("") == []
      assert Tenancy.parse_tenant_priority(" , ,") == []
      assert Tenancy.parse_tenant_priority(nil) == []
    end
  end
end
