defmodule Platform.Social.ToolDefinitionsTest do
  use ExUnit.Case, async: true

  alias Platform.Federation.ToolDoc
  alias Platform.Social.{Extension, ToolDefinitions}

  # Social 4/7's six, Social 5/7's social_clip_render and social_clip_list,
  # and Social 6/7's social_task_request.
  @nine ~w(social_profile_list social_profile_get social_draft_create social_draft_update
           social_post_list social_clip_propose social_clip_render social_clip_list
           social_task_request)

  @sentence "A human approves this in Burrow and the platform publishes it; agents cannot approve or publish."

  test "exactly the nine tools, names() and definitions() agree" do
    assert Enum.sort(ToolDefinitions.names()) == Enum.sort(@nine)
    assert Enum.map(ToolDefinitions.definitions(), & &1.name) == ToolDefinitions.names()
  end

  test "no tool name contains publish or approve" do
    for name <- ToolDefinitions.names() do
      refute name =~ "publish"
      refute name =~ "approve"
    end
  end

  test "every rubric field is non-blank and every parameter has type, required, description" do
    for tool <- ToolDefinitions.definitions(),
        key <- [:name, :description, :returns, :limitations, :when_to_use] do
      value = Map.fetch!(tool, key)
      assert is_binary(value) and String.trim(value) != "", "#{tool.name}.#{key} is blank"
    end

    for tool <- ToolDefinitions.definitions(), {param, meta} <- tool.parameters do
      assert is_binary(meta.type), "#{tool.name}.#{param}"
      assert is_boolean(meta.required), "#{tool.name}.#{param}"
      assert is_binary(meta.description) and meta.description != "", "#{tool.name}.#{param}"

      if meta.type == "array",
        do: assert(meta.schema == %{type: "array", items: %{type: "string"}})
    end
  end

  test "every description, and its rendered MCP form, carries the human-approves sentence" do
    assert ToolDefinitions.human_approves() == @sentence

    for tool <- ToolDefinitions.definitions() do
      assert tool.description =~ @sentence
      assert ToolDoc.render_description(tool) =~ @sentence
    end
  end

  test "no definition takes an approver field" do
    for tool <- ToolDefinitions.definitions() do
      for field <- ~w(approved_by_user_id approved_at rejection_reason rejected_at)a do
        refute Map.has_key?(tool.parameters, field), "#{tool.name} takes #{field}"
      end
    end
  end

  test "deny_message names the missing publish/approve tool, and only for those names" do
    text =
      "There is no publish or approve tool: a human approves in Burrow and the platform publishes."

    assert Extension.deny_message("social_post_publish") == text
    assert Extension.deny_message("social_post_approve") == text
    assert Extension.deny_message("social_draft_create") == nil
    assert Extension.deny_message("social_whatever") == nil
  end
end
