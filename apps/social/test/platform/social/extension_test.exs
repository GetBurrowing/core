defmodule Platform.Social.ExtensionTest do
  use ExUnit.Case, async: true

  alias Platform.Social.Extension

  test "is the registered extension in this module's build" do
    assert Extension in Platform.Extensions.list()
  end

  test "every required callback answers without raising; the only tool bundle is social" do
    assert Extension.canvas_kinds() == [Platform.Social.CanvasKinds.SocialPostCard]
    assert [%{name: "social"} = bundle] = Extension.mcp_tool_bundles()
    assert bundle.tool_names == Platform.Social.ToolDefinitions.names()
    assert bundle.owns_tool?.("social_post_publish")
    refute bundle.owns_tool?.("task_get")
    assert Extension.runtime_channel_events() == []
    assert Extension.live_hooks() == []
    assert Extension.experiment_surfaces() == []
    assert Extension.experiment_metrics() == %{}
    assert Extension.runtime_disconnected("some-runtime") == :ok
    assert {:error, _} = Extension.handle_runtime_event("anything", "some-runtime", %{})
  end

  test "declares the social_post_approval inbox kind, kept listed on open (Social 3/7)" do
    assert [
             %{
               kind: "social_post_approval",
               source_type: "social_post",
               label: "Post needs approval",
               icon: "hero-megaphone",
               stays_listed_on_open: true
             }
           ] = Extension.inbox_kinds()

    assert "social_post_approval" in Platform.Inbox.Item.kinds()
    assert "social_post" in Platform.Inbox.Item.source_types()
    assert "social_post_approval" in Platform.Inbox.action_kinds()
    refute "social_post_approval" in Platform.Inbox.push_kinds()
    refute "social_post_approval" in Platform.Mobile.AppEntities.approval_kinds()
  end

  test "contributes the Social rail item and the /m/social live page (Social 7/7)" do
    assert Extension.rail_items() == [
             %{
               key: :social,
               label: "Social",
               path: "/m/social",
               hero_icon: "hero-megaphone",
               cluster: :working,
               root_only?: false
             }
           ]

    assert [%{prefix: "social", live_view: PlatformWeb.SocialLive}] = Extension.live_pages()
    assert %{live_view: PlatformWeb.SocialLive} = Platform.Extensions.live_page_for("social")
  end

  test "migrations_path is an existing directory and is among the migration paths core runs" do
    path = Extension.migrations_path()

    assert is_binary(path)
    assert File.dir?(path)
    assert path in Platform.Extensions.migrations_paths()
    assert path in Platform.Release.migrations_paths(Platform.Repo)
  end

  test "Platform.Extensions.validate/0 is :ok with Social registered" do
    assert Platform.Extensions.validate() == :ok
    assert Platform.Extensions.validate!() == :ok
  end
end
