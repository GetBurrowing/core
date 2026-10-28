# Run via bin/platform rpc after copying this file and the validated triage.ex
# source into the release container. Does not replace a running application
# module or require a pre-deployment hot load of the task's entire branch.
source = File.read!("/tmp/meeting-live-cleanup-triage.ex")
{:defmodule, _, [_original, [do: {:__block__, _, forms}]]} = Code.string_to_quoted!(source)

functions = [
  :junk_live_tasks,
  :live_cleanup_query,
  :junk_live_batch,
  :refresh_meeting_briefing,
  :broadcast_batch_deleted
]

selected =
  Enum.filter(forms, fn
    {kind, _, [{:when, _, [{name, _, _} | _]}, _]} when kind in [:def, :defp] -> name in functions
    {kind, _, [{name, _, _}, _]} when kind in [:def, :defp] -> name in functions
    _ -> false
  end)

quoted =
  quote do
    defmodule Platform.Meetings.LiveTaskCleanupOneOff do
      import Ecto.Query
      alias Platform.{Audit, Repo}
      alias Platform.Meetings.MeetingCandidate
      alias Platform.Tasks.Task
      require Logger
      unquote_splicing(selected)
    end
  end

Code.compile_quoted(quoted)

apply? = System.get_env("MEETING_CLEANUP_APPLY") == "true"

opts = [
  dry_run: not apply?,
  limit: 250,
  actor_id: "01a13fd8-a480-7000-93a3-7a5c68a769af",
  operation_id: "01a17f00-live-task-cleanup-20261028"
]

case Platform.Meetings.LiveTaskCleanupOneOff.junk_live_tasks(opts) do
  {:ok, report} -> IO.puts("MEETING_LIVE_CLEANUP " <> Jason.encode!(report))
  {:error, reason} -> raise "Cleanup refused: #{inspect(reason)}"
end
