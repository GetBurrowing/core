#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/apps/platform"
QUERY="${1:-}"
DATABASE_URL="${DATABASE_URL:-postgres://postgres:postgres@127.0.0.1/platform_dev}"
TMP_ERR="$(mktemp)"
trap 'rm -f "$TMP_ERR"' EXIT

if [[ -z "$QUERY" ]]; then
  echo "usage: $0 <task-id-or-title-fragment>" >&2
  exit 1
fi

(
  cd "$APP_DIR"
  QUERY="$QUERY" DATABASE_URL="$DATABASE_URL" mix run -e '
    require Logger
    Logger.configure(level: :error)

    alias Platform.{Repo, Tasks}
    alias Platform.Tasks.Task
    import Ecto.Query

    query = System.fetch_env!("QUERY")

    task =
      Task
      |> where([t], fragment("?::text", t.id) == ^query or ilike(t.title, ^"%#{query}%"))
      |> order_by([t], desc: t.inserted_at)
      |> limit(1)
      |> Repo.one()

    if is_nil(task) do
      IO.puts(:stderr, "No task matched: #{query}")
      System.halt(2)
    end

    plans = Tasks.list_plans(task.id)
    plan = List.last(plans)
    stages = if plan, do: Tasks.list_stages(plan.id), else: []

    IO.puts("TASK #{task.id}")
    IO.puts("  title: #{task.title}")
    IO.puts("  status: #{task.status}")
    IO.puts("  assignee: #{task.assignee_type || "—"}/#{task.assignee_id || "—"}")

    if plan do
      approved_at = if plan.approved_at, do: DateTime.to_iso8601(plan.approved_at), else: "—"
      IO.puts("PLAN #{plan.id}")
      IO.puts("  version: #{plan.version}")
      IO.puts("  status: #{plan.status}")
      IO.puts("  approved_at: #{approved_at}")
      IO.puts("STAGES")

      Enum.each(stages, fn stage ->
        validations =
          stage.id
          |> Tasks.list_validations()
          |> Enum.map_join(", ", fn v -> "#{v.kind}=#{v.status}" end)

        suffix = if validations == "", do: "", else: " {#{validations}}"
        IO.puts("  #{stage.position}. [#{stage.status}] #{stage.name}#{suffix}")
      end)
    else
      IO.puts("PLAN —")
      IO.puts("  version: —")
      IO.puts("  status: —")
      IO.puts("  approved_at: —")
      IO.puts("STAGES")
      IO.puts("  (none)")
    end
  '
) 2>"$TMP_ERR" || {
  cat "$TMP_ERR" >&2
  exit 1
}
