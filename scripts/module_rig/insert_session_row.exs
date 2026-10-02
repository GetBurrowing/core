# Module rig (ADR 0055 stage 4, task 01a0ee08), prod-like case: one ended
# game_stream_sessions row, written by the PRE-module build (origin/main at
# the merge-base) so the later builds can be shown to keep it. Plain SQL, so
# the script names no module and works whichever build runs it.
alias Platform.Repo
alias Platform.Tasks

u = System.unique_integer([:positive])

{:ok, project} =
  Tasks.create_project(%{name: "Rig #{u}", repo_url: "https://github.com/example/rig-01a0ee08"})

{:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Rig task #{u}"})

id = Ecto.UUID.generate()
now = DateTime.utc_now()

Repo.query!(
  """
  INSERT INTO game_stream_sessions
    (id, task_id, review_sha, branch, host_runtime_id, encoder, ended_state,
     started_at, ended_at, inserted_at, updated_at)
  VALUES ($1, $2, $3, $4, $5, '{}'::jsonb, 'ended', $6, $6, $6, $6)
  """,
  [
    Ecto.UUID.dump!(id),
    Ecto.UUID.dump!(task.id),
    String.duplicate("0", 40),
    "task/rig",
    "rig-host",
    now
  ]
)

IO.puts("RIG session_row_id=#{id}")
IO.puts("RIG task_id=#{task.id}")
