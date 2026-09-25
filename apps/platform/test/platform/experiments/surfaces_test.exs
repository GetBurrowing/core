defmodule Platform.Experiments.SurfacesTest do
  @moduledoc """
  The surfaces registry and resolver (task 01a0d415, the experimentation-layer
  ADR-0052). The resolver's rules moved from `PromptTemplates`; the prompt path's
  own regression tests stay in `prompt_templates_test.exs`, unmodified.
  """

  use Platform.DataCase, async: true

  import ExUnit.CaptureLog

  alias Platform.Experiments
  alias Platform.Experiments.Assignment
  alias Platform.Experiments.Experiment
  alias Platform.Experiments.Subject
  alias Platform.Experiments.SurfaceDefault
  alias Platform.Experiments.Surfaces
  alias Platform.Experiments.Surfaces.DispatchPrompt
  alias Platform.Orchestration.PromptTemplate

  @surface "dispatch.prompt"

  defp unique, do: System.unique_integer([:positive])

  setup do
    template =
      %PromptTemplate{}
      |> PromptTemplate.changeset(%{
        slug: "surfaces.test.v#{unique()}",
        name: "Surfaces test",
        content: "LIVE-BODY"
      })
      |> Repo.insert!()

    %{template: template}
  end

  # A running experiment where every NEW subject lands in "treatment".
  defp running_on(template) do
    {:ok, experiment} =
      Experiments.create_experiment(%{slug: "surf-#{unique()}", name: "Surfaces"})

    {:ok, _} =
      Experiments.add_variant(experiment, %{slug: "treatment", content: "TREATMENT", weight: 1})

    {:ok, running} = Experiments.activate(experiment, template)

    {1, _} =
      Repo.update_all(
        from(v in Platform.Experiments.Variant,
          where: v.experiment_id == ^running.id and v.slug == "control"
        ),
        set: [weight: 0]
      )

    running
  end

  defp subject, do: Subject.new("task", Ecto.UUID.generate())

  defp assignment_count(experiment) do
    Repo.aggregate(from(a in Assignment, where: a.experiment_id == ^experiment.id), :count)
  end

  describe "registry" do
    test "dispatch.prompt is registered and resolvable by key" do
      assert Surfaces.get(@surface) == DispatchPrompt
      assert DispatchPrompt in Surfaces.list()
      assert Surfaces.get("dispatch.model") == nil
      assert Surfaces.get(nil) == nil
    end

    test "every surface declares a path in :draft | :dispatch and a plain-data schema" do
      for surface <- Surfaces.list() do
        assert surface.path() in [:draft, :dispatch]
        assert is_binary(surface.key())
        assert is_binary(surface.subject_type())
        assert {:ok, _json} = Jason.encode(surface.payload_schema())
      end
    end

    test "dispatch.prompt validates its payload" do
      assert {:ok, %{"content" => "x"}} = DispatchPrompt.validate_payload(%{"content" => "x"})
      assert {:error, [_]} = DispatchPrompt.validate_payload(%{"content" => ""})
      assert {:error, [_]} = DispatchPrompt.validate_payload(%{})
    end

    test "chat.context_summary is registered on the :draft path with its one target" do
      alias Platform.Experiments.Surfaces.ChatContextSummary

      assert Surfaces.get("chat.context_summary") == ChatContextSummary
      assert ChatContextSummary.path() == :draft
      assert ChatContextSummary.subject_type() == "message"
      assert ChatContextSummary.targets() == ["chat.context_summary"]
    end

    test "chat.context_summary validates its payload" do
      alias Platform.Experiments.Surfaces.ChatContextSummary, as: S

      assert {:ok, %{"provider" => "ollama", "model" => "m", "max_messages" => 30}} =
               S.validate_payload(%{
                 "provider" => "ollama",
                 "model" => " m ",
                 "max_messages" => 30
               })

      assert {:ok, %{"provider" => "anthropic"}} =
               S.validate_payload(%{provider: "anthropic", system_prompt: "  "})

      assert {:error, ["unknown keys: tools"]} =
               S.validate_payload(%{"provider" => "openai", "tools" => []})

      for n <- [0, 31, "5", 1.5] do
        assert {:error, ["max_messages must be an integer in 1..30"]} =
                 S.validate_payload(%{"provider" => "ollama", "max_messages" => n})
      end

      assert {:error, [_]} = S.validate_payload(%{"provider" => "none"})
      assert {:error, [_]} = S.validate_payload(%{})

      assert {:error, ["system_prompt must be at most 4000 chars"]} =
               S.validate_payload(%{
                 "provider" => "ollama",
                 "system_prompt" => String.duplicate("x", 4001)
               })

      assert {:error, ["max_tokens must be an integer in 1..4096"]} =
               S.validate_payload(%{"provider" => "ollama", "max_tokens" => 0})

      assert {:error, ["payload must be an object"]} = S.validate_payload("x")
    end

    test "dispatch.prompt's control payload is the template's current content", %{template: t} do
      assert DispatchPrompt.control_payload(t.slug, []) == {:ok, %{"content" => "LIVE-BODY"}}
      assert DispatchPrompt.control_payload("no.such.slug", []) == {:error, :template_not_found}
    end
  end

  describe "resolve/4" do
    test "activation binds the prompt surface", %{template: template} do
      experiment = running_on(template)

      assert experiment.surface_key == @surface
      assert experiment.surface_target == template.slug
    end

    test "is sticky across calls", %{template: template} do
      experiment = running_on(template)
      s = subject()

      assert {:variant, %Experiment{id: id}, "treatment", %{"content" => "TREATMENT"}} =
               Surfaces.resolve(@surface, template.slug, s)

      assert id == experiment.id

      # Every new subject would now get control; the existing one must not move.
      Repo.update_all(
        from(v in Platform.Experiments.Variant, where: v.experiment_id == ^experiment.id),
        set: [weight: 0]
      )

      Repo.update_all(
        from(v in Platform.Experiments.Variant,
          where: v.experiment_id == ^experiment.id and v.slug == "control"
        ),
        set: [weight: 1000]
      )

      assert {:variant, _, "treatment", _} = Surfaces.resolve(@surface, template.slug, s)
      assert assignment_count(experiment) == 1
    end

    test "a stopped experiment still honours an existing assignment and creates none",
         %{template: template} do
      experiment = running_on(template)
      in_flight = subject()

      assert {:variant, _, "treatment", _} = Surfaces.resolve(@surface, template.slug, in_flight)
      {:ok, _stopped} = Experiments.stop(experiment)

      assert {:variant, _, "treatment", _} = Surfaces.resolve(@surface, template.slug, in_flight)
      assert Surfaces.resolve(@surface, template.slug, subject()) == :none
      assert assignment_count(experiment) == 1
    end

    test "a pending-approval experiment creates no assignment", %{template: template} do
      experiment = running_on(template)

      {:ok, _pending} =
        experiment |> Experiment.changeset(%{approval_state: "pending"}) |> Repo.update()

      assert Surfaces.resolve(@surface, template.slug, subject()) == :none
      assert assignment_count(experiment) == 0
    end

    test "with no experiment, the latest promoted default applies", %{template: template} do
      for {seq, body} <- [{1, "OLD"}, {2, "NEW"}] do
        %SurfaceDefault{}
        |> SurfaceDefault.changeset(%{
          surface_key: @surface,
          surface_target: template.slug,
          seq: seq,
          kind: "promote",
          payload: %{"content" => body}
        })
        |> Repo.insert!()
      end

      assert Surfaces.resolve(@surface, template.slug, subject()) ==
               {:default, %{"content" => "NEW"}}
    end

    test "a project-scoped experiment reads the task's project from the dispatch surface",
         %{template: template} do
      org = Platform.TenancyFixtures.tenant_org_id("soylent")
      {:ok, p} = Platform.Tasks.create_project(%{name: "Scoped #{unique()}", org_id: org})
      {:ok, q} = Platform.Tasks.create_project(%{name: "Other #{unique()}", org_id: org})
      {:ok, in_p} = Platform.Tasks.create_task(%{project_id: p.id, title: "in P"})
      {:ok, in_q} = Platform.Tasks.create_task(%{project_id: q.id, title: "in Q"})

      experiment = running_on(template)
      {:ok, experiment} = experiment |> Experiment.changeset(%{project_id: p.id}) |> Repo.update()
      assert experiment.org_id == org

      assert Surfaces.resolve(@surface, template.slug, Subject.new("task", in_q.id)) == :none

      assert {:variant, _, "treatment", _} =
               Surfaces.resolve(@surface, template.slug, Subject.new("task", in_p.id))

      assert assignment_count(experiment) == 1
    end

    test "an unknown surface resolves to :none", %{template: template} do
      assert Surfaces.resolve("no.such.surface", template.slug, subject()) == :none
    end

    test "never raises: a subject id that is not a uuid falls through and logs",
         %{template: template} do
      _experiment = running_on(template)

      log =
        capture_log(fn ->
          assert Surfaces.resolve(@surface, template.slug, Subject.new("task", "not-a-uuid")) ==
                   :none
        end)

      assert log =~ "experiment resolution failed"
    end
  end
end
