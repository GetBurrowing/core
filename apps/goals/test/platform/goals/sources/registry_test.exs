defmodule Platform.Goals.Sources.RegistryTest do
  use Platform.DataCase, async: false
  alias Platform.Goals.Sources

  defmodule Third do
    @behaviour Platform.Goals.Source
    def key, do: "third"
    def label, do: "Third source"
    def kind, do: :logged
    def population(_), do: {:ok, "third"}
  end

  test "registered keys, labels and required callbacks are valid" do
    keys = Enum.map(Sources.all(), & &1.key())
    assert Enum.uniq(keys) == keys

    for source <- Sources.all() do
      assert Code.ensure_loaded?(source)

      for {fun, arity} <- [key: 0, label: 0, kind: 0, population: 1] do
        assert function_exported?(source, fun, arity)
      end

      refute source.label() =~ ~r/[0-9]/
      assert source.kind() in [:logged, :measured]
      if source.kind() == :measured, do: assert(function_exported?(source, :measure, 1))
    end

    assert Sources.SelfReported.population(%{}) == {:ok, "self_reported"}
    refute function_exported?(Sources.SelfReported, :measure, 1)
  end

  test "unknown keys are refused without interpreting module names" do
    for key <- [nil, 42, "", "youtube", "Elixir.System"], do: assert(Sources.fetch(key) == :error)
  end

  test "a third source needs only a module and registration" do
    previous = Application.fetch_env(:goals, :sources)
    migrations = Path.wildcard("priv/repo/migrations/*")

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:goals, :sources, value)
        :error -> Application.delete_env(:goals, :sources)
      end
    end)

    Application.put_env(:goals, :sources, Sources.all() ++ [Third])
    assert Sources.fetch("third") == {:ok, Third}
    assert %{key: "third", label: "Third source", kind: :logged} in Sources.describe()
    assert Path.wildcard("priv/repo/migrations/*") == migrations
  end
end
