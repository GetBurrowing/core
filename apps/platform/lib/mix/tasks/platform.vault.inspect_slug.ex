defmodule Mix.Tasks.Platform.Vault.InspectSlug do
  @moduledoc """
  Print every `vault_credentials` row for a slug, across every scope.

      mix platform.vault.inspect_slug t3

  ## Why this exists

  Task 019f9cb8 — `Platform.Vault.get/2` and `delete/2` used to resolve a slug
  with `limit(1)` and no `order_by`, so an ambiguous slug silently picked
  whichever row Postgres happened to return first. Stages 1-2 of that task
  fixed the resolution itself: both functions now go through
  `resolve_one_by_slug/2` and refuse with `{:error, :ambiguous_slug}` instead
  of picking a row.

  What was still missing is a way to SEE the ambiguity from outside `iex`,
  against a real database, without writing a one-off query each time. This
  task is that: read-only, reproducible, pasteable into an incident channel.

  ## READ-ONLY — this task decides nothing

  This module never calls `Repo.insert`, `Repo.update`, or `Repo.delete`, and
  never will. It does not compute which row is "the real one" — `scope_type`
  and `scope_id` are independent namespaces by design (see the moduledoc on
  `Platform.Vault`, "Scopes" section), so the same slug can legitimately exist
  at more than one scope simultaneously, and this task has no way to know
  which coexisting row an operator actually wants to keep. It prints every
  matching row, unranked, and stops.

  Deciding which `t3` row (if any) to remove or rename, and executing that
  decision, is Rowan Ellis's call to make against production — not
  something this task infers or automates.

  ## Never prints `encrypted_data`

  Every row is stripped the same way `Platform.Vault`'s own `strip_encrypted/1`
  private helper does it (`%{credential | encrypted_data: nil}`) before this
  task ever touches it, so neither the plaintext value nor the Cloak
  ciphertext blob can appear in this task's output — not even by accident of
  a future `inspect/1` on the struct.
  """

  use Mix.Task

  import Ecto.Query

  alias Platform.Repo
  alias Platform.Vault.Credential

  @shortdoc "Read-only: print every vault_credentials row for a slug, across every scope"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      [slug] when is_binary(slug) and slug != "" ->
        slug
        |> fetch_all()
        |> report()
        |> Enum.each(fn line -> Mix.shell().info(line) end)

      _ ->
        Mix.raise("usage: mix platform.vault.inspect_slug <slug>")
    end
  end

  @doc """
  Fetch every `vault_credentials` row matching `slug`, oldest first, with
  `encrypted_data` stripped. Read-only: a single `Repo.all/1` `SELECT`, no
  mutation of any kind.

  Separated from `run/1` so a test can exercise it without driving
  `OptionParser`/`Mix.shell()`.
  """
  @spec fetch_all(String.t()) :: [Credential.t()]
  def fetch_all(slug) do
    from(c in Credential, where: c.slug == ^slug, order_by: [asc: c.inserted_at])
    |> Repo.all()
    |> Enum.map(&strip_encrypted/1)
  end

  @doc """
  Render the report lines for a set of matching rows.

  Prints a count header, then one block per row with every non-secret field
  the ticket calls for. Never touches `encrypted_data` — the caller has
  already stripped it, and this function does not reintroduce it.
  """
  @spec report([Credential.t()]) :: [String.t()]
  def report([]) do
    ["no vault_credentials row for this slug in this environment."]
  end

  def report(credentials) do
    header = [
      "#{length(credentials)} row(s) matched. Display only — nothing here is ranked " <>
        "or recommended as authoritative."
    ]

    blocks =
      credentials
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {c, i} -> ["", "--- row #{i} ---" | row_lines(c)] end)

    header ++ blocks
  end

  defp row_lines(%Credential{} = c) do
    [
      "id:              #{c.id}",
      "slug:            #{c.slug}",
      "name:            #{inspect(c.name)}",
      "provider:        #{inspect(c.provider)}",
      "credential_type: #{inspect(c.credential_type)}",
      "scope_type:      #{inspect(c.scope_type)}",
      "scope_id:        #{inspect(c.scope_id)}",
      "workspace_id:    #{inspect(c.workspace_id)}",
      "metadata:        #{inspect(c.metadata)}",
      "expires_at:      #{inspect(c.expires_at)}",
      "last_used_at:    #{inspect(c.last_used_at)}",
      "rotated_at:      #{inspect(c.rotated_at)}",
      "inserted_at:     #{inspect(c.inserted_at)}",
      "updated_at:      #{inspect(c.updated_at)}"
    ]
  end

  # Mirrors `Platform.Vault`'s own private `strip_encrypted/1` verbatim — see
  # that module for why this is load-bearing rather than cosmetic.
  defp strip_encrypted(%Credential{} = credential) do
    %{credential | encrypted_data: nil}
  end
end
