defmodule Platform.Org.BurrowDocs do
  @moduledoc """
  Seeds the product-owned Burrow Docs into the org wiki as
  `burrow/page/<basename>` rows, on every boot (task 01a10a44 stage 1).

  The corpus is `docs/burrow/*.md` in the product repo. It is read at
  COMPILE time (see `Platform.Org.BurrowDocs.Source`) and embedded in this
  module, so the running release carries exactly the docs it was built with.
  Every file is an `@external_resource`, so editing a doc recompiles this
  module, and `__mix_recompile__?/0` catches a file being added or removed.

  ## Ownership: product-owned, not install-owned

  `Platform.Org.Seeds` is insert-if-missing for install-owned placeholders —
  once a row exists, the install owns it. Burrow pages are the opposite: the
  repo owns them, so `sync/0` overwrites a row whose content drifted and
  deletes a row whose file is gone. Those are opposite policies, which is why
  this is a sibling module and not an extension of `Org.Seeds`.

  This module is the only writer of `burrow/page/*`.

  ## Change-driven

  `sync/0` compares each stored row's `content` with its source file and
  calls the write path only when they differ, so `version` and `updated_at`
  move only when the doc itself changed in a release. (An equal-content
  `upsert_page/3` would not bump `version` either, since Ecto skips an update
  with no changes; what the comparison saves is the rest of the write path:
  the `org_wiki:index` broadcast that re-embeds the page, the telemetry event
  and the link rewrite, on every boot for every doc.) All writes go through `Platform.Org.Wiki.upsert_page/3` and
  `Platform.Org.Wiki.delete_page/2`, which parse frontmatter, maintain
  the links table and broadcast the index event that drives semantic
  indexing.
  """

  import Ecto.Query

  require Logger

  alias Platform.Org.BurrowDocs.Source
  alias Platform.Org.Wiki
  alias Platform.Org.WikiPage
  alias Platform.Repo

  @namespace_prefix "burrow/page/"

  {source_dir, source_files} = Source.resolve!()

  for path <- source_files do
    @external_resource path
  end

  @source_dir source_dir
  @source_files source_files

  @docs Enum.map(source_files, fn path ->
          %{file_key: @namespace_prefix <> Path.basename(path), content: File.read!(path)}
        end)

  # Recompile when the SET of files changes. `@external_resource` covers
  # edits to a file that existed at compile time, but not a new file or a
  # different source directory winning resolution.
  @doc false
  def __mix_recompile__? do
    Source.resolve!() != {@source_dir, @source_files}
  rescue
    _ -> true
  end

  @typedoc "One product doc: its wiki key and its raw file content."
  @type doc :: %{file_key: String.t(), content: String.t()}

  @typedoc "What `sync/0` did."
  @type report :: %{
          inserted: [String.t()],
          updated: [String.t()],
          unchanged: [String.t()],
          deleted: [String.t()],
          failed: [{String.t(), term()}]
        }

  @doc "The `file_key` prefix every Burrow Docs row carries."
  @spec namespace_prefix() :: String.t()
  def namespace_prefix, do: @namespace_prefix

  @doc "The directory the corpus was compiled from."
  @spec source_dir() :: Path.t()
  def source_dir, do: @source_dir

  @doc """
  The compiled corpus: one entry per `docs/burrow/*.md` file, sorted by
  file name, with `file_key` `burrow/page/<basename>` and the file's raw
  content (frontmatter included).
  """
  @spec docs() :: [doc()]
  def docs, do: @docs

  @doc """
  Makes the `burrow/page/*` rows mirror `docs/0`.

    * a doc with no row is inserted;
    * a doc whose row content differs is updated (version + 1);
    * a doc whose row content is equal is left alone, so nothing moves;
    * a `burrow/page/*` row with no doc is deleted.

  Rows are org-level (`workspace_id` nil), belong to the root org, and carry
  `updated_by` nil. Returns `{:error, :no_root_org}` when the install has no
  root org yet. Per-row write failures are collected in `:failed`, not raised.

  `corpus` defaults to `docs/0`; tests pass a fixture corpus so the
  change-driven and prune behaviour can be observed across several docs.
  """
  @spec sync([doc()]) :: {:ok, report()} | {:error, :no_root_org}
  def sync(corpus \\ docs()) do
    case Platform.Tenancy.get_root_org() do
      nil -> {:error, :no_root_org}
      %{id: org_id} -> {:ok, do_sync(corpus, org_id)}
    end
  end

  defp do_sync(corpus, org_id) do
    existing =
      from(p in WikiPage,
        where: is_nil(p.workspace_id) and like(p.file_key, ^(@namespace_prefix <> "%")),
        select: {p.file_key, p.content}
      )
      |> Repo.all()
      |> Map.new()

    report = %{inserted: [], updated: [], unchanged: [], deleted: [], failed: []}

    report =
      Enum.reduce(corpus, report, fn %{file_key: key, content: content}, acc ->
        case Map.fetch(existing, key) do
          {:ok, ^content} -> push(acc, :unchanged, key)
          {:ok, _stale} -> write(acc, :updated, key, content, org_id)
          :error -> write(acc, :inserted, key, content, org_id)
        end
      end)

    doc_keys = MapSet.new(corpus, & &1.file_key)

    existing
    |> Map.keys()
    |> Enum.reject(&MapSet.member?(doc_keys, &1))
    |> Enum.sort()
    |> Enum.reduce(report, fn key, acc ->
      case Wiki.delete_page(key, product_docs: true) do
        {:ok, _} -> push(acc, :deleted, key)
        {:error, reason} -> push(acc, :failed, {key, reason})
      end
    end)
    |> Map.new(fn {k, v} -> {k, Enum.reverse(v)} end)
  end

  defp write(acc, outcome, key, content, org_id) do
    attrs = %{content: content, updated_by: nil, org_id: org_id}

    case Wiki.upsert_page(key, attrs, product_docs: true) do
      {:ok, _page} -> push(acc, outcome, key)
      {:error, reason} -> push(acc, :failed, {key, reason})
    end
  end

  defp push(acc, field, value), do: Map.update!(acc, field, &[value | &1])

  @doc """
  The boot entry point. Wraps `sync/0`, logs the outcome and ALWAYS returns
  `:ok`; it never raises or throws.

  `Platform.Application` runs it as a `restart: :transient` one-shot `Task`.
  A raise there would restart the child, raise again and trip the
  supervisor's restart intensity, taking the application down over a docs
  sync. So every failure here is logged and swallowed.

  `sync_fun` exists for tests.
  """
  @spec run_at_boot((-> {:ok, report()} | {:error, term()})) :: :ok
  def run_at_boot(sync_fun \\ &sync/0) do
    case sync_fun.() do
      {:ok, %{failed: []} = report} ->
        Logger.info(
          "BurrowDocs: synced (inserted=#{length(report.inserted)} " <>
            "updated=#{length(report.updated)} unchanged=#{length(report.unchanged)} " <>
            "deleted=#{length(report.deleted)})"
        )

        :ok

      {:ok, %{failed: failed}} ->
        Logger.error("BurrowDocs: boot sync left rows unsynced: #{inspect(failed)}")
        :ok

      {:error, :no_root_org} ->
        Logger.warning(
          "BurrowDocs: no root org (no org with parent_org_id IS NULL) yet, so there is " <>
            "no org to own burrow/page rows; skipping. The next boot retries."
        )

        :ok

      other ->
        Logger.error("BurrowDocs: boot sync returned #{inspect(other)}; skipping")
        :ok
    end
  rescue
    error ->
      Logger.error(
        "BurrowDocs: boot sync failed, skipping rather than crash-looping the " <>
          "supervisor: " <> Exception.message(error)
      )

      :ok
  catch
    kind, reason ->
      Logger.error(
        "BurrowDocs: boot sync exited (#{inspect(kind)}), skipping rather than " <>
          "crash-looping the supervisor: #{inspect(reason)}"
      )

      :ok
  end
end
