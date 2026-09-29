defmodule Platform.Meetings.OpenQuestionPilot.Programs do
  @moduledoc """
  Saved Imp programs for arm B of the open_question pilot (task 01a0e8b5).

  A program is named by a BASENAME inside `priv/imp_pilot/open_question/`
  matching `~r/^[a-z0-9_]+\\.json$/`, the only form an experiment variant's
  `"program"` may take, so a payload cannot name a path outside that
  directory. The file is an `Imp.save!/2` artefact and is read with
  `Imp.read!/1`, which verifies its checksum and never restores
  credentials.

  `load/1` caches the loaded program in `:persistent_term`, keyed by the
  sha256 of the file's bytes. A changed file is a new key, so a stale
  program is never served for new bytes. Programs are small and few (one
  per compiled arm), so the cache is not pruned.
  """

  @name ~r/^[a-z0-9_]+\.json$/

  @doc "The directory programs live in."
  @spec dir() :: String.t()
  def dir, do: Application.app_dir(:platform, "priv/imp_pilot/open_question")

  @doc "Whether `name` is an acceptable program basename (says nothing about existence)."
  @spec valid_name?(term()) :: boolean()
  def valid_name?(name), do: is_binary(name) and Regex.match?(@name, name)

  @doc """
  Load the program named `name`.

  `{:error, :invalid_name}` for anything that is not a plain basename,
  `{:error, :not_found}` for a missing file, `{:error, {:unreadable, message}}`
  when `Imp.read!/1` refuses it.
  """
  @spec load(term()) :: {:ok, struct()} | {:error, term()}
  def load(name) do
    with true <- valid_name?(name) || {:error, :invalid_name},
         path = Path.join(dir(), name),
         {:ok, bytes} <- read(path) do
      key = {__MODULE__, :crypto.hash(:sha256, bytes)}

      case :persistent_term.get(key, nil) do
        nil -> read_program(path, key)
        program -> {:ok, program}
      end
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, {:unreadable, inspect(reason)}}
    end
  end

  defp read_program(path, key) do
    program = Imp.read!(path)
    :persistent_term.put(key, program)
    {:ok, program}
  rescue
    error -> {:error, {:unreadable, Exception.message(error)}}
  end
end
