defmodule Platform.Admin.BackupStatus do
  @moduledoc """
  The last-backup status `admin_health` reports (task 01a17b10 stage 5).

  The install's backup job (`bin/burrow-backup`, rendered by the installer when
  `[backup] target != none`) writes `backup-status.json` into core's data volume
  after a successful run: `last_success_at` (UTC ISO 8601), `size_bytes`,
  `target` and `databases`. Core only reads it. The path is
  `config :platform, :backup_status_path` (default under `/data/platform`).

  Returns `%{configured: false}` when there is no file, which is also what an
  install with `target = none` shows, and `%{configured: true, error: ...}` for
  a file that cannot be read. It never returns a path or a credential.
  """

  @default_path "/data/platform/backup-status.json"

  @spec read() :: map()
  def read do
    path = Application.get_env(:platform, :backup_status_path, @default_path)

    case File.read(path) do
      {:error, :enoent} ->
        %{configured: false}

      {:error, _} ->
        %{configured: true, error: "unreadable"}

      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{} = map} ->
            %{
              configured: true,
              last_success_at: map["last_success_at"],
              size_bytes: map["size_bytes"],
              target: map["target"],
              databases: map["databases"]
            }

          _ ->
            %{configured: true, error: "invalid"}
        end
    end
  end
end
