defmodule Platform.UpdaterFixtures do
  @moduledoc """
  Tmp trees standing in for the host updater's two mounts (task 01a1b7b6
  stage 3): `<root>/core/{staging,inbox}` and `<root>/outbox/status.json`.
  `setup_updater_dirs/1` points `Platform.Updates` at them for one test.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc "Creates the tree, configures `Platform.Updates`, and restores both on exit."
  def setup_updater_dirs(_context \\ %{}) do
    root = Path.join(System.tmp_dir!(), "updates-#{System.unique_integer([:positive])}")
    core = Path.join(root, "core")
    File.mkdir_p!(Path.join(core, "staging"))
    File.mkdir_p!(Path.join(core, "inbox"))
    File.mkdir_p!(Path.join(root, "outbox"))
    status = Path.join([root, "outbox", "status.json"])

    previous = Application.get_env(:platform, Platform.Updates)
    Application.put_env(:platform, Platform.Updates, core_dir: core, status_path: status)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:platform, Platform.Updates, previous),
        else: Application.delete_env(:platform, Platform.Updates)

      File.rm_rf!(root)
    end)

    %{updater_root: root, core_dir: core, status_path: status}
  end

  @doc "A status.json body as the stage 1 updater writes it, with `overrides` merged."
  def status_json(overrides \\ %{}) do
    %{
      "channel" => "stable",
      "auto_update" => true,
      "last_result" => "ok",
      "last_checked_at" => "2026-11-07T20:00:00Z",
      "deferred_since" => nil,
      "current" => %{
        "digest" => "ghcr.io/example/core@sha256:" <> String.duplicate("a", 64),
        "commit" => "061fbe1d2c3b4a5968778695a4b3c2d1e0f9a8b7"
      },
      "available" => nil,
      "last_rollback" => nil,
      "pending_irreversible" => nil,
      "last_request" => nil
    }
    |> Map.merge(overrides)
  end

  @doc "Writes `status_json(overrides)` to the configured status path."
  def write_status!(path, overrides \\ %{}) do
    File.write!(path, Jason.encode!(status_json(overrides)))
  end
end
