defmodule Platform.Repo.Migrations.AddPromptRefsToMeetingSynthesisFindings do
  @moduledoc """
  Task `01a16974-e3db-7000-97e9-8ec9611189bc`, stage 6: `prompt_refs`, the
  `"kind:id"` refs of every source that was in the provider prompt which
  produced a finding's body (the source itself plus its required refs).

  The body is model text and can describe any source in its prompt, cited
  or not, so a viewer must be able to read every prompt ref, not only the
  citations. `MeetingBriefings.finding_visible?/2` re-checks them live.

  No `Platform.Audit.record/1`, no PubSub: migrations run before the
  supervision tree is up.
  """

  use Ecto.Migration

  def change do
    alter table(:meeting_synthesis_findings) do
      add(:prompt_refs, {:array, :string}, null: false, default: [])
    end
  end
end
