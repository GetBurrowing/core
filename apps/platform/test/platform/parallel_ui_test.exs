defmodule Platform.ParallelUITest do
  @moduledoc """
  Two-direction guard for the `Platform.ParallelUI` ledger (task 01a156cb).

  Main carries zero entries, so a test that only looked at the live ledger
  would be vacuous until the first rung lands. Every direction is therefore
  shown to fire on synthetic input first:

    * the entry schema is driven against hand-built bad entries, one broken
      field at a time;
    * `check/2` is driven with seeded entries and markers;
    * `Markers.scan/1` is driven against a fixture directory with one real
      marker per file plus decoys, at exact `file:line`.

  Only then is the live tree checked, together with a `files_scanned` floor:
  without the floor, a scan of the wrong root finds zero markers and the
  zero-entry check stays green.
  """

  use ExUnit.Case, async: true

  alias Platform.ParallelUI
  alias Platform.ParallelUI.Markers

  @fixture_dir Path.expand("../support/fixtures/parallel_ui", __DIR__)
  @heex_fixture_dir Path.expand("../support/fixtures/parallel_ui_heex", __DIR__)

  @uuid_regex ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  # Measured on main 60af1f6fe (2026-10-20) by counting `.ex .exs .heex .js .ts`
  # files under each root with `find <root> -type f`, from apps/platform:
  #   lib 1100, priv/repo/migrations 360, assets/js 91 (total 1551).
  # Floors sit well below so deleting files never trips them; a wrong or
  # missing root scans zero files and does.
  @root_floors %{"lib" => 900, "priv/repo/migrations" => 300, "assets/js" => 70}
  @files_scanned_floor 1300

  @valid_event %{
    id: "probe-event",
    kind: :event,
    legacy: "the {:probe, _} PubSub broadcast the old task board listens for",
    replacement: "the {:task_changed, _} broadcast",
    introduced_by: "01a156cb-71f8-7000-89f2-7842bacbdbf1",
    cutover: "stop broadcasting {:probe, _}"
  }

  @valid_column %{
    id: "probe-col",
    kind: :column,
    legacy: "tasks.legacy_title, still read by the old task card",
    replacement: "tasks.title",
    introduced_by: "01a156cb-71f8-7000-89f2-7842bacbdbf1",
    cutover: "drop column tasks.legacy_title",
    table: "tasks",
    column: "legacy_title"
  }

  # Returns the names of the schema rules `entry` breaks, [] when valid.
  defp entry_errors(entry) do
    kind = Map.get(entry, :kind)

    expected_keys =
      if kind == :column,
        do: ParallelUI.required_keys() ++ ParallelUI.column_keys(),
        else: ParallelUI.required_keys()

    [
      keys: MapSet.new(Map.keys(entry)) == MapSet.new(expected_keys),
      kind: kind in ParallelUI.kinds(),
      id: is_binary(entry[:id]) and Regex.match?(ParallelUI.id_regex(), entry[:id]),
      introduced_by:
        is_binary(entry[:introduced_by]) and Regex.match?(@uuid_regex, entry[:introduced_by]),
      legacy: non_blank?(entry[:legacy]),
      cutover: non_blank?(entry[:cutover]),
      column_target: kind != :column or (non_blank?(entry[:table]) and non_blank?(entry[:column]))
    ]
    |> Enum.reject(fn {_rule, ok?} -> ok? end)
    |> Enum.map(fn {rule, _} -> rule end)
  end

  defp non_blank?(value), do: is_binary(value) and String.trim(value) != ""

  defp duplicate_ids(entries) do
    entries
    |> Enum.frequencies_by(& &1[:id])
    |> Enum.filter(fn {_id, n} -> n > 1 end)
    |> Enum.map(fn {id, _} -> id end)
  end

  defp marker(id, path \\ "lib/platform/x.ex", line \\ 1),
    do: %{id: id, path: path, line: line}

  describe "entry schema" do
    test "every live entry passes every schema rule" do
      for entry <- ParallelUI.entries() do
        assert entry_errors(entry) == [],
               "Platform.ParallelUI entry #{inspect(entry[:id])} breaks " <>
                 "#{inspect(entry_errors(entry))}: #{inspect(entry)}"
      end
    end

    test "live ids are unique" do
      assert duplicate_ids(ParallelUI.entries()) == []
    end

    test "kinds, keys and the id grammar are the documented ones" do
      assert ParallelUI.kinds() == [:event, :field, :column, :dual_write, :route]

      assert ParallelUI.required_keys() ==
               [:id, :kind, :legacy, :replacement, :introduced_by, :cutover]

      assert ParallelUI.column_keys() == [:table, :column]
      assert Regex.match?(ParallelUI.id_regex(), "probe-event.v2_x")
      refute Regex.match?(ParallelUI.id_regex(), "<id>")
      refute Regex.match?(ParallelUI.id_regex(), "Probe")
      refute Regex.match?(ParallelUI.id_regex(), "-probe")
      refute Regex.match?(ParallelUI.id_regex(), "")
    end

    test "the hand-built valid entries pass, so the bad-entry table below is not vacuous" do
      assert entry_errors(@valid_event) == []
      assert entry_errors(@valid_column) == []
    end

    test "each schema rule fires on exactly one hand-built bad entry" do
      cases = [
        {Map.delete(@valid_event, :cutover), [:keys, :cutover]},
        {Map.put(@valid_event, :ticket, "x"), [:keys]},
        {Map.put(@valid_event, :table, "tasks"), [:keys]},
        {Map.drop(@valid_column, [:table]), [:keys, :column_target]},
        {Map.put(@valid_column, :column, " "), [:column_target]},
        {%{@valid_event | kind: :shim}, [:kind]},
        {%{@valid_event | id: "Probe-Event"}, [:id]},
        {%{@valid_event | id: "<id>"}, [:id]},
        {%{@valid_event | introduced_by: "01a156cb"}, [:introduced_by]},
        {%{@valid_event | legacy: "  "}, [:legacy]},
        {%{@valid_event | cutover: ""}, [:cutover]}
      ]

      for {bad, expected} <- cases do
        assert entry_errors(bad) == expected,
               "expected #{inspect(expected)} for #{inspect(bad)}, got #{inspect(entry_errors(bad))}"
      end
    end

    test "the duplicate-id rule fires on a seeded duplicate" do
      assert duplicate_ids([@valid_event, @valid_column]) == []
      assert duplicate_ids([@valid_event, @valid_event]) == ["probe-event"]
    end
  end

  describe "check/2" do
    test "an entry with a marker is ok" do
      assert ParallelUI.check([@valid_event], [marker("probe-event")]) == :ok
    end

    test "an entry with no marker is unmarked" do
      assert ParallelUI.check([@valid_event], []) ==
               {:error, %{unmarked: ["probe-event"], unregistered: []}}
    end

    test "a marker with no entry is unregistered, with its path and line" do
      assert ParallelUI.check([], [marker("orphan-probe", "lib/platform/tasks.ex", 42)]) ==
               {:error,
                %{
                  unmarked: [],
                  unregistered: [%{id: "orphan-probe", path: "lib/platform/tasks.ex", line: 42}]
                }}
    end

    test "both directions are reported together" do
      assert {:error, %{unmarked: ["probe-col"], unregistered: [%{id: "orphan-probe"}]}} =
               ParallelUI.check(
                 [@valid_event, @valid_column],
                 [marker("probe-event"), marker("orphan-probe")]
               )
    end

    test "no entries and no markers is ok" do
      assert ParallelUI.check([], []) == :ok
    end
  end

  describe "Markers.scan/1 positive control" do
    test "finds exactly the two real fixture markers and none of the decoys" do
      result = Markers.scan([@fixture_dir])

      assert result.files_scanned == 2

      assert result.markers == [
               %{
                 id: "fixture-known-id",
                 path: "test/support/fixtures/parallel_ui/sample.exs",
                 line: 6
               },
               %{
                 id: "fixture-known-id",
                 path: "test/support/fixtures/parallel_ui/sample.js",
                 line: 6
               }
             ]
    end

    test "the decoys really are in the fixtures, so their absence above means something" do
      for file <- ["sample.exs", "sample.js"] do
        text = File.read!(Path.join(@fixture_dir, file))
        assert text =~ "parallel-ui: <id>"
        assert text =~ ~s("parallel-ui: fixture-decoy")
      end
    end

    test "the scanned markers drive check/2 in both directions" do
      %{markers: markers} = Markers.scan([@fixture_dir])
      entry = %{@valid_event | id: "fixture-known-id"}

      assert ParallelUI.check([entry], markers) == :ok

      assert {:error, %{unmarked: [], unregistered: [%{line: 6}, %{line: 6}]}} =
               ParallelUI.check([], markers)
    end

    # The HEEx leader `<%!--` is a third branch of the marker regex; its own
    # fixture directory keeps the two-marker control above unchanged.
    test "finds the HEEx marker and none of the HEEx decoys" do
      text = File.read!(Path.join(@heex_fixture_dir, "sample.heex"))
      assert text =~ "parallel-ui: <id>"
      assert text =~ "leader: parallel-ui: fixture-heex-decoy"

      assert Markers.scan([@heex_fixture_dir]) == %{
               markers: [
                 %{
                   id: "fixture-heex-id",
                   path: "test/support/fixtures/parallel_ui_heex/sample.heex",
                   line: 3
                 }
               ],
               files_scanned: 1
             }
    end

    test "a missing root scans zero files" do
      assert Markers.scan([Path.join(@fixture_dir, "does-not-exist")]) ==
               %{markers: [], files_scanned: 0}
    end
  end

  describe "live tree" do
    test "the default roots are exactly lib, priv/repo/migrations and assets/js" do
      app_dir = Path.expand("../..", __DIR__)

      assert Enum.map(Markers.default_roots(), &Path.relative_to(&1, app_dir)) ==
               ["lib", "priv/repo/migrations", "assets/js"]
    end

    test "each default root is actually walked" do
      app_dir = Path.expand("../..", __DIR__)

      for root <- Markers.default_roots() do
        name = Path.relative_to(root, app_dir)
        floor = Map.fetch!(@root_floors, name)
        %{files_scanned: n} = Markers.scan([root])

        assert n >= floor,
               "scanned #{n} files under #{name}, floor is #{floor}: the root is wrong or missing"
      end
    end

    test "every ledger entry is marked and every marker is registered" do
      %{markers: markers, files_scanned: files_scanned} = Markers.scan()

      assert files_scanned >= @files_scanned_floor,
             "scanned #{files_scanned} files, floor is #{@files_scanned_floor}: " <>
               "a scan that never ran would also find zero markers"

      case ParallelUI.check(ParallelUI.entries(), markers) do
        :ok ->
          :ok

        {:error, %{unmarked: unmarked, unregistered: unregistered}} ->
          flunk("""
          Platform.ParallelUI ledger and markers disagree.

          Entries with no `parallel-ui:` marker anywhere (add the marker, or delete the entry):
          #{Enum.map_join(unmarked, "\n", &"  #{&1}")}

          Markers with no entry in Platform.ParallelUI (add the entry, or delete the marker):
          #{Enum.map_join(unregistered, "\n", &"  #{&1.path}:#{&1.line} #{&1.id}")}
          """)
      end
    end
  end
end
