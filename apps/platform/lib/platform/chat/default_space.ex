defmodule Platform.Chat.DefaultSpace do
  @moduledoc """
  A fresh install's first channel, "General" (task 01a10322 stage 6).

  Measured on the test rig on 2026-10-09: the release image booted on an empty
  database has ZERO spaces after its migrations, so the first person to sign
  in lands in a chat with nothing in it. `ensure/0` creates `#general` in the
  root org when, and only when, the install has no channel at all.

  Idempotent:

    * it does nothing once ANY channel exists, archived ones included, so an
      install whose people renamed, archived or never wanted a "General" is
      left alone. Execution, meeting and DM spaces are not channels, so an
      install with only those still gets one;
    * it adopts an existing `general` slug in the root org rather than
      inserting a second one;
    * a concurrent insert loses on the space slug's unique index and is
      reported as `:exists`.

  `run_at_boot/0` is the supervised entry point (see `Platform.Application`):
  it never raises, so it can never crash-loop the tree.
  """

  import Ecto.Query

  require Logger

  alias Platform.Chat
  alias Platform.Chat.Space
  alias Platform.Repo
  alias Platform.Tenancy

  @name "General"
  @slug "general"

  @doc """
  Create `#general` if this install has no channel. Returns `{:ok, space}`
  when it created one, `:exists` when nothing was needed, or
  `{:error, reason}` (e.g. `:no_root_org` before the org seed has run).
  """
  @spec ensure() :: {:ok, Space.t()} | :exists | {:error, term()}
  def ensure do
    if channels?(), do: :exists, else: create_in_root(Tenancy.get_root_org())
  end

  defp create_in_root(nil), do: {:error, :no_root_org}

  defp create_in_root(root) do
    case Chat.create_space(%{name: @name, slug: @slug, kind: "channel", org_id: root.id}) do
      {:ok, space} -> {:ok, space}
      {:error, %Ecto.Changeset{} = cs} -> if channels?(), do: :exists, else: {:error, cs}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "`ensure/0` for the boot task: logs and returns `:ok`, never raises."
  @spec run_at_boot() :: :ok
  def run_at_boot do
    case ensure() do
      {:ok, space} -> Logger.info("[DefaultSpace] created ##{space.slug} on a fresh install")
      :exists -> :ok
      {:error, reason} -> Logger.warning("[DefaultSpace] not seeded: #{inspect(reason)}")
    end

    :ok
  rescue
    error ->
      Logger.warning("[DefaultSpace] not seeded: #{Exception.message(error)}")
      :ok
  end

  defp channels? do
    Repo.exists?(from(s in Space, where: s.kind == "channel"))
  end
end
