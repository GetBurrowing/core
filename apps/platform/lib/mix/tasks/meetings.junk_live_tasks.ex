defmodule Mix.Tasks.Meetings.JunkLiveTasks do
  @moduledoc """
  Audited, bounded cleanup of historical live meeting task filings.

      mix meetings.junk_live_tasks --dry-run --limit 250
      mix meetings.junk_live_tasks --apply --actor-id UUID --operation-id OP --limit 250

  Defaults to dry-run. Invoke repeatedly with the same operation ID until
  remaining is zero; each changed batch has its own audit event. Reports IDs
  and counts only, never task content. Conflicting provenance aborts the batch.
  """
  use Mix.Task

  @shortdoc "Preview or audit-soft-delete proven live-minted meeting tasks"
  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          dry_run: :boolean,
          apply: :boolean,
          actor_id: :string,
          operation_id: :string,
          limit: :integer
        ]
      )

    if rest != [] or invalid != [], do: Mix.raise("Invalid cleanup arguments")
    if opts[:apply] and opts[:dry_run], do: Mix.raise("Choose apply or dry-run")
    Mix.Task.run("app.start")

    options =
      Keyword.take(opts, [:actor_id, :operation_id, :limit])
      |> Keyword.put(:dry_run, not Keyword.get(opts, :apply, false))

    case Platform.Meetings.Triage.junk_live_tasks(options) do
      {:ok, report} -> Mix.shell().info(Jason.encode!(report))
      {:error, reason} -> Mix.raise("Cleanup refused: #{inspect(reason)}")
    end
  end
end
