defmodule Platform.Experiments.Surfaces.OpenQuestionClassifierTest do
  @moduledoc """
  The `meetings.open_question_classifier` surface (task 01a0e8b5 stage 3):
  registration, the control arm, and payload validation, including path
  traversal, a missing program file and a file `Imp.read!/1` refuses.
  """

  use Platform.DataCase

  alias Platform.Experiments.Subject
  alias Platform.Experiments.Surfaces
  alias Platform.Experiments.Surfaces.OpenQuestionClassifier, as: Surface
  alias Platform.Meetings.OpenQuestionPilot.Programs

  @baseline "baseline_v0.json"

  test "is registered with its key, subject type, path and one target" do
    assert Surfaces.get("meetings.open_question_classifier") == Surface
    assert Surface.subject_type() == "meeting"
    assert Surface.path() == :dispatch
    assert Surface.targets() == ["meetings.intent_classify"]

    assert %{"required" => ["arm"], "properties" => %{"arm" => _, "program" => _}} =
             Surface.payload_schema()
  end

  test "the control arm is the prompt" do
    assert Surface.control_payload("meetings.intent_classify", []) == {:ok, %{"arm" => "prompt"}}
    assert {:ok, %{"arm" => "prompt"}} = Surface.validate_payload(%{"arm" => "prompt"})
  end

  test "an imp_program arm naming the shipped baseline program validates" do
    assert File.regular?(Path.join(Programs.dir(), @baseline))

    assert Surface.validate_payload(%{arm: "imp_program", program: @baseline}) ==
             {:ok, %{"arm" => "imp_program", "program" => @baseline}}
  end

  describe "validate_payload refuses" do
    test "unknown keys and an unknown arm" do
      assert {:error, errors} = Surface.validate_payload(%{"arm" => "b", "extra" => 1})
      assert Enum.any?(errors, &(&1 =~ "unknown keys: extra"))
      assert Enum.any?(errors, &(&1 =~ "arm must be one of"))

      assert {:error, _} = Surface.validate_payload("prompt")
    end

    test "a missing program, and a program on the prompt arm" do
      assert {:error, ["program is required when arm is imp_program"]} =
               Surface.validate_payload(%{"arm" => "imp_program"})

      assert {:error, ["program must be absent when arm is prompt"]} =
               Surface.validate_payload(%{"arm" => "prompt", "program" => @baseline})
    end

    test "path traversal and anything that is not a plain basename" do
      for program <- [
            "../baseline_v0.json",
            "../../../../etc/passwd.json",
            "/etc/baseline_v0.json",
            "sub/baseline_v0.json",
            "Baseline.json",
            "baseline_v0.JSON",
            "dataset.jsonl",
            "README.md",
            "",
            42
          ] do
        assert {:error, [error]} =
                 Surface.validate_payload(%{"arm" => "imp_program", "program" => program}),
               "accepted #{inspect(program)}"

        assert error =~ "basename"
      end
    end

    test "a program file that does not exist" do
      assert {:error, [error]} =
               Surface.validate_payload(%{
                 "arm" => "imp_program",
                 "program" => "no_such_program.json"
               })

      assert error =~ "does not exist"
    end

    test "a program file Imp.read!/1 refuses" do
      name = "zz_corrupt_#{System.unique_integer([:positive])}.json"
      path = Path.join(Programs.dir(), name)
      on_exit(fn -> File.rm(path) end)
      File.write!(path, ~s({"artifact_type": "imp_program_artifact", "payload": {}}))

      assert {:error, [error]} =
               Surface.validate_payload(%{"arm" => "imp_program", "program" => name})

      assert error =~ "not a readable Imp program"
    end
  end

  describe "subject_attributes/1" do
    test "a meeting reads its project and the project's org" do
      org = Platform.TenancyFixtures.tenant_org_id("soylent")

      {:ok, project} =
        Platform.Tasks.create_project(%{
          name: "OQ attrs #{System.unique_integer([:positive])}",
          org_id: org
        })

      {:ok, meeting} = Platform.Meetings.create_meeting(%{project_id: project.id, name: "attrs"})

      assert Surface.subject_attributes(meeting.id) == %{org_id: org, project_id: project.id}
    end

    test "an unknown, malformed or non-binary id is %{} and never raises" do
      assert Surface.subject_attributes(Ecto.UUID.generate()) == %{}
      assert Surface.subject_attributes("not-a-uuid") == %{}
      assert Surface.subject_attributes("0123456789abcdef") == %{}
      assert Surface.subject_attributes(nil) == %{}
    end
  end

  test "resolving with no experiment falls to :none, never raising" do
    subject = Subject.new("meeting", Ecto.UUID.generate())

    assert Surfaces.resolve(
             "meetings.open_question_classifier",
             "meetings.intent_classify",
             subject
           ) ==
             :none
  end
end
