defmodule Platform.ParallelUI.Columns do
  @moduledoc """
  Reads and checks the Postgres labels on `:column` entries of
  `Platform.ParallelUI` (task 01a156cb).

  A column kept alive for the old UI carries a column comment of the form
  `parallel-ui: <id>`, written by the migration that introduced the shim (see
  the `Platform.ParallelUI` moduledoc for the snippet). The label makes the
  shim visible to anyone reading the schema, without grep.

  `labelled/1` reads every such comment on a column of a table in the
  connection's search path (`current_schemas(false)`). Table-level comments
  and comments that do not start with `parallel-ui:` are not returned.

  `check/2` is pure: it compares entries against labels both ways, so it can
  be driven with synthetic input. `test/platform/parallel_ui_columns_test.exs`
  runs it against the live ledger and database. `mix parallel_ui.report` does
  NOT read labels: it is DB-free on purpose.
  """

  alias Platform.ParallelUI

  @prefix "parallel-ui:"

  @labelled_sql """
  SELECT c.relname, a.attname, d.description
  FROM pg_description d
  JOIN pg_class c ON c.oid = d.objoid
  JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = d.objsubid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE d.objsubid > 0
    AND d.description LIKE 'parallel-ui:%'
    AND n.nspname = ANY (current_schemas(false))
  ORDER BY c.relname, a.attname, d.description
  """

  @type label :: %{table: String.t(), column: String.t(), id: String.t()}
  @type mismatch :: %{
          id: String.t(),
          expected: %{table: String.t(), column: String.t()},
          actual: %{table: String.t(), column: String.t()}
        }
  @type failure :: %{
          unlabelled: [String.t()],
          unregistered: [label()],
          mismatched: [mismatch()]
        }

  @doc """
  Every `parallel-ui:` column comment visible in the connection's search
  path, sorted by table, column, id. The id is the comment text after the
  `parallel-ui:` prefix, trimmed.
  """
  @spec labelled(Ecto.Repo.t()) :: [label()]
  def labelled(repo \\ Platform.Repo) do
    %{rows: rows} = repo.query!(@labelled_sql)

    Enum.map(rows, fn [table, column, description] ->
      %{table: table, column: column, id: parse_id(description)}
    end)
  end

  defp parse_id(description) do
    description
    |> String.replace_prefix(@prefix, "")
    |> String.trim()
  end

  @doc """
  Checks both directions between the `:column` entries in `entries` and
  `labelled`.

    * `:unlabelled` — a `:column` entry whose id appears on no column at all
      (sorted ids).
    * `:mismatched` — a label naming a registered `:column` entry, but on a
      different `{table, column}` than the entry declares.
    * `:unregistered` — a label whose id is not a registered `:column` entry
      (including the id of an entry of another kind).

  Entries of other kinds are ignored. Pure.
  """
  @spec check([ParallelUI.entry()], [label()]) :: :ok | {:error, failure()}
  def check(entries, labelled) do
    column_entries =
      entries
      |> Enum.filter(&(&1.kind == :column))
      |> Map.new(&{&1.id, %{table: &1.table, column: &1.column}})

    labelled_ids = MapSet.new(labelled, & &1.id)

    unlabelled =
      column_entries
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(labelled_ids, &1))
      |> Enum.sort()

    {registered, unregistered} =
      Enum.split_with(labelled, &Map.has_key?(column_entries, &1.id))

    mismatched =
      registered
      |> Enum.reject(&(Map.fetch!(column_entries, &1.id) == Map.take(&1, [:table, :column])))
      |> Enum.map(fn label ->
        %{
          id: label.id,
          expected: Map.fetch!(column_entries, label.id),
          actual: Map.take(label, [:table, :column])
        }
      end)
      |> Enum.sort_by(&{&1.id, &1.actual.table, &1.actual.column})

    unregistered = Enum.sort_by(unregistered, &{&1.table, &1.column, &1.id})

    case {unlabelled, unregistered, mismatched} do
      {[], [], []} ->
        :ok

      _ ->
        {:error, %{unlabelled: unlabelled, unregistered: unregistered, mismatched: mismatched}}
    end
  end
end
