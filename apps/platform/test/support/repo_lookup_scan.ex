defmodule Platform.Support.RepoLookupScan do
  @moduledoc """
  Static scan of every `Repo.get`-family lookup in `apps/platform/lib`.

  ## Why this exists

  `Repo.get(Schema, id)` casts `id` through the schema's `@primary_key`
  type before it ever reaches Postgres. Every schema in this app except
  `Platform.Roles.Role` (string PK) and `Platform.Audit.Event` (integer
  PK) keys on a UUID, so a non-UUID id does not return `nil` — it
  **raises** `Ecto.Query.CastError` from inside `Repo`. That is the
  defect PR #613 (`ecc8acc7`) fixed at one site, task `019fa11d-1f6a`
  fixed at one site, and this task's stages 1-2 fixed at one more. Three
  instances of one class, three single-site fixes.

  A markdown audit would rot the day it landed. This module is the
  executable half: `call_sites/0` re-derives the survey from source on
  every test run, and `Platform.RepoLookupBoundaryTest` compares it to a
  checked-in classification. Add an unclassified boundary lookup and the
  suite tells you at test time.

  ## Why AST, not grep

  `git grep "Repo.get("` is wrong in both directions and the plan for
  this task named all three failure modes:

    * It **misses** `Platform.Repo.get(` (6 real sites on this tree —
      `federation/task_attrs.ex`, `meetings/intent_classifier.ex`,
      `memory/telemetry_handler.ex`, `platform_web/channels/runtime_channel.ex`
      and two in `platform_web/live/chat_live.ex`). Matching on
      `List.last(alias_parts) == :Repo` catches both spellings.
    * It **over-counts** `@doc`/comment prose. 8 lines on this tree
      mention `Repo.get(` inside documentation, including two written by
      this very task. The AST never sees a string literal as a call.
    * It **misses** `Repo.get_by(Agent, id: id, kind: ...)`, where the
      exposed id is a keyword value rather than the second positional
      argument. `get_by_id_keys/0` surfaces those.

  Reconciliation on this tree: 249 grep lines minus 8 documentation
  mentions equals the 241 real `get`/`get!`/`get_by`/`get_by!` calls
  this scanner reports. It does not under-match the plan's baseline.

  ## The fourth family: bare `Ecto.UUID.cast/1` guards

  A site that guards with a bare `Ecto.UUID.cast/1` is *also* in scope
  even when it never calls `Repo.get` itself, because that guard does
  not work. `Ecto.UUID.cast/1` hex-encodes a raw 16-byte binary and
  returns `{:ok, _}`, while `Ecto.UUID.dump/1` rejects the same value —
  so a 16-character slug clears the guard and `Repo` raises anyway. Two
  such guards sat on live request paths before stage 4 of task
  `019fa129` (`plugs/external_user_scope.ex` and `live/chat_live.ex`),
  each gating `Chat.get_space/1` on a URL path segment.
  `Platform.UUID.valid?/1` adds the `byte_size(value) == 36` check that
  closes the gap. The scan records `:ecto_uuid_cast` as a call kind so
  those sites cannot be lost again.

  ## The fifth family, and why it makes this a ratchet

  Stage 4 also records `Platform.UUID.cast/1` and `Platform.UUID.valid?/1`
  as `:platform_uuid_guard`. Tracking the *fix* — not just the defect —
  is what stops the fix being quietly undone:

    * Re-simplify a guard back to a bare `Ecto.UUID.cast/1` and an
      **unclassified `:ecto_uuid_cast` key appears** → "every call site
      is classified" fails, naming the file.
    * That same edit **drops a `:platform_uuid_guard` count** → "recorded
      call counts match the source tree" fails, naming the file again.

  Two independent detectors per guarded site, derived from source rather
  than from anyone remembering to write a test. This matters because the
  behavioural tests for these sites are easy to write *vacuously*: a
  suite built from `"higgins"` plus a valid UUID is fully green against
  the bug, since `Ecto.UUID.cast/1` rejects `"higgins"` on its own. Only
  a raw 16-byte binary or a 16-character slug discriminates.

  ## Keying

  Sites are keyed `{relative_path, call_kind, schema_alias}` with a
  count per key — deliberately **not** by line number, so the inventory
  survives reordering and small refactors. A key's count changing is
  still a signal; a function moving 40 lines down is not.

  `schema_alias` is the literal first argument when it is a module
  alias. When the first argument is a composed query the scanner falls
  back to `"~q:<FirstAliasInside>"` (e.g. `Platform.Files.get_file/2`
  pipes `File` through a soft-delete filter first), and to `"~expr"` /
  `"~<var>"` when no alias is reachable.

  ## Known limits, stated rather than hidden

    * `alias Platform.Repo, as: DB` would evade the `:Repo` last-segment
      match. No such alias exists on this tree.
    * `Repo.one/1` is **counted per file** (`query_lookup_counts/0`) but
      not classified per key. Its ids live inside `where:` clauses built
      by other functions, so attributing one statically needs dataflow
      this scanner does not do.
    * The wider query-DSL exposure is measured by `query_id_pins/0`:
      283 pinned comparisons against an `id` / `*_id` field across 61
      files on this tree. `where: m.id == ^id` raises the *same*
      `Ecto.Query.CastError` as `Repo.get/2`, and this family is nearly
      three times the size of the `Repo.one` count the plan baselined —
      because `Repo.all`, `Repo.exists?`, `Repo.aggregate`,
      `Repo.update_all` and `Repo.delete_all` carry it too. It is
      reported, not gated: classifying 283 sites is its own task.
  """

  @lookup_funs [:get, :get!, :get_by, :get_by!]
  @query_fun :one
  @guard_funs [:cast, :valid?]

  @typedoc "`{relative_path, call_kind, schema_alias}`"
  @type key :: {String.t(), atom(), String.t()}

  @doc "Absolute path of the `lib` tree this scanner walks."
  @spec lib_root() :: String.t()
  def lib_root, do: Path.expand("../../lib", __DIR__)

  @doc "Every `.ex` file under `lib`, sorted for deterministic output."
  @spec source_files() :: [String.t()]
  def source_files do
    lib_root()
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.sort()
  end

  @doc """
  The classified-and-gated families: `Repo.get/get!/get_by/get_by!` plus
  bare `Ecto.UUID.cast/1` guards. Returns `%{key => count}`.
  """
  @spec call_sites() :: %{key() => pos_integer()}
  def call_sites do
    source_files()
    |> Enum.flat_map(&scan_file/1)
    |> Enum.filter(fn {_key, kind} -> kind != @query_fun end)
    |> Enum.map(fn {key, _kind} -> key end)
    |> Enum.frequencies()
  end

  @doc """
  `call_sites/0` over ANOTHER lib tree, keyed relative to `root`: a
  build-time module's own inventory runs the same scanner over its own lib
  (ADR 0055, task 01a0ee08 stage 3), since core's inventory lists core's
  lib only.
  """
  @spec call_sites_under(String.t()) :: %{key() => pos_integer()}
  def call_sites_under(root) do
    root
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&scan_source(File.read!(&1), Path.relative_to(&1, root)))
    |> Enum.reduce(%{}, &Map.merge(&2, &1, fn _key, a, b -> a + b end))
  end

  @doc """
  `Repo.one/1` calls per relative path. Counted, not classified — see
  the moduledoc's "Known limits".
  """
  @spec query_lookup_counts() :: %{String.t() => pos_integer()}
  def query_lookup_counts do
    source_files()
    |> Enum.flat_map(&scan_file/1)
    |> Enum.filter(fn {_key, kind} -> kind == @query_fun end)
    |> Enum.map(fn {{path, _, _}, _} -> path end)
    |> Enum.frequencies()
  end

  @doc """
  The keyword keys used at each `Repo.get_by/2` and `Repo.get_by!/2`
  site, as `%{key => [[atom()]]}` (one list per call).

  This is what makes the `get_by` blind spot visible: a site keyed
  `id:` / `*_id:` carries the same exposure as `Repo.get/2`, while one
  keyed `slug:` / `email:` / `auth_token_hash:` compares against a
  string column and cannot raise.
  """
  @spec get_by_id_keys() :: %{key() => [[atom()]]}
  def get_by_id_keys do
    source_files()
    |> Enum.flat_map(&scan_get_by_keys/1)
    |> Enum.group_by(fn {key, _keys} -> key end, fn {_key, keys} -> keys end)
  end

  @doc """
  Reported-not-gated: pinned comparisons against an `id` / `*_id` field
  inside a query expression (`where: x.id == ^value`). Returns
  `%{relative_path => count}`.
  """
  @spec query_id_pins() :: %{String.t() => pos_integer()}
  def query_id_pins do
    source_files()
    |> Enum.flat_map(fn path ->
      rel = relative(path)

      path
      |> parse!()
      |> prewalk_collect(fn
        {:==, _, [left, right]} ->
          cond do
            id_field?(left) and pinned?(right) -> [rel]
            id_field?(right) and pinned?(left) -> [rel]
            true -> []
          end

        _ ->
          []
      end)
    end)
    |> Enum.frequencies()
  end

  @doc """
  Lines under `lib` whose *text* names a `Repo.get`-family call but
  whose AST does not — i.e. documentation and comments. Kept so the
  grep-vs-scan reconciliation in the test is checkable rather than
  asserted.
  """
  @spec doc_mention_count() :: non_neg_integer()
  def doc_mention_count do
    pattern = ~r/(^|[^.\w])(Platform\.)?Repo\.(get|get!|get_by|get_by!)\(/

    Enum.reduce(source_files(), 0, fn path, acc ->
      ast_lines = path |> scan_file(:with_lines) |> MapSet.new()

      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.count(fn {line, index} ->
        Regex.match?(pattern, line) and not MapSet.member?(ast_lines, index)
      end)
      |> Kernel.+(acc)
    end)
  end

  @doc """
  Scan a source STRING rather than a file, keyed under `rel`.

  This exists so the scanner's own capability tests do not have to use a
  live defect as their fixture. Stage 3 asserted "the scanner still sees
  the bare cast in `external_user_scope.ex`" — a true statement that
  stage 4 then falsified by *fixing* the bug, which is the wrong reason
  for a scanner test to fail. Capability is proved against a synthetic
  snippet; the real tree is asserted to be CLEAN of those snippets.
  """
  @spec scan_source(String.t(), String.t()) :: %{key() => pos_integer()}
  def scan_source(source, rel) do
    source
    |> Code.string_to_quoted!()
    |> expand_pipes()
    |> prewalk_collect(fn node -> node_to_entries(node, rel) end)
    |> Enum.filter(fn {_key, kind} -> kind != @query_fun end)
    |> Enum.map(fn {key, _kind} -> key end)
    |> Enum.frequencies()
  end

  # ── Scanning ──────────────────────────────────────────────────────────

  defp scan_file(path) do
    rel = relative(path)

    path
    |> parse!()
    |> prewalk_collect(fn node -> node_to_entries(node, rel) end)
  end

  defp scan_file(path, :with_lines) do
    path
    |> parse!()
    |> prewalk_collect(fn
      {{:., _, [{:__aliases__, _, parts}, fun]}, meta, args}
      when is_list(args) ->
        if List.last(parts) == :Repo and fun in @lookup_funs, do: [meta[:line]], else: []

      _ ->
        []
    end)
  end

  defp node_to_entries({{:., _, [{:__aliases__, _, parts}, fun]}, _meta, args}, rel)
       when is_list(args) do
    last = List.last(parts)

    cond do
      last == :Repo and fun in @lookup_funs ->
        [{{rel, fun, schema_key(args)}, fun}]

      last == :Repo and fun == @query_fun ->
        [{{rel, @query_fun, schema_key(args)}, @query_fun}]

      parts == [:Ecto, :UUID] and fun == :cast ->
        [{{rel, :ecto_uuid_cast, "-"}, :ecto_uuid_cast}]

      parts == [:Platform, :UUID] and fun in @guard_funs ->
        [{{rel, :platform_uuid_guard, "-"}, :platform_uuid_guard}]

      true ->
        []
    end
  end

  defp node_to_entries(_node, _rel), do: []

  defp scan_get_by_keys(path) do
    rel = relative(path)

    path
    |> parse!()
    |> prewalk_collect(fn
      {{:., _, [{:__aliases__, _, parts}, fun]}, _meta, args}
      when is_list(args) ->
        if List.last(parts) == :Repo and fun in [:get_by, :get_by!] do
          [{{rel, fun, schema_key(args)}, keyword_keys(args)}]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp keyword_keys([_schema, kw | _]) when is_list(kw) do
    Enum.map(kw, fn
      {key, _value} when is_atom(key) -> key
      _ -> :__dynamic
    end)
  end

  defp keyword_keys(_), do: [:__dynamic]

  # ── AST helpers ───────────────────────────────────────────────────────

  defp parse!(path) do
    path
    |> File.read!()
    |> Code.string_to_quoted!()
    |> expand_pipes()
  end

  # `x |> Repo.get(id)` and `Repo.get(x, id)` must produce the same key,
  # so rewrite the pipe before collecting. Pipes are the dominant spelling
  # for the query-composing lookups (`Platform.Files.get_file/2`).
  defp expand_pipes(ast) do
    Macro.prewalk(ast, fn
      {:|>, _meta, [lhs, {call, meta, args}]} when is_list(args) -> {call, meta, [lhs | args]}
      other -> other
    end)
  end

  # Returns matches in AST visit order, which is what `first_alias/1`
  # depends on to pick the outermost schema alias of a composed query.
  defp prewalk_collect(ast, fun) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn node, acc ->
        {node, Enum.reverse(fun.(node)) ++ acc}
      end)

    Enum.reverse(acc)
  end

  defp schema_key([first | _]), do: alias_of(first)
  defp schema_key(_), do: "~none"

  defp alias_of({:__aliases__, _, parts}), do: Enum.map_join(parts, ".", &Atom.to_string/1)
  defp alias_of({:__MODULE__, _, _}), do: "__MODULE__"

  defp alias_of({var, _, context}) when is_atom(var) and is_atom(context),
    do: "~" <> Atom.to_string(var)

  defp alias_of(other) do
    case first_alias(other) do
      nil -> "~expr"
      alias_name -> "~q:" <> alias_name
    end
  end

  defp first_alias(ast) do
    ast
    |> prewalk_collect(fn
      {:__aliases__, _, parts} -> [Enum.map_join(parts, ".", &Atom.to_string/1)]
      _ -> []
    end)
    |> List.first()
  end

  defp id_field?({{:., _, [{var, _, ctx}, field]}, _, _})
       when is_atom(var) and is_atom(ctx) and is_atom(field) do
    field == :id or String.ends_with?(Atom.to_string(field), "_id")
  end

  defp id_field?(_), do: false

  defp pinned?({:^, _, _}), do: true
  defp pinned?(_), do: false

  defp relative(path), do: Path.relative_to(path, lib_root())
end
