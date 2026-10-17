defmodule Platform.Prototypes.ToolsTest do
  @moduledoc "The `prototype` bundle end-to-end through `ToolSurface.execute/3`."

  use Platform.DataCase, async: false

  import Platform.PrototypeFixtures
  import Platform.TenancyFixtures

  alias Platform.Chat
  alias Platform.Federation.ToolSurface

  setup do
    scratch = scratch_storage!("prototype_tools_test")
    set_settings!(%{enabled: true, who_may_publish: "members"})
    org_a = tenant_org_id("proto-tool-a-#{System.unique_integer([:positive])}")
    org_b = tenant_org_id("proto-tool-b-#{System.unique_integer([:positive])}")
    root_agent = agent!(%{"org_id" => acme_org_id()})
    tenant_agent = agent!(%{"org_id" => org_a})
    {:ok, scratch: scratch, org_a: org_a, org_b: org_b, root: root_agent, tenant: tenant_agent}
  end

  defp ctx_for(agent), do: %{agent_id: agent.id}

  defp publish(agent, args), do: ToolSurface.execute("prototype_publish", args, ctx_for(agent))

  test "the bundle is listed and grantable, and not a default" do
    names = ToolSurface.list_tools(["prototype"]) |> Enum.map(& &1.name)
    assert names == ["prototype_publish", "prototype_versions", "prototype_rollback"]
    assert "prototype" in Platform.Access.RuntimeProfiles.valid_modules()
    refute "prototype" in Platform.Agents.AgentRuntime.default_tool_profile()
  end

  test "publish with a file map, then versions and rollback", ctx do
    assert {:ok, r1} =
             publish(ctx.tenant, %{
               "org_id" => ctx.org_a,
               "name" => "T",
               "files" => bundle_files()
             })

    assert r1.version == 1
    assert r1.url == "/proto/#{r1.prototype_id}/1/"

    assert {:ok, r2} =
             publish(ctx.tenant, %{
               "prototype_id" => r1.prototype_id,
               "files" => bundle_files("v2")
             })

    assert r2.version == 2

    assert {:ok, list} =
             ToolSurface.execute(
               "prototype_versions",
               %{"prototype_id" => r1.prototype_id},
               ctx_for(ctx.tenant)
             )

    assert Enum.map(list.versions, & &1.version) == [2, 1]
    assert list.total == 2 and list.has_more == false

    assert {:ok, %{latest_version: 1}} =
             ToolSurface.execute(
               "prototype_rollback",
               %{"prototype_id" => r1.prototype_id, "version" => 1},
               ctx_for(ctx.tenant)
             )
  end

  test "a tenant agent cannot publish into, or see, another org's prototypes", ctx do
    assert {:error, %{code: :unauthorized}} =
             publish(ctx.tenant, %{
               "org_id" => ctx.org_b,
               "name" => "X",
               "files" => bundle_files()
             })

    assert stored_prototype_files(ctx.scratch) == []

    {:ok, r} =
      publish(ctx.root, %{"org_id" => ctx.org_b, "name" => "B", "files" => bundle_files()})

    assert {:error, %{code: :not_found}} =
             ToolSurface.execute(
               "prototype_versions",
               %{"prototype_id" => r.prototype_id},
               ctx_for(ctx.tenant)
             )

    assert {:error, %{code: :not_found}} =
             publish(ctx.tenant, %{"prototype_id" => r.prototype_id, "files" => bundle_files()})
  end

  test "disabled install refuses with a code", ctx do
    set_settings!(%{enabled: false})

    assert {:error, %{code: :prototypes_disabled, recoverable: false}} =
             publish(ctx.tenant, %{
               "org_id" => ctx.org_a,
               "name" => "X",
               "files" => bundle_files()
             })
  end

  test "publish from a zip attachment in a space the agent is in; org from the space", ctx do
    {:ok, space} =
      Chat.create_space(%{
        name: "Proto Space",
        slug: "proto-#{System.unique_integer([:positive])}",
        kind: "channel",
        org_id: ctx.org_a
      })

    {:ok, _} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: ctx.tenant.id,
        display_name: "Proto Agent",
        joined_at: DateTime.utc_now()
      })

    zip = zip([%{name: "index.html", data: "<p>zipped</p>"}])

    {:ok, att} =
      ToolSurface.execute(
        "attachment_upload_inline",
        %{
          "space_id" => space.id,
          "filename" => "bundle.zip",
          "content_type" => "application/zip",
          "data_base64" => Base.encode64(zip)
        },
        ctx_for(ctx.tenant)
      )

    assert {:ok, r} =
             publish(ctx.tenant, %{
               "space_id" => space.id,
               "name" => "Zipped",
               "zip_attachment_id" => att.id
             })

    p = Platform.Prototypes.get_prototype(r.prototype_id)
    assert p.org_id == ctx.org_a
    assert p.space_id == space.id
  end
end
