defmodule Platform.Access.ToolListEquivalenceTest do
  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Access.{RuntimeProfiles, Tools}
  alias Platform.Accounts.User
  alias Platform.Agents.AgentRuntime
  alias Platform.Repo
  alias Platform.RuntimeBundleSnapshot
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  setup do
    root = acme_org_id()
    admin = owner!(root, "admin")
    guest = owner!(root, "member", true)
    %{admin: admin, guest: guest}
  end

  test "ordered tool names are unchanged for each production bundle array except approved Play loss",
       %{admin: admin} do
    for %{key: key, bundles: bundles} <- RuntimeBundleSnapshot.snapshots() do
      runtime = runtime!(admin.id, bundles)
      before = RuntimeBundleSnapshot.legacy_tool_names(bundles)
      after_names = Tools.tool_names(runtime)

      expected =
        if key in [:c, :k, :n],
          do: Enum.reject(before, &String.starts_with?(&1, "play_session_")),
          else: before

      assert after_names == expected, "ordered tool list changed for snapshot #{key}"
    end
  end

  test "guest owner gets exactly the six legacy chat tools with every bundle", %{guest: guest} do
    bundles = Platform.Federation.ToolSurface.all_bundles()
    runtime = runtime!(guest.id, bundles)

    assert Tools.tool_names(runtime) ==
             RuntimeBundleSnapshot.legacy_tool_names(bundles, true)
  end

  test "one tool-list decision stays within four database queries", %{admin: admin, guest: guest} do
    Platform.Access.builtin_role_rules()

    for owner <- [admin, guest] do
      runtime = runtime!(owner.id, ["messaging", "space"])
      {names, query_count} = count_queries(fn -> Tools.tool_names(runtime) end)

      IO.puts(
        "tool-list query count for #{if owner.id == admin.id, do: "admin", else: "guest"}: #{query_count}"
      )

      assert names != []
      assert query_count <= 4, "#{owner.id} used #{query_count} queries for one tool list"
    end
  end

  defp runtime!(owner_id, bundles) do
    runtime =
      Repo.insert!(%AgentRuntime{
        runtime_id: "ordered-profile-#{System.unique_integer([:positive])}",
        owner_user_id: owner_id
      })

    {:ok, _} =
      RuntimeProfiles.create_for_runtime(
        runtime,
        bundles,
        RuntimeProfiles.translated_permissions(bundles)
      )

    runtime
  end

  defp count_queries(fun) do
    caller = self()
    ref = make_ref()

    :ok =
      :telemetry.attach(
        ref,
        [:platform, :repo, :query],
        fn _, _, _, _ ->
          if self() == caller, do: send(caller, {ref, :query})
        end,
        nil
      )

    result =
      try do
        fun.()
      after
        :telemetry.detach(ref)
      end

    {result, drain_queries(ref, 0)}
  end

  defp drain_queries(ref, count) do
    receive do
      {^ref, :query} -> drain_queries(ref, count + 1)
    after
      0 -> count
    end
  end

  defp owner!(org_id, role, external? \\ false) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "tool-owner-#{n}@example.com",
        name: "Tool owner #{n}",
        oidc_sub: "tool-owner-#{n}"
      })

    membership =
      %OrgMembership{}
      |> OrgMembership.changeset(%{
        user_id: user.id,
        org_id: org_id,
        role: role
      })
      |> Repo.insert!()

    if external?,
      do: Tenancy.mark_membership_external(%{user_id: user.id, org_id: org_id, role: role})

    assert membership.user_id == user.id
    user
  end
end
