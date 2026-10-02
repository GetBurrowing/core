defmodule Platform.Agents.ContextDeltaTest do
  use ExUnit.Case, async: true

  alias Platform.Agents.ContextDelta

  describe "new/1 additions normalisation" do
    # Regression: the `%Date{}` head of `normalize_value/1` sat after the
    # `is_map/1` head, so a Date was treated as a plain map and `Map.new/2`
    # raised Protocol.UndefinedError on the struct.
    test "keeps a Date value intact, top-level and nested" do
      date = ~D[2026-10-02]

      assert {:ok, %ContextDelta{additions: additions}} =
               ContextDelta.new(%{
                 from_agent: "agent-1",
                 from_session: "session-1",
                 additions: %{due: date, nested: %{on: date}, list: [date]}
               })

      assert additions == %{
               "due" => date,
               "nested" => %{"on" => date},
               "list" => [date]
             }
    end

    test "still stringifies plain-map keys and atom values" do
      assert {:ok, %ContextDelta{additions: additions}} =
               ContextDelta.new(%{
                 from_agent: "agent-1",
                 from_session: "session-1",
                 additions: %{status: :open, meta: %{kind: :note}}
               })

      assert additions == %{"status" => "open", "meta" => %{"kind" => "note"}}
    end
  end
end
