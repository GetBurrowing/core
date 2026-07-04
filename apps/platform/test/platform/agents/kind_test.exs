defmodule Platform.Agents.KindTest do
  @moduledoc """
  Unit tests for `Platform.Agents.Kind.classify/1` (task 019f2566 stage 3).

  Covers the three canonical shapes plus nil/unknown fallback.
  """
  use ExUnit.Case, async: true

  alias Platform.Agents.Agent
  alias Platform.Agents.Kind

  describe "classify/1 — %Agent{} struct" do
    test "kind='external' → :ext_single_responsibility (Hermione shape)" do
      assert Kind.classify(%Agent{
               kind: "external",
               endpoint_kind: "openai_compat",
               base_url: "https://llm.example.test",
               model: "some-model"
             }) == :ext_single_responsibility
    end

    test "kind='native' + runtime_type='external' → :fed_conversational (Dalton shape)" do
      assert Kind.classify(%Agent{kind: "native", runtime_type: "external"}) ==
               :fed_conversational
    end

    test "kind='native' + runtime_type='built_in' → :loc_built_in (default local)" do
      assert Kind.classify(%Agent{kind: "native", runtime_type: "built_in"}) == :loc_built_in
    end

    test "external wins over runtime_type='external' (external endpoint is the outer classifier)" do
      # A native agent with runtime_type=external is Dalton. An
      # external-kind agent is always ext_single_responsibility even
      # if someone jams runtime_type=external into the row — the
      # kind='external' branch fires first.
      assert Kind.classify(%Agent{kind: "external", runtime_type: "external"}) ==
               :ext_single_responsibility
    end
  end

  describe "classify/1 — plain maps" do
    test "atom-keyed external shape" do
      assert Kind.classify(%{kind: "external"}) == :ext_single_responsibility
    end

    test "string-keyed external shape" do
      assert Kind.classify(%{"kind" => "external"}) == :ext_single_responsibility
    end

    test "atom-keyed federated shape" do
      assert Kind.classify(%{kind: "native", runtime_type: "external"}) == :fed_conversational
    end

    test "string-keyed federated shape" do
      assert Kind.classify(%{"kind" => "native", "runtime_type" => "external"}) ==
               :fed_conversational
    end

    test "mixed key shape (atom kind, string runtime_type) still resolves" do
      assert Kind.classify(%{"runtime_type" => "external", kind: "native"}) == :fed_conversational
    end

    test "empty map falls through to :loc_built_in" do
      assert Kind.classify(%{}) == :loc_built_in
    end
  end

  describe "classify/1 — nil / unknown input" do
    test "nil is :loc_built_in" do
      assert Kind.classify(nil) == :loc_built_in
    end

    test "arbitrary term is :loc_built_in" do
      assert Kind.classify(:not_an_agent) == :loc_built_in
      assert Kind.classify("hermione") == :loc_built_in
      assert Kind.classify(123) == :loc_built_in
    end
  end
end
