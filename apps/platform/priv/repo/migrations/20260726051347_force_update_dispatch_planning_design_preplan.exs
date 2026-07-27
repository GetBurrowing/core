defmodule Platform.Repo.Migrations.ForceUpdateDispatchPlanningDesignPreplan do
  use Ecto.Migration

  @moduledoc """
  Retarget the `dispatch.planning` "Design involvement (UI/UX tasks)"
  section at the pre-plan design step (task `019f9b29-5ecd` stage 6,
  ADR-0046 stack member 7).

  Two items in that section are reversed by ADR-0046 decision 1:

    * item 1 told the planner to resolve the brand cascade itself and to
      escalate once per project. `Platform.Design.Brand` now does that
      before the planning dispatch is sent.
    * item 2 told the planner to author an advisory "Design direction
      (Saru)" stage carrying `responsibility: "designer"`. Design now
      runs BEFORE planning as a responsibility dispatch, so a planner
      still emitting that stage gives every UI task design twice.

  The detection paragraph and items 3 (semantic token slots) and 4 (the
  `manual_approval` screenshot rule) are unchanged — the lifecycle move
  does not touch them and rewriting them would put unrelated churn in a
  body a reviewer has to diff against the live row.

  `PromptTemplates.seed_defaults/0` is INSERT-only and
  `20260713000010_sync_dispatch_planning_responsibility_hint.exs`
  already claimed this row on every migrated environment, so editing
  `do_default_templates/0` alone would change only the fallback body and
  leave deployed planners reading the old instruction. Same force-update
  shape as that migration, for the same reason. `down/0` is a no-op:
  reverting to the superseded body would re-enable double design.

  Boundary with the sibling stack members:

    * Member 9 owns removing `Stage.responsibility` and its resolution
      path in `task_router.ex`. This migration removes only the
      INSTRUCTION TO AUTHOR the field — no schema, no column, no
      resolver. Landing it first is what makes member 9's deletion safe:
      no newly-submitted plan carries `responsibility`, so member 9 only
      has to handle plans already in flight.
    * Member 5 owns the architecture gate. Nothing here reads or waits
      on an architecture outcome; design's trigger is the UI heuristic
      plus the `designer` role, and architecture runs after plan
      submission, so the two share no ordering edge.
    * Member 8 owns card rendering. Nothing here touches `.heex`,
      `assets/`, or a LiveView.

  Skips the slug when no DB row exists (fresh boots pick it up via
  `seed_defaults/0`).
  """

  @slug "dispatch.planning"

  def up do
    alias Platform.Orchestration.PromptTemplates

    case PromptTemplates.get_template_by_slug(@slug) do
      nil ->
        :skip

      template ->
        case PromptTemplates.default_content_for_slug(@slug) do
          nil ->
            :skip

          content ->
            {:ok, _} = PromptTemplates.update_template(template, %{content: content})
        end
    end

    :ok
  end

  def down do
    :ok
  end
end
