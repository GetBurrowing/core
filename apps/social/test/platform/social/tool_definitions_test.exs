defmodule Platform.Social.ToolDefinitionsTest do
  use ExUnit.Case, async: true

  alias Platform.Federation.ToolDoc
  alias Platform.Social.{Extension, ToolDefinitions}

  # Social 4/7's six, Social 5/7's social_clip_render and social_clip_list,
  # Social 6/7's social_task_request, and Clip Studio 1/9's social_clip_submit
  # and six clip job tools, and Social authoring 2/11's two idea tools, and 7/11's social_idea_note_add.
  @job_tools ~w(social_clip_job_list social_clip_job_claim social_clip_job_source social_clip_job_progress
                social_clip_job_complete social_clip_job_fail)

  @nineteen ~w(social_profile_list social_profile_get social_draft_create social_draft_update
              social_post_list social_clip_propose social_clip_submit social_clip_render
              social_clip_list social_task_request) ++
              @job_tools ++ ~w(social_idea_create social_idea_list social_idea_note_add)

  @sentence "A human approves this in Burrow and the platform publishes it; agents cannot approve or publish."

  test "exactly the nineteen tools, names() and definitions() agree" do
    assert Enum.sort(ToolDefinitions.names()) == Enum.sort(@nineteen)
    assert Enum.map(ToolDefinitions.definitions(), & &1.name) == ToolDefinitions.names()
  end

  test "social_post_list documents the read-only Clip Studio post fields" do
    list = Enum.find(ToolDefinitions.definitions(), &(&1.name == "social_post_list"))

    for field <- ~w(clip_id platform_post_id publish_attempts published_at) do
      assert list.returns =~ field
      assert list.limitations =~ field
    end

    assert list.limitations =~ "read-only"
  end

  test "no social tool can approve, reject, undo or retry a clip" do
    for definition <- ToolDefinitions.definitions() do
      for verb <- ~w(approve reject undo retry decision) do
        refute definition.name =~ verb, "#{definition.name} names #{verb}"
      end

      refute Map.has_key?(definition.parameters, :account_ids) and
               definition.name =~ "clip",
             "#{definition.name} takes account_ids for a clip"
    end

    # The decisions live in Platform.Social, outside the tool surface.
    assert function_exported?(Platform.Social, :approve_clip, 5)
    refute Enum.any?(ToolDefinitions.names(), &(&1 =~ "decide"))
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

      if meta.type == "array" do
        if param == :picks do
          assert tool.name == "social_clip_job_progress"
          assert meta.schema.type == "array"
          assert meta.schema.maxItems == 100
          assert meta.schema.items.type == "object"
          assert meta.schema.items.required == ["candidate_id", "in_s", "out_s"]
          assert meta.schema.items.additionalProperties == false

          assert Map.keys(meta.schema.items.properties) |> Enum.sort() == [
                   :candidate_id,
                   :in_s,
                   :out_s
                 ]
        else
          assert meta.schema == %{type: "array", items: %{type: "string"}}
        end
      end
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

  # Clip Studio 1/9: the review state is written only by a human approver.
  test "no tool exposes a writable review parameter" do
    exposed =
      for tool <- ToolDefinitions.definitions(),
          field <- ~w(review_status review_note reviewed_by_user_id reviewed_at rev)a,
          Map.has_key?(tool.parameters, field),
          do: {tool.name, field}

    # only social_clip_list's read filter
    assert exposed == [{"social_clip_list", :review_status}]

    submit = Enum.find(ToolDefinitions.definitions(), &(&1.name == "social_clip_submit"))
    assert submit.parameters.profile_id.required
    assert submit.parameters.file_id.required
    refute submit.parameters.title.required
    assert submit.limitations =~ "file_not_in_project"
    assert submit.limitations =~ "Only a human approver approves or rejects"
  end

  test "job tool docs state the clip contract" do
    for name <- @job_tools do
      tool = Enum.find(ToolDefinitions.definitions(), &(&1.name == name))
      assert tool, "#{name} is not defined"

      for phrase <- [
            "clip review",
            "--apply",
            "clip project info --json",
            "picks JSON",
            ~s(extends = "how-to-computer")
          ] do
        assert tool.description =~ phrase, "#{name} does not say #{phrase}"
      end

      assert tool.description =~ "payload.clip_user_profile"
      assert tool.limitations =~ "not_found"
      assert tool.limitations =~ "[privacy] mode"

      for code <-
            ~w(already_claimed not_claimer job_closed invalid_progress file_not_in_project not_a_video),
          do: assert(tool.limitations =~ code, "#{name} limitations miss #{code}")
    end

    complete = Enum.find(ToolDefinitions.definitions(), &(&1.name == "social_clip_job_complete"))

    assert Map.keys(complete.parameters) |> Enum.map(&to_string/1) |> Enum.sort() ==
             Enum.sort(["job_id" | Platform.Social.ClipJobs.result_keys()])

    refute Enum.any?(ToolDefinitions.names(), &(&1 =~ ~r/enqueue|create_job/))
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
