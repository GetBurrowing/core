defmodule Platform.Access.ToolPermissionsTest do
  use Platform.DataCase, async: false

  alias Platform.Access.{Registry, ToolPermissions}
  alias Platform.Federation.ToolSurface
  alias Platform.FixtureExtension

  test "every listed core tool has one registered, grantable permission" do
    FixtureExtension.register([])

    names = Enum.map(ToolSurface.tool_definitions(), & &1.name)
    assert names == Enum.uniq(names)

    for name <- names do
      permission = ToolPermissions.for_tool(name)
      assert Registry.permission?(permission), "#{name} has no registered permission"
      refute Registry.install_level?(permission), "#{name} is install-level"
    end

    assert ToolPermissions.for_tool("mail_inbound_list") == "mail.use"
    assert ToolPermissions.for_tool("mail_inbound_get") == "mail.use"
    assert ToolPermissions.for_tool("not_a_tool") == nil
  end

  test "bundle translation includes policy-gated feedback and mail tools" do
    assert "agents.manage_own" in ToolPermissions.bundle_permissions("federation")
    assert "mail.use" in ToolPermissions.bundle_permissions("mail")

    assert ToolPermissions.for_tool("feedback.submit") == "agents.manage_own"
    assert "agents.manage_own" in ToolPermissions.bundle_permissions("federation")
  end

  test "extension tools use explicit mapping or the bundle fallback" do
    FixtureExtension.register()
    assert ToolPermissions.for_tool("fixture_echo") == "skills.read"
    assert ToolPermissions.for_tool("fixture_hidden") == Registry.bundle_permission("fixture")

    assert ToolPermissions.bundle_permissions("fixture") ==
             MapSet.new(["skills.read", Registry.bundle_permission("fixture")])
  end
end
