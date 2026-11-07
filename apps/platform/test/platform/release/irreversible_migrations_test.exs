defmodule Platform.Release.IrreversibleMigrationsTest do
  @moduledoc """
  Guard for `deployment/release/irreversible-migrations.txt` (task 01a1b7b6
  stage 2).

  The file lists the migrations the PREVIOUS release's code cannot run
  against. The host updater reads it from the image
  (`/app/release/irreversible-migrations.txt`) to hold such a release for an
  explicit "Update now" and to refuse an automatic rollback past it, so a
  destructive migration that is NOT listed would be applied, and rolled back
  past, as if it were harmless.

  The rule, for every migration newer than `@cutoff`:

    * if its source (comment lines excluded) matches any trigger below, it
      must be listed in the file OR carry a
      `# old-code-compatible: <reason>` comment;
    * every version listed must name an existing migration file;
    * every non-comment line of the file is exactly one 14-digit version
      (the host updater reads it line by line, with no inline comments).

  `@cutoff` is the newest migration version on main when the guard was
  written; older migrations predate the channels and are not re-judged.

  A regex heuristic over the source, deliberately over-eager: a false
  positive costs one waiver comment. It reads files only (no git, no DB).
  """

  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../../..", __DIR__)
  @list_path Path.join(@repo_root, "deployment/release/irreversible-migrations.txt")
  @migration_glob Path.join(@repo_root, "apps/*/priv/repo/migrations/*.exs")

  # Newest migration version on main when this guard was written.
  @cutoff 20_261_106_194_315

  @triggers [
    {"remove ", ~r/remove /},
    {"drop", ~r/drop/},
    {"rename", ~r/rename/},
    {"modify ", ~r/modify /},
    {"execute", ~r/execute/},
    {"unique_index", ~r/unique_index/},
    {"create constraint", ~r/create constraint/}
  ]

  @waiver ~r/^[ \t]*#[ \t]*old-code-compatible:[ \t]*\S/m

  # --- the rule, as pure functions over text --------------------------------

  @doc false
  def version_of(path) do
    case Regex.run(~r/^(\d{14})_/, Path.basename(path)) do
      [_, v] -> String.to_integer(v)
      _ -> nil
    end
  end

  @doc false
  def triggers(source) do
    code =
      source
      |> String.split("\n")
      |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "#"))

    joined = Enum.join(code, "\n")

    named =
      for {name, re} <- @triggers, Regex.match?(re, joined), do: name

    null_false =
      if Enum.any?(code, &(&1 =~ "null: false" and not (&1 =~ "default:"))),
        do: ["null: false without default:"],
        else: []

    named ++ null_false
  end

  @doc false
  def waived?(source), do: Regex.match?(@waiver, source)

  @doc false
  def parse_list(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
  end

  @doc false
  def violations(migrations, listed, cutoff) do
    migrations
    |> Enum.filter(fn {path, _} -> (version_of(path) || 0) > cutoff end)
    |> Enum.reject(fn {path, _} -> Integer.to_string(version_of(path)) in listed end)
    |> Enum.reject(fn {_, source} -> waived?(source) end)
    |> Enum.map(fn {path, source} -> {Path.basename(path), triggers(source)} end)
    |> Enum.reject(fn {_, hits} -> hits == [] end)
  end

  defp migrations, do: for(p <- Path.wildcard(@migration_glob), do: {p, File.read!(p)})
  defp listed, do: @list_path |> File.read!() |> parse_list()

  # --- the real tree -----------------------------------------------------------

  test "the migration glob sees every app's migrations" do
    # Positive control: an empty glob would pass every rule below.
    files = Path.wildcard(@migration_glob)
    assert length(files) > 100
    assert Enum.any?(files, &String.contains?(&1, "/apps/platform/priv/repo/migrations/"))
    assert Enum.all?(files, &version_of/1)
  end

  test "the cutoff is a real migration version" do
    assert Enum.any?(Path.wildcard(@migration_glob), &(version_of(&1) == @cutoff))
  end

  test "every destructive migration newer than the cutoff is listed or waived" do
    assert violations(migrations(), listed(), @cutoff) == [],
           "Each migration above may break the PREVIOUS release's code. List its " <>
             "version in deployment/release/irreversible-migrations.txt, or add " <>
             "`# old-code-compatible: <reason>` to it if old code really runs against it."
  end

  test "every line of the list is one 14-digit version" do
    for line <- listed() do
      assert line =~ ~r/^\d{14}$/,
             "irreversible-migrations.txt: `#{line}` is not a bare 14-digit version " <>
               "(the host updater reads each non-# line as a version; no inline comments)"
    end
  end

  test "every listed version names an existing migration file" do
    versions = MapSet.new(Path.wildcard(@migration_glob), &Integer.to_string(version_of(&1)))

    for v <- listed() do
      assert MapSet.member?(versions, v),
             "irreversible-migrations.txt lists #{v}, but no apps/*/priv/repo/migrations/#{v}_*.exs exists"
    end
  end

  test "the list ships in both images, identically" do
    for dockerfile <- ["apps/platform/Dockerfile", "apps/burrow_release/Dockerfile"] do
      assert File.read!(Path.join(@repo_root, dockerfile)) =~
               ~r{^COPY deployment/release/irreversible-migrations\.txt /app/release/irreversible-migrations\.txt$}m,
             "#{dockerfile} no longer copies the irreversible-migrations list"
    end
  end

  # --- positive controls: the rule sees each case -----------------------------

  @remove_column """
  defmodule Platform.Repo.Migrations.DropLegacy do
    use Ecto.Migration

    def change do
      alter table(:spaces) do
        remove :legacy_kind
      end
    end
  end
  """

  test "a `remove ` migration past the cutoff, neither listed nor waived, is a violation" do
    path = "apps/platform/priv/repo/migrations/20991231000000_drop_legacy.exs"

    assert violations([{path, @remove_column}], [], @cutoff) ==
             [{"20991231000000_drop_legacy.exs", ["remove "]}]
  end

  test "listing the version or a waiver clears it" do
    path = "apps/platform/priv/repo/migrations/20991231000000_drop_legacy.exs"
    assert violations([{path, @remove_column}], ["20991231000000"], @cutoff) == []

    waived = "# old-code-compatible: the column was never read\n" <> @remove_column
    assert violations([{path, waived}], [], @cutoff) == []

    # An empty reason is not a waiver.
    bare = "# old-code-compatible:\n" <> @remove_column
    assert violations([{path, bare}], [], @cutoff) != []
  end

  test "a migration at or before the cutoff is not judged" do
    path = "apps/platform/priv/repo/migrations/#{@cutoff}_drop_legacy.exs"
    assert violations([{path, @remove_column}], [], @cutoff) == []
  end

  test "each trigger is seen" do
    cases = [
      {"remove :a", "remove "},
      {"drop table(:a)", "drop"},
      {"drop_if_exists index(:a, [:b])", "drop"},
      {"rename table(:a), :b, to: :c", "rename"},
      {"modify :a, :text", "modify "},
      {~s|execute "UPDATE a SET b = 1"|, "execute"},
      {"create unique_index(:a, [:b])", "unique_index"},
      {~s|create constraint(:a, :b, check: "c > 0")|, "create constraint"},
      {"add :a, :text, null: false", "null: false without default:"}
    ]

    for {line, trigger} <- cases do
      assert trigger in triggers("def change do\n  #{line}\nend\n"), "#{line} -> #{trigger}"
    end
  end

  test "an additive migration triggers nothing" do
    source = """
    def change do
      alter table(:a) do
        add :b, :text
        add :c, :boolean, null: false, default: false
      end
      create index(:a, [:b])
    end
    """

    assert triggers(source) == []
  end

  test "a trigger word in a comment line is ignored" do
    assert triggers("# we will drop this later\ndef change, do: :ok\n") == []
  end

  test "the list parser skips comments and blanks" do
    assert parse_list("# header\n\n20261107000000\n# x\n20261108000000\n") ==
             ["20261107000000", "20261108000000"]
  end
end
