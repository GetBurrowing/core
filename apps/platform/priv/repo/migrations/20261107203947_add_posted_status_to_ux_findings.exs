defmodule Platform.Repo.Migrations.AddPostedStatusToUxFindings do
  @moduledoc """
  Allow `posted` on `ux_findings.status` (task `01a1af00-86ac-7000-94ba-a121d5cb8116`
  stage 4): an `fyi` finding the weekly digest (`Platform.Ux.Digest`) put in
  chat. It is no longer open, so the next digest does not repeat it and the
  next week's friction can file a fresh one; it was never answered, so the
  keep-versus-dismiss metric does not read it.
  """

  use Ecto.Migration

  def up do
    drop(constraint(:ux_findings, :ux_findings_status_check))

    create(
      constraint(:ux_findings, :ux_findings_status_check,
        check: "status IN ('open', 'answered', 'dismissed', 'posted')"
      )
    )
  end

  def down do
    execute("UPDATE ux_findings SET status = 'dismissed' WHERE status = 'posted'")
    drop(constraint(:ux_findings, :ux_findings_status_check))

    create(
      constraint(:ux_findings, :ux_findings_status_check,
        check: "status IN ('open', 'answered', 'dismissed')"
      )
    )
  end
end
