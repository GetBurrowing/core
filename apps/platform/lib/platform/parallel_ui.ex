defmodule Platform.ParallelUI do
  @moduledoc """
  The ledger of legacy surfaces kept alive only so the old UI keeps working
  while the redesigned one runs beside it (task 01a156cb).

  ## The rule

  Any rung that keeps a legacy **event, field, column, dual write or route**
  alive for the old UI adds its entry to `@entries` below **and** its markers
  in the same commit. The final cutover task is planned from this ledger
  (`mix parallel_ui.report`), one stage per kind, each step taken verbatim from
  the entry's `:cutover` string. A shim that is not written down here is a
  shim nobody will remember to delete.

  Main ships with zero entries. `test/platform/parallel_ui_test.exs` enforces
  both directions against the live tree:

    * every entry has at least one marker somewhere under the scanned roots
      (otherwise it is `unmarked`), and
    * every marker names a registered entry (otherwise it is `unregistered`,
      reported with its `path:line`).

  ## Entry schema

  Every entry is a map with exactly `required_keys/0`:

    * `:id` — matches `id_regex/0`, unique across the ledger.
    * `:kind` — one of `kinds/0`.
    * `:legacy` — what is being kept alive, in prose.
    * `:replacement` — what the new UI uses instead.
    * `:introduced_by` — the UUID of the task that added the shim.
    * `:cutover` — the exact step that removes it. Copied verbatim into the
      cutover task's stage, so write it as an instruction.

  A `:column` entry additionally carries `column_keys/0` (`:table` and
  `:column`), naming the column the `COMMENT ON COLUMN` label sits on. No other
  kind carries them.

  ## Marker syntax

  A marker is a comment leader, optional whitespace, `parallel-ui:`, whitespace,
  then the entry id. Only comments count: the same text inside a string literal
  is not a marker. Below, `<id>` is a placeholder the id grammar cannot match,
  so these examples are not markers themselves.

    * Elixir (`.ex`, `.exs`): `# parallel-ui: <id>`
    * HEEx (`.heex`): `<%!-- parallel-ui: <id> --%>`
    * JavaScript / TypeScript (`.js`, `.ts`): `// parallel-ui: <id>`

  Scanned roots: `lib`, `priv/repo/migrations` and `assets/js` under
  `apps/platform` (see `Platform.ParallelUI.Markers`). `test/` is not scanned.

  ## Columns

  A `:column` entry is also labelled in Postgres, so the label is queryable
  without grep. The migration that introduces the shim writes literal SQL (a
  migration must not change meaning when lib changes, so it does not call into
  this module) and carries a marker:

      # parallel-ui: <id>
      execute(
        "COMMENT ON COLUMN <table>.<column> IS 'parallel-ui: <id>'",
        "COMMENT ON COLUMN <table>.<column> IS NULL"
      )

  Write the table and column names into the SQL by hand. Do not interpolate
  anything from lib: a migration that calls into this module would change
  meaning whenever the ledger changes. Prior art for a reversible
  `COMMENT ON`: `20260501203100_create_invocation_visibility_grants.exs`.

  `Platform.ParallelUI.Columns.labelled/1` reads the labels back, and
  `test/platform/parallel_ui_columns_test.exs` checks both directions: every
  `:column` entry has a `parallel-ui: <id>` comment on exactly its
  `{table, column}`, and every such comment names a registered `:column`
  entry on that column. `mix parallel_ui.report` does not read the database,
  so column labels are enforced by that test, not by the report.
  """

  @kinds [:event, :field, :column, :dual_write, :route]

  @required_keys [:id, :kind, :legacy, :replacement, :introduced_by, :cutover]

  @column_keys [:table, :column]

  @id_regex ~r/\A[a-z0-9][a-z0-9_.-]*\z/

  @entries []

  @type kind :: :event | :field | :column | :dual_write | :route
  @type entry :: %{required(atom()) => term()}
  @type marker :: %{id: String.t(), path: String.t(), line: pos_integer()}
  @type failure :: %{unmarked: [String.t()], unregistered: [marker()]}

  @doc "Every ledger entry, in declaration order."
  @spec entries() :: [entry()]
  def entries, do: @entries

  @doc "The recognised kinds, in the order the report groups them."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "The keys every entry must carry."
  @spec required_keys() :: [atom()]
  def required_keys, do: @required_keys

  @doc "The extra keys a `:column` entry carries, and no other kind does."
  @spec column_keys() :: [atom()]
  def column_keys, do: @column_keys

  @doc "The id grammar: lowercase alphanumerics, `_`, `.` and `-`."
  @spec id_regex() :: Regex.t()
  def id_regex, do: @id_regex

  @doc """
  Checks both directions between `entries` and `markers`.

  Pure: the caller supplies both sides, so seeded entries can be checked
  without editing the live ledger. Returns `:ok`, or an error naming every
  entry with no marker (`:unmarked`, sorted ids) and every marker with no
  entry (`:unregistered`, sorted by path then line).
  """
  @spec check([entry()], [marker()]) :: :ok | {:error, failure()}
  def check(entries, markers) do
    entry_ids = MapSet.new(entries, & &1.id)
    marker_ids = MapSet.new(markers, & &1.id)

    unmarked =
      entries
      |> Enum.map(& &1.id)
      |> Enum.reject(&MapSet.member?(marker_ids, &1))
      |> Enum.uniq()
      |> Enum.sort()

    unregistered =
      markers
      |> Enum.reject(&MapSet.member?(entry_ids, &1.id))
      |> Enum.sort_by(&{&1.path, &1.line})

    case {unmarked, unregistered} do
      {[], []} -> :ok
      _ -> {:error, %{unmarked: unmarked, unregistered: unregistered}}
    end
  end
end
