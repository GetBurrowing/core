defmodule Platform.Responsibilities.RegistryTest do
  @moduledoc """
  Boot-time Registry GenServer (ADR-0041 M1 stage 4).

  Tests start a per-case instance with a unique registered name to keep
  the DataCase sandbox owner of the Repo connection. The app supervisor
  flag `:start_responsibilities_registry` is `false` in `config/test.exs`,
  so no second copy can race us here.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Responsibilities
  alias Platform.Responsibilities.Registry

  # ── fixture providers ─────────────────────────────────────────────────────

  defmodule FakeProvider do
    @moduledoc false
    @behaviour Platform.Responsibilities.Provider

    @impl true
    def register do
      [
        %{
          key: "registrytestfake.one",
          feature: "registry_test_fake",
          trigger_kind: "cron",
          trigger_config: %{"expression" => "*/5 * * * *"},
          scope: "global",
          context_provided: [],
          output_contract: %{"summary" => "string"},
          default_prompt_template: "registry_test.fake.v1",
          cost_profile: "low_freq_capable"
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
          key: "registrytestbad.broken",
          feature: "registry_test_bad",
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

  # Start a Registry under the test supervisor with a unique name per
  # case so concurrent (and re-run) tests never collide on `__MODULE__`.
  defp start_registry(opts) do
    name = unique_name()
    pid = start_supervised!({Registry, Keyword.put(opts, :name, name)})
    {pid, name}
  end

  defp unique_name do
    suffix = System.unique_integer([:positive])
    :"#{__MODULE__}.Reg#{suffix}"
  end

  # ── happy path ────────────────────────────────────────────────────────────

  describe "init with explicit providers" do
    test "upserts rows declared by every provider in the list" do
      {_pid, name} = start_registry(providers: [FakeProvider])

      status = Registry.status(name)
      assert %{ok: [row], errors: []} = status
      assert row.key == "registrytestfake.one"

      # Round-trip through the context module to prove the row is
      # actually persisted, not just held in GenServer state.
      persisted = Responsibilities.get_by_key("registrytestfake.one")
      assert persisted
      assert persisted.id == row.id
    end

    test "providers/0 returns the configured module list" do
      {_pid, name} = start_registry(providers: [FakeProvider])
      assert Registry.providers(name) == [FakeProvider]
    end

    test "tolerates an empty provider list" do
      {_pid, name} = start_registry(providers: [])
      assert Registry.status(name) == %{ok: [], errors: []}
      assert Registry.providers(name) == []
    end
  end

  # ── reload ────────────────────────────────────────────────────────────────

  describe "reload/0" do
    test "re-runs register_all idempotently (no duplicate inserts, no errors)" do
      {_pid, name} = start_registry(providers: [FakeProvider])

      first = Registry.status(name)
      assert [%{id: first_id, key: "registrytestfake.one"}] = first.ok
      assert first.errors == []

      second = Registry.reload(name)
      assert [%{id: second_id, key: "registrytestfake.one"}] = second.ok
      assert second.errors == []

      # Same row id across calls — upsert preserved the primary key.
      assert first_id == second_id

      # status/0 now reflects the reload result.
      assert Registry.status(name) == second
    end
  end

  # ── boot safety ───────────────────────────────────────────────────────────

  describe "boot safety" do
    test "bad provider in list does not crash the registry and siblings still register" do
      # The test env clamps Logger to :warning; bump it just for this
      # case so the :info "registered N" log lines are emittable and
      # therefore capturable. Reset on exit so we don't leak state.
      prev_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: prev_level) end)

      log =
        capture_log([level: :info], fn ->
          {pid, name} = start_registry(providers: [FakeProvider, BadProvider])

          # Process is alive even though one provider failed.
          assert Process.alive?(pid)

          status = Registry.status(name)
          ok_keys = Enum.map(status.ok, & &1.key) |> Enum.sort()
          assert ok_keys == ["registrytestfake.one"]
          assert [{BadProvider, {:invalid_attrs, %Ecto.Changeset{}}}] = status.errors

          # FakeProvider's row is actually in the DB despite BadProvider's failure.
          assert Responsibilities.get_by_key("registrytestfake.one")
          refute Responsibilities.get_by_key("registrytestbad.broken")
        end)

      assert log =~ "registered 1 responsibilities for"
      assert log =~ "Platform.Responsibilities.RegistryTest.FakeProvider"
      assert log =~ "register failed for"
      assert log =~ "Platform.Responsibilities.RegistryTest.BadProvider"
    end
  end
end
