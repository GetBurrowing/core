defmodule Platform.Repo.Migrations.BackfillExternalAgentHttpRuntimeTypeTest do
  @moduledoc """
  Task 01a1b20f stage 1. Behavioural coverage of
  `20261106182012_backfill_external_agent_http_runtime_type`.

  The suite migrates an EMPTY database, where the UPDATE matches zero rows,
  so this file seeds the pre-fix row shapes directly (struct inserts, no
  changeset or context) and runs the SHIPPED `up/0` and `down/0` through
  `Ecto.Migration.Runner` on the sandboxed connection, the same way as
  `BackfillChannelCreatorAdminTest`. Every test asserts which rows changed AND
  which did not.
  """
  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Repo

  @migration Platform.Repo.Migrations.BackfillExternalAgentHttpRuntimeType

  @migration_path Path.expand(
                    "../../../../priv/repo/migrations/" <>
                      "20261106182012_backfill_external_agent_http_runtime_type.exs",
                    __DIR__
                  )

  setup_all do
    unless Code.ensure_loaded?(@migration), do: Code.require_file(@migration_path)
    :ok
  end

  defp run_migration!(operation) when operation in [:up, :down] do
    {:ok, runner} =
      Ecto.Migration.Runner.start_link(
        {self(), Repo, Repo.config(), @migration, :forward, operation,
         %{level: false, sql: false}}
      )

    Ecto.Migration.Runner.metadata(runner, [])
    apply(@migration, operation, [])
    Ecto.Migration.Runner.flush()
    Ecto.Migration.Runner.stop()
    :ok
  end

  defp agent!(kind, runtime_type, endpoint_kind \\ nil) do
    n = System.unique_integer([:positive])

    external_fields =
      if endpoint_kind,
        do: [endpoint_kind: endpoint_kind, base_url: "https://api.example.test/v1", model: "m"],
        else: []

    Repo.insert!(
      struct(
        Agent,
        [
          slug: "backfill-runtime-#{n}",
          name: "Backfill #{n}",
          status: "active",
          kind: kind,
          runtime_type: runtime_type
        ] ++ external_fields
      )
    )
  end

  defp runtime_type(%Agent{id: id}), do: Repo.get!(Agent, id).runtime_type

  test "up: an external HTTP agent on built_in becomes http" do
    openai = agent!("external", "built_in", "openai_compat")
    ollama = agent!("external", "built_in", "ollama_native")

    run_migration!(:up)

    assert runtime_type(openai) == "http"
    assert runtime_type(ollama) == "http"
  end

  test "up: native built_in and runtime_type external rows are untouched" do
    native = agent!("native", "built_in")
    federated = agent!("native", "external")
    external_ws = agent!("external", "external", "openai_compat")
    no_endpoint = agent!("external", "built_in")

    run_migration!(:up)

    assert runtime_type(native) == "built_in"
    assert runtime_type(federated) == "external"
    assert runtime_type(external_ws) == "external"
    assert runtime_type(no_endpoint) == "built_in"
  end

  test "down: reverses only external rows carrying http" do
    http = agent!("external", "http", "openai_compat")
    native_http = agent!("native", "http")
    federated = agent!("native", "external")
    native = agent!("native", "built_in")

    run_migration!(:down)

    assert runtime_type(http) == "built_in"
    assert runtime_type(native_http) == "http"
    assert runtime_type(federated) == "external"
    assert runtime_type(native) == "built_in"
  end

  test "up then down round-trips the external HTTP row" do
    ext = agent!("external", "built_in", "openai_compat")

    run_migration!(:up)
    assert runtime_type(ext) == "http"

    run_migration!(:down)
    assert runtime_type(ext) == "built_in"
  end
end
