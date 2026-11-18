defmodule Platform.Social.StudioSourceTest do
  @moduledoc """
  Social Studio slice B source guards: what the
  Studio context may and may not reference. These read the source on purpose;
  a path added later that breaks the rule fails here before it ships.
  """
  use ExUnit.Case, async: true

  @lib Path.expand("../../../lib", __DIR__)
  defp read(rel), do: File.read!(Path.join(@lib, rel))

  defp lib_files, do: Path.wildcard(Path.join(@lib, "**/*.ex"))

  test "only Studio calls the Studio content changeset" do
    users =
      for path <- lib_files(),
          File.read!(path) =~ "studio_content_changes",
          do: Path.relative_to(path, @lib)

    assert Enum.sort(users) == ["platform/social/post.ex", "platform/social/studio.ex"]
  end

  test "the Studio context never references a publisher or Publishing" do
    source = read("platform/social/studio.ex")

    for forbidden <- ["Publishing", "Publisher", "ZernioHTTP", "ClipPublish", "PublishRetry"] do
      refute source =~ forbidden,
             "studio.ex mentions #{forbidden}; Studio must never reach a send path"
    end
  end

  test "nothing in Studio deletes a post or a receipt" do
    source = read("platform/social/studio.ex")
    refute source =~ ~r/Repo\.delete(_all)?\(/
    refute source =~ "delete_all"
  end

  test "agents reach Studio edits only through save_version" do
    source = read("platform/social/agent_drafts.ex")
    assert source =~ "Studio.save_version("

    refute source =~
             ~r/Studio\.(approve_version|plan_post|cancel_plan|revoke_approval|accept_render)/
  end

  test "flow is never written after insert by Studio" do
    refute read("platform/social/studio.ex") =~ ~r/change\([^)]*flow:|flow: *"(legacy)"/
  end
end
