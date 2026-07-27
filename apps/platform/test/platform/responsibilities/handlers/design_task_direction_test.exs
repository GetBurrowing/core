defmodule Platform.Responsibilities.Handlers.DesignTaskDirectionTest do
  @moduledoc """
  Guards for `design.task_direction` — the ADR-0046 pre-plan design step
  (stack member 7, task `019f9b29-5ecd` stage 3).

  ## Verification label: GUARD, not detector

  Every test here is a guard. The handler, the provider clause, the bundle
  key and the template row are all NEW in this stage, so nothing in this file
  can detonate against unfixed `main` — there is no prior behaviour to be
  wrong. The mandatory detector for this task lives in stage 4, where the
  design step is actually fired.

  What these guards CAN do is detonate against this stage's own commit, and
  two of them were checked that way rather than assumed:

    * Delete the `handler_for("design.task_direction")` clause from
      `Providers.Design` and `provider_coverage_test.exs` goes red naming the
      key — the guard member 2 shipped, doing exactly the job it was built
      for.
    * Delete the `build_prompt/1` forwarding from `Providers.Design` and
      "provider build_prompt reaches the handler" goes red, because the
      Router probes that callback on the PROVIDER, never on the handler.

  ## Vacuity disclosure

  Not every assertion below earns its keep, and saying which is more useful
  than padding the table:

    * **`register/0` returns the canonical spec** — passes trivially. It is a
      restatement of the module it tests, so it detects nothing today. It is
      a pin: it earns its keep the first time someone edits the registration
      without meaning to change the contract.
    * **`handler_for("design.critique")` still resolves** — a real positive
      control. Without it, a catch-all clause returning `DesignTaskDirection`
      for every key would pass the main assertion.
    * **The architect control in the scope-fence test** — the load-bearing
      one. The fence guard is an ABSENCE assertion, and an absence assertion
      passes against an empty string, a failed render, or a probe set made of
      words nothing ever says. The control renders
      `ArchitectureReviewPlan.build_prompt/1` over the SAME probe set and
      requires it to fire, so the probes are proven capable of firing.

  ## Why the absence assertions run against the USER slot only

  The stage brief specified that `build_prompt/1` output must contain none of
  "module boundary", "data model", "schema" — and, in the same paragraph,
  specified a system prompt that says *"Do NOT comment on module boundaries,
  data model, data flow, schema design, or code structure"*. Those two
  requirements contradict each other: a prohibition that cannot name what it
  prohibits is not a prohibition.

  Resolved by splitting the slots, which is what the requirement actually
  means. The SYSTEM slot must NAME the prohibited domains (asserted
  positively). The USER slot — the deliverable, the context, everything the
  model is asked to produce — must contain none of them.
  """
  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Platform.Chat
  alias Platform.Chat.Canvas
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo
  alias Platform.Responsibilities.BuiltIns
  alias Platform.Responsibilities.Handlers
  alias Platform.Responsibilities.Handlers.ArchitectureReviewPlan
  alias Platform.Responsibilities.Handlers.DesignTaskDirection
  alias Platform.Responsibilities.Providers
  alias Platform.Responsibilities.Responsibility
  alias Platform.Roles
  alias Platform.Roles.RoleResponsibility
  alias Platform.Tasks
  alias Platform.Tasks.CanvasAttachment
  alias Platform.Tasks.Task, as: TaskSchema

  # Vocabulary that belongs to the Architect, not the Designer. Chosen so
  # that the paired control below actually fires: the shipped
  # `architecture.review_plan.v1` body says "editing the same module
  # concurrently" and "Duplicate abstraction", so a probe set the architect
  # prompt could not trip would be a probe set that proves nothing.
  @architectural_vocabulary [
    "module",
    "abstraction",
    "schema",
    "data model",
    "data flow",
    "code structure"
  ]

  # ── fixtures ──────────────────────────────────────────────────────────────

  defp project! do
    {:ok, project} =
      Tasks.create_project(%{name: "Direction Project #{System.unique_integer([:positive])}"})

    project
  end

  defp task!(project_id, attrs \\ %{}) do
    now = DateTime.utc_now()

    %TaskSchema{}
    |> Ecto.Changeset.change(
      Map.merge(
        %{
          project_id: project_id,
          title: "Direction Task #{System.unique_integer([:positive])}",
          status: "planning",
          inserted_at: now,
          updated_at: now
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  # Hand-built rather than `ExecutionSpace.find_or_create/1` for the reason
  # `Platform.Design.BrandTest` documents: that helper derives its slug from
  # the task UUID's millisecond field, so two tasks created inside one
  # millisecond collide on `chat_spaces_unique_org_slug`. Same substitution,
  # same guard that it stays findable.
  defp execution_space!(task) do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{
        name: "direction-exec-#{n}",
        slug: "direction-exec-#{n}",
        kind: "execution",
        metadata: %{"task_id" => task.id}
      })

    assert %{id: found} = Platform.Orchestration.ExecutionSpace.find_by_task_id(task.id)
    assert found == space.id

    space
  end

  defp responsibility do
    [spec] = DesignTaskDirection.register()
    struct!(Responsibility, Map.put(spec, :id, Ecto.UUID.generate()))
  end

  defp canvas_count, do: Repo.aggregate(Canvas, :count, :id)

  defp attachment_count(task_id) do
    Repo.aggregate(from(a in CanvasAttachment, where: a.task_id == ^task_id), :count, :id)
  end

  # ── register/0 ────────────────────────────────────────────────────────────

  describe "register/0" do
    # Vacuity: passes trivially. A pin on the contract, not a detector.
    test "returns exactly one spec carrying the canonical registration" do
      specs = DesignTaskDirection.register()

      assert length(specs) == 1
      [spec] = specs

      assert spec.key == "design.task_direction"
      assert spec.feature == "design"
      assert spec.trigger_kind == "event_topic"
      assert spec.trigger_config == %{"topic" => "task:planning_started"}
      assert spec.scope == "per_project"

      assert spec.context_provided == ["task_payload", "brand_context", "attached_canvases"]

      assert spec.default_prompt_template == "design.task_direction.v1"
      assert spec.cost_profile == "low_freq_capable"
      assert spec.output_contract == %{"direction" => "string"}

      assert spec.metadata["owner"] == "platform.design"
      assert spec.metadata["role"] == "designer"
      assert spec.metadata["adr"] == "0046"
      assert spec.metadata["status"] == "active"
    end

    test "the accessors agree with the spec" do
      [spec] = DesignTaskDirection.register()

      assert DesignTaskDirection.key() == spec.key
      assert DesignTaskDirection.template_slug() == spec.default_prompt_template
    end
  end

  # ── provider wiring ───────────────────────────────────────────────────────

  describe "provider wiring" do
    test "Providers.Design.handler_for/1 maps the new key to this module" do
      assert Providers.Design.handler_for("design.task_direction") ==
               Handlers.DesignTaskDirection

      assert Providers.Design.handler_for(responsibility()) ==
               Handlers.DesignTaskDirection
    end

    # Positive control for the assertion above: a catch-all clause returning
    # DesignTaskDirection for every key would satisfy it, and this is what
    # distinguishes that.
    test "the other design keys still resolve to their own handlers" do
      assert Providers.Design.handler_for("design.critique") == Handlers.DesignCritique
      assert Providers.Design.handler_for("design.spec_writer") == Handlers.DesignSpecWriter
      assert Providers.Design.handler_for("design.brand_check") == Handlers.DesignBrandCheck
      assert Providers.Design.handler_for("design.not_a_key") == nil
    end

    test "the handler is in BuiltIns.providers/0" do
      assert Handlers.DesignTaskDirection in BuiltIns.providers()
    end

    # The Router probes `build_prompt/1` on the PROVIDER module, never on the
    # handler, so this forwarding is the only thing that makes the handler's
    # prompt reachable at dispatch time.
    test "provider build_prompt/1 reaches the handler for this key" do
      context =
        DesignTaskDirection.gather_context(%{})
        |> Map.put(:__responsibility__, responsibility())

      assert {:ok, %{system: system, user: user}} = Providers.Design.build_prompt(context)
      assert is_binary(system) and system != ""
      assert is_binary(user) and user != ""
    end

    # The narrow return contract: anything other than `:no_build_prompt`
    # would convert a routing miss into a DROPPED dispatch, which is worse
    # than the legacy render path it falls back to.
    test "provider build_prompt/1 returns exactly :no_build_prompt for a handler without one" do
      critique = %Responsibility{
        id: Ecto.UUID.generate(),
        key: "design.critique",
        feature: "design"
      }

      assert {:error, :no_build_prompt} =
               Providers.Design.build_prompt(%{__responsibility__: critique})

      assert {:error, :no_build_prompt} = Providers.Design.build_prompt(%{})
      assert {:error, :no_build_prompt} = Providers.Design.build_prompt(nil)
    end
  end

  # ── role bundle ───────────────────────────────────────────────────────────

  describe "the designer role bundle" do
    test "seed_defaults/0 lands all four keys, and a second run inserts nothing" do
      # The migration already seeded this DB, so clear the designer pairs
      # first — otherwise "seed_defaults inserted the key" would be
      # indistinguishable from "the key was already there".
      Repo.delete_all(from(rr in RoleResponsibility, where: rr.role_key == "designer"))
      assert Roles.bundle_for("designer") == []

      before = Repo.aggregate(RoleResponsibility, :count, :id)

      assert :ok = Platform.Roles.Seeds.seed_defaults()

      assert Roles.bundle_for("designer") == [
               "design.brand_check",
               "design.critique",
               "design.spec_writer",
               "design.task_direction"
             ]

      after_first = Repo.aggregate(RoleResponsibility, :count, :id)
      assert after_first == before + 4

      assert :ok = Platform.Roles.Seeds.seed_defaults()
      assert Repo.aggregate(RoleResponsibility, :count, :id) == after_first
    end
  end

  # ── the scope fence ───────────────────────────────────────────────────────

  describe "scope fence — the design step cannot do the architect's job" do
    test "the system slot names the prohibition; the user slot carries none of it" do
      project = project!()

      task =
        task!(project.id, %{
          title: "Redesign the task detail panel header",
          description: "The header crowds the title against the status pill on a phone."
        })

      context = DesignTaskDirection.gather_context(%{task_id: task.id})
      assert {:ok, %{system: system, user: user}} = DesignTaskDirection.build_prompt(context)

      # The fence is stated, verbatim, as a prohibition.
      assert system =~ DesignTaskDirection.scope_fence()
      assert system =~ "visual surface only"
      assert system =~ "Architect's remit"
      assert system =~ "If everything you have to say is architectural, say nothing."

      # And it names what it prohibits — a prohibition that cannot say what
      # it prohibits is not one.
      for term <- ["module boundaries", "data model", "data flow", "schema design"] do
        assert system =~ term,
               "the scope fence must NAME #{inspect(term)} as prohibited, not gesture at it"
      end

      # The deliverable the designer is actually asked to produce.
      assert user =~ "brand"
      assert user =~ "Palette"
      assert user =~ "Self-critique"

      # The absence assertion this whole test exists for.
      for term <- @architectural_vocabulary do
        refute String.contains?(String.downcase(user), term),
               """
               The design-direction USER prompt mentions #{inspect(term)}.

               That is the Architect's remit and a separate step in this same
               lifecycle (`architecture.review_plan`). A design step that asks for
               architectural output is the architect built twice, at the wrong
               point in the lifecycle and by the wrong role.
               """
      end
    end

    # PAIRED POSITIVE CONTROL. Without this, the refute loop above would pass
    # against an empty string, a failed template render, or a probe set made
    # of words no prompt in this codebase ever uses.
    test "the same probe set fires on the architect's prompt" do
      arch_context = ArchitectureReviewPlan.gather_context(%{})
      assert {:ok, %{user: arch_user}} = ArchitectureReviewPlan.build_prompt(arch_context)

      assert arch_user != ""

      hits =
        Enum.filter(@architectural_vocabulary, fn term ->
          String.contains?(String.downcase(arch_user), term)
        end)

      assert hits != [],
             """
             The architectural probe set matched NOTHING in the architect's own
             prompt, so the absence assertion in the sibling test proves nothing:
             a probe set that cannot fire cannot detect a violation.

             Probe set: #{inspect(@architectural_vocabulary)}
             """
    end
  end

  # ── gather_context/2 ──────────────────────────────────────────────────────

  describe "gather_context/2" do
    test "a project with neither brand page resolves advisory and does not raise" do
      project = project!()
      task = task!(project.id)

      assert {:ok, context} =
               DesignTaskDirection.gather_context(responsibility(), %{
                 task_id: task.id
               })

      assert context.brand_context.enforcement == :advisory
      assert context.brand_context.mode == :unresolved
      assert context.task_payload.missing? == false
      assert context.task_payload.task_id == task.id
      assert context.task_payload.project_id == project.id
      assert context.attached_canvases.missing? == false
      assert context.attached_canvases.total == 0
    end

    # Degrades rather than refusing — the deliberate opposite of
    # `architecture.review_plan`'s `:plan_payload`. See the handler moduledoc.
    test "an unresolvable task degrades every slot instead of refusing" do
      assert {:ok, context} =
               DesignTaskDirection.gather_context(responsibility(), %{
                 task_id: Ecto.UUID.generate()
               })

      assert context.task_payload.missing?
      assert context.brand_context.missing?
      assert context.attached_canvases.missing?
      assert context.brand_context.enforcement == :advisory

      # And the prompt still renders — a degraded slot must arrive as an
      # instruction, not as silence.
      assert {:ok, %{user: user}} = DesignTaskDirection.build_prompt(context)
      assert user =~ "no task resolved"
    end

    test "an already-attached canvas is surfaced so direction is not re-issued" do
      project = project!()
      task = task!(project.id)
      space = execution_space!(task)

      {:ok, participant} =
        Platform.Orchestration.ExecutionSpace.ensure_system_participant(space.id)

      {:ok, canvas} =
        Chat.create_canvas(%{
          space_id: space.id,
          created_by: participant.id,
          title: "Existing direction"
        })

      {:ok, _} =
        Platform.Tasks.CanvasAttachments.attach_canvas(task.id, canvas.id,
          note: "prior art",
          attached_by: %{kind: "agent", id: Ecto.UUID.generate()}
        )

      context = DesignTaskDirection.gather_context(%{task_id: task.id})

      assert context.attached_canvases.total == 1
      assert [%{canvas_id: id, title: "Existing direction"}] = context.attached_canvases.canvases
      assert id == canvas.id

      assert {:ok, %{user: user}} = DesignTaskDirection.build_prompt(context)
      assert user =~ "Existing direction"
      assert user =~ "Do NOT re-issue direction"
    end
  end

  # ── handle_output/3 ───────────────────────────────────────────────────────

  describe "handle_output/3" do
    test "a valid direction creates exactly one canvas and exactly one attachment" do
      project = project!()
      task = task!(project.id)
      space = execution_space!(task)
      agent_id = Ecto.UUID.generate()

      before = canvas_count()

      assert :ok =
               DesignTaskDirection.handle_output(
                 responsibility(),
                 %{"direction" => "## Direction\n\nOne signature element: the status pill."},
                 %{task_id: task.id, agent_id: agent_id}
               )

      assert canvas_count() == before + 1
      assert attachment_count(task.id) == 1

      [attachment] = Repo.all(from(a in CanvasAttachment, where: a.task_id == ^task.id))
      assert attachment.note == DesignTaskDirection.attachment_note()
      assert attachment.attached_by_kind == "agent"
      assert attachment.attached_by_id == agent_id

      canvas = Repo.get!(Canvas, attachment.canvas_id)
      assert canvas.space_id == space.id
      assert canvas.metadata["source"] == "design.task_direction"

      assert %{"root" => %{"children" => [%{"props" => %{"content" => content}}]}} =
               canvas.document

      assert content =~ "One signature element"
    end

    # The absence half of the pair above, in the same module so neither can
    # drift away from the other.
    test "no execution space returns :ok and creates zero canvases" do
      project = project!()
      task = task!(project.id)

      before = canvas_count()

      assert :ok =
               DesignTaskDirection.handle_output(
                 responsibility(),
                 %{"direction" => "## Direction"},
                 %{task_id: task.id, agent_id: Ecto.UUID.generate()}
               )

      assert canvas_count() == before
      assert attachment_count(task.id) == 0
    end

    test "an empty direction creates nothing even with a resolvable space" do
      project = project!()
      task = task!(project.id)
      _space = execution_space!(task)

      before = canvas_count()

      assert :ok =
               DesignTaskDirection.handle_output(
                 responsibility(),
                 %{"direction" => "   \n  "},
                 %{task_id: task.id, agent_id: Ecto.UUID.generate()}
               )

      assert canvas_count() == before
      assert attachment_count(task.id) == 0
    end

    test "a missing task_id returns :ok and creates nothing" do
      before = canvas_count()

      assert :ok =
               DesignTaskDirection.handle_output(
                 responsibility(),
                 %{"direction" => "## Direction"},
                 %{}
               )

      assert canvas_count() == before
    end

    # Attribution is resolved BEFORE the canvas is created precisely so this
    # case cannot leave an orphan canvas in the space.
    test "no attributable agent leaves zero canvases rather than an unattachable one" do
      project = project!()
      task = task!(project.id)
      _space = execution_space!(task)

      before = canvas_count()

      assert :ok =
               DesignTaskDirection.handle_output(
                 responsibility(),
                 %{"direction" => "## Direction"},
                 %{task_id: task.id}
               )

      assert canvas_count() == before
      assert attachment_count(task.id) == 0
    end
  end

  # ── the prompt template row ───────────────────────────────────────────────

  describe "the design.task_direction.v1 template row" do
    # The five bullets are asserted as EXACT substrings, including the en
    # dashes in "4–6" and "2–3", because they were lifted verbatim from the
    # `dispatch.planning` body. A paraphrase here would mean the output shape
    # changed silently between the planner asking for it and the designer
    # producing it.
    @deliverable_bullets [
      "- Opening line pins the subject: what this surface is, who uses it, and the one job it does.",
      "- Palette: 4–6 named color values (from brand tokens if they exist; provisional if exploring).",
      "- Type: 2–3 roles (display used with restraint, body, optional utility).",
      "- Layout: one sentence of intent + a rough wireframe; name ONE signature element — spend boldness in one place.",
      "- Self-critique before handoff: revise anything that reads like the generic default for this kind of page, and say what changed."
    ]

    test "the migrated row exists and carries all five bullets plus the delivery instruction" do
      template = PromptTemplates.get_template_by_slug("design.task_direction.v1")

      assert template,
             "design.task_direction.v1 has no row — `mix ecto.migrate` did not run " <>
               "20260726051346_seed_design_task_direction.exs against this test DB"

      for bullet <- @deliverable_bullets do
        assert String.contains?(template.content, bullet),
               "the template row is missing the deliverable bullet:\n#{bullet}"
      end

      assert template.content =~ "task_attach_canvas"
      assert template.content =~ "completion signal"

      assert Enum.sort(template.variables) ==
               ["attached_canvases", "brand_context", "task_summary"]
    end

    # The DB row and the hardcoded fallback must be the same text, or a
    # deployment whose row went missing gets a quietly different prompt.
    test "the hardcoded fallback body matches the seeded row" do
      template = PromptTemplates.get_template_by_slug("design.task_direction.v1")
      fallback = PromptTemplates.default_content_for_slug("design.task_direction.v1")

      assert is_binary(fallback)
      assert fallback == template.content
    end

    # The five bullets are the SAME five the planner prompt has been asking
    # for since task 019f4f1d. If either copy is reworded without the other,
    # this fires.
    test "the bullets are byte-identical to the ones dispatch.planning asks for" do
      planning = PromptTemplates.default_content_for_slug("dispatch.planning")

      for bullet <- @deliverable_bullets do
        trimmed = String.trim_leading(bullet, "- ")

        assert String.contains?(planning, trimmed),
               """
               The deliverable bullet below no longer appears in dispatch.planning.

               #{bullet}

               ADR-0046 moves WHO produces design direction and WHEN, not WHAT it
               looks like. If the two copies have diverged, one of them changed the
               output shape without saying so.
               """
      end
    end
  end
end
