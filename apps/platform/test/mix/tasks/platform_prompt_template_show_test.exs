defmodule Mix.Tasks.Platform.PromptTemplate.ShowTest do
  @moduledoc """
  The case that matters is the ABSENT row.

  A missing `prompt_templates` row reading as an empty template is the exact
  ambiguity this task exists to remove, so the unknown-slug test is the one
  with teeth: it asserts a raise (exit status 1 at the CLI) AND that the
  message names the slug, because a bare raise would leave an operator
  guessing which environment was short a row.

  `async: false` and a real database: `run/1` drives `Mix.Task.run("app.start")`
  and `Mix.shell()`, both global.
  """

  use Platform.DataCase, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Platform.PromptTemplate.Show
  alias Platform.Orchestration.PromptTemplates

  doctest Show

  @content "Hello {{agent_roster}}\nbody line\n"
  # sha256 of @content, computed independently of the module under test.
  @content_sha :crypto.hash(:sha256, "Hello {{agent_roster}}\nbody line\n")
               |> Base.encode16(case: :lower)

  defp seed_template(slug) do
    {:ok, template} =
      PromptTemplates.create_template(%{
        slug: slug,
        name: "Show task fixture",
        content: @content,
        variables: ["agent_roster"],
        updated_by: "show_task_test"
      })

    template
  end

  describe "unknown slug" do
    test "raises a named Mix.Error rather than printing an empty template" do
      error =
        assert_raise Mix.Error, fn ->
          Show.fetch!("meetings.no_such_template.v1")
        end

      assert error.message =~ "meetings.no_such_template.v1"
      assert error.message =~ "ABSENT, not empty"
    end

    test "run/1 propagates the raise, so the CLI exits non-zero" do
      assert_raise Mix.Error, fn ->
        capture_io(fn -> Show.run(["--slug", "meetings.no_such_template.v1"]) end)
      end
    end
  end

  describe "known slug" do
    test "prints the live row's content and its sha256" do
      slug = "test.show.#{System.unique_integer([:positive])}"
      seed_template(slug)

      output = capture_io(fn -> Show.run(["--slug", slug]) end)

      assert output =~ "slug:       #{slug}"
      assert output =~ "sha256:     #{@content_sha}"
      assert output =~ "bytes:      #{byte_size(@content)}"
      assert output =~ ~s(variables:  ["agent_roster"])
      assert output =~ "updated_by: \"show_task_test\""
      assert output =~ "--- content ---"
      assert output =~ "Hello {{agent_roster}}"
    end

    test "--sha-only prints the sha and suppresses the body" do
      slug = "test.show.#{System.unique_integer([:positive])}"
      seed_template(slug)

      output = capture_io(fn -> Show.run(["--slug", slug, "--sha-only"]) end)

      assert output =~ "sha256:     #{@content_sha}"
      refute output =~ "--- content ---"
      refute output =~ "body line"
    end

    test "reads the DB row, not do_default_templates/0" do
      slug = "test.show.#{System.unique_integer([:positive])}"
      template = seed_template(slug)

      {:ok, _} = PromptTemplates.update_template(template, %{content: "RUNTIME EDITED BODY"})

      output = capture_io(fn -> Show.run(["--slug", slug]) end)

      assert output =~ "RUNTIME EDITED BODY"
      refute output =~ "body line"

      assert output =~
               "sha256:     " <>
                 (:crypto.hash(:sha256, "RUNTIME EDITED BODY") |> Base.encode16(case: :lower))
    end
  end

  describe "missing --slug" do
    test "raises rather than defaulting to some template" do
      assert_raise Mix.Error, ~r/--slug/, fn ->
        capture_io(fn -> Show.run([]) end)
      end
    end
  end
end
