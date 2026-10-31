defmodule Platform.Installs.Python do
  @moduledoc """
  Runs the installer CLI (`python3 -m burrow_install ...`, the one template and
  the one pocket-id client, `deployment/installer/`) from core (task 01a10315
  stage 2). The renderer is never ported to Elixir.

  `config :platform, Platform.Installs, installer_path:` is the directory that
  holds the `burrow_install` package: `/app/installer` in the release image,
  the repo's `deployment/installer` in dev and test.

  Every run gets a fresh 0700 directory under `System.tmp_dir!/0` (outside any
  git tree, which the renderer requires), removed in an `after` block whatever
  happens. Secrets reach the CLI only as 0600 files in that directory, never
  as arguments or environment.
  """

  @doc "The directory holding the `burrow_install` package."
  @spec installer_path() :: String.t()
  def installer_path do
    Application.get_env(:platform, Platform.Installs, [])
    |> Keyword.get_lazy(:installer_path, fn ->
      Path.expand("../../../../../deployment/installer", __DIR__)
    end)
  end

  @doc """
  Run `fun.(dir)` with a fresh private directory and remove it afterwards.
  """
  @spec with_private_dir((String.t() -> result)) :: result when result: term()
  def with_private_dir(fun) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "burrow-installs-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)

    try do
      fun.(dir)
    after
      File.rm_rf!(dir)
    end
  end

  @doc "Write `contents` to `path` with mode 0600."
  @spec write_private!(String.t(), iodata()) :: :ok
  def write_private!(path, contents) do
    File.touch!(path)
    File.chmod!(path, 0o600)
    File.write!(path, contents)
  end

  @doc """
  `python3 -m burrow_install <args>`. Returns `{output, exit_status}`;
  stdout and stderr are merged. Callers must never log the output whole.
  """
  @spec run([String.t()]) :: {String.t(), non_neg_integer()} | {:error, :python_missing}
  def run(args) do
    case System.find_executable("python3") do
      nil ->
        {:error, :python_missing}

      python ->
        System.cmd(python, ["-m", "burrow_install" | args],
          env: [{"PYTHONPATH", installer_path()}],
          stderr_to_stdout: true
        )
    end
  end
end
