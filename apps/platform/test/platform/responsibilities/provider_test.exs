defmodule Platform.Responsibilities.ProviderTest do
  @moduledoc """
  Tests the `Platform.Responsibilities.Provider` behaviour contract plus
  the `register/1` + `register_all/1` boot-time registration entry
  points (ADR-0041 M1 stage 3).
  """
  use Platform.DataCase, async: true

  alias Platform.Responsibilities
  alias Platform.Responsibilities.Responsibility

  # ── fixture providers ─────────────────────────────────────────────────────

  defmodule FakeProvider do
    @moduledoc false
    @behaviour Platform.Responsibilities.Provider

    @impl true
    def register do
      [
        %{
          key: "fake.one",
          feature: "fake",
          trigger_kind: "cron",
          trigger_config: %{"expression" => "*/5 * * * *"},
          scope: "global",
          context_provided: [],
          output_contract: %{"summary" => "string"},
          default_prompt_template: "fake.one.v1",
          cost_profile: "low_freq_capable"
        }
      ]
    end

    @impl true
    def gather_context(_resp, _ctx), do: {:ok, %{}}

    @impl true
    def handle_output(_resp, _output), do: :ok
  end

  defmodule SecondProvider do
    @moduledoc false
    @behaviour Platform.Responsibilities.Provider

    @impl true
    def register do
      [
        %{
          key: "second.alpha",
          feature: "second",
          trigger_kind: "event_topic",
          trigger_config: %{"topic" => "second.event"},
          scope: "per_org",
          context_provided: ["history"],
          output_contract: %{"text" => "string"},
          default_prompt_template: "second.alpha.v1",
          cost_profile: "high_freq_low_cost"
        }
      ]
    end

    @impl true
    def gather_context(_resp, _ctx), do: {:ok, %{}}

    @impl true
    def handle_output(_resp, _output), do: :ok
  end

  defmodule BadProvider do
    @moduledoc false
    @behaviour Platform.Responsibilities.Provider

    @impl true
    def register do
      # Missing required `cost_profile` will fail the changeset.
      [
        %{
          key: "bad.broken",
          feature: "bad",
          trigger_kind: "cron",
          trigger_config: %{"expression" => "*/5 * * * *"},
          scope: "global"
        }
      ]
    end

    @impl true
    def gather_context(_resp, _ctx), do: {:ok, %{}}

    @impl true
    def handle_output(_resp, _output), do: :ok
  end

  # Module that exists but doesn't implement the behaviour.
  defmodule NotAProvider do
    @moduledoc false
    def something_else, do: :ok
  end

  # Two providers that declare the same key with different cost_profiles —
  # used to prove last-writer-wins for upsert_by_key/1.
  defmodule SharedKeyProviderA do
    @moduledoc false
    @behaviour Platform.Responsibilities.Provider

    @impl true
    def register do
      [
        %{
          key: "shared.same",
          feature: "shared",
          trigger_kind: "cron",
          trigger_config: %{"expression" => "*/5 * * * *"},
          scope: "global",
          output_contract: %{"summary" => "string"},
          default_prompt_template: "shared.v1",
          context_provided: [],
          cost_profile: "high_freq_low_cost"
        }
      ]
    end

    @impl true
    def gather_context(_r, _c), do: {:ok, %{}}

    @impl true
    def handle_output(_r, _o), do: :ok
  end

  defmodule SharedKeyProviderB do
    @moduledoc false
    @behaviour Platform.Responsibilities.Provider

    @impl true
    def register do
      [
        %{
          key: "shared.same",
          feature: "shared",
          trigger_kind: "cron",
          trigger_config: %{"expression" => "*/5 * * * *"},
          scope: "global",
          output_contract: %{"summary" => "string"},
          default_prompt_template: "shared.v1",
          context_provided: [],
          cost_profile: "low_freq_capable"
        }
      ]
    end

    @impl true
    def gather_context(_r, _c), do: {:ok, %{}}

    @impl true
    def handle_output(_r, _o), do: :ok
  end

  # ── register/1 ─────────────────────────────────────────────────────────────

  describe "register/1" do
    test "upserts the rows declared by the provider" do
      assert {:ok, [%Responsibility{} = row]} = Responsibilities.register(FakeProvider)
      assert row.key == "fake.one"
      assert row.feature == "fake"
      assert row.cost_profile == "low_freq_capable"
    end

    test "is idempotent — repeated calls keep the same id" do
      {:ok, [first]} = Responsibilities.register(FakeProvider)
      {:ok, [second]} = Responsibilities.register(FakeProvider)

      assert first.id == second.id
      assert first.key == second.key
    end

    test "rejects a module that exists but doesn't implement register/0" do
      assert {:error, {NotAProvider, :not_a_provider}} =
               Responsibilities.register(NotAProvider)
    end

    test "rejects a module name that isn't loaded" do
      undefined = :"Elixir.Platform.Responsibilities.ProviderTest.NeverDefined"

      assert {:error, {^undefined, :module_not_loaded}} =
               Responsibilities.register(undefined)
    end

    test "returns invalid_attrs error when register/0 yields a bad attribute map" do
      assert {:error, {BadProvider, {:invalid_attrs, %Ecto.Changeset{} = cs}}} =
               Responsibilities.register(BadProvider)

      assert Keyword.has_key?(cs.errors, :cost_profile)
    end
  end

  # ── register_all/1 ─────────────────────────────────────────────────────────

  describe "register_all/1" do
    test "aggregates ok rows across multiple providers" do
      assert {:ok, %{ok: rows, errors: []}} =
               Responsibilities.register_all([FakeProvider, SecondProvider])

      keys = Enum.map(rows, & &1.key) |> Enum.sort()
      assert keys == ["fake.one", "second.alpha"]
    end

    test "collects per-provider failures into :errors without poisoning siblings" do
      assert {:ok, %{ok: oks, errors: errors}} =
               Responsibilities.register_all([FakeProvider, BadProvider, SecondProvider])

      ok_keys = Enum.map(oks, & &1.key) |> Enum.sort()
      assert ok_keys == ["fake.one", "second.alpha"]

      assert [{BadProvider, {:invalid_attrs, %Ecto.Changeset{}}}] = errors
    end

    test "tolerates an unloaded module name without crashing" do
      ghost = :"Elixir.Platform.Responsibilities.ProviderTest.AlsoMissing"

      assert {:ok, %{ok: oks, errors: errors}} =
               Responsibilities.register_all([FakeProvider, ghost])

      assert [row] = oks
      assert row.key == "fake.one"
      assert [{^ghost, :module_not_loaded}] = errors
    end

    test "tolerates an empty provider list" do
      assert {:ok, %{ok: [], errors: []}} = Responsibilities.register_all([])
    end

    test "last writer wins when two providers declare the same key" do
      assert {:ok, %{ok: rows, errors: []}} =
               Responsibilities.register_all([SharedKeyProviderA, SharedKeyProviderB])

      # Both providers report success; both rows reference the same DB row.
      assert length(rows) == 2
      assert Enum.all?(rows, &(&1.key == "shared.same"))

      # The persisted row reflects the second writer's cost_profile.
      persisted = Responsibilities.get_by_key("shared.same")
      assert persisted.cost_profile == "low_freq_capable"
    end
  end
end
