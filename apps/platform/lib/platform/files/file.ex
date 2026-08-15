defmodule Platform.Files.File do
  @moduledoc """
  Ecto schema for the `platform_files` table — the project-scoped document
  store introduced for ADR 0042.

  Mirrors the convention used by `Platform.Tasks.Task` (UUIDv7 PK,
  binary_id FKs, validations in the changeset). The companion context
  module is `Platform.Files`; the storage wrapper is
  `Platform.Files.Storage`.

  ## Required fields

    * `:project_id` — every file lives under a project (ADR 0042).
    * `:content_type`, `:byte_size`, `:storage_key`, `:content_hash` —
      populated by `Platform.Files.Storage` after the bytes land in the
      backing object store.

  ## Optional fields

    * `:org_id` — only set for files that span multiple projects within a
      tenant. Default nil for the common per-project case.
    * `:name` — display label (defaults to `original_filename` when the
      caller doesn't supply one).
    * `:uploaded_by_user_id` — historical only; nilifies on user delete.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  @valid_ingest_statuses ~w(pending ingested failed not_attempted)
  @valid_ingest_intents ~w(attempt human_only)

  schema "platform_files" do
    belongs_to(:project, Platform.Tasks.Project)
    belongs_to(:org, Platform.Tenancy.Org)
    belongs_to(:uploaded_by_user, Platform.Accounts.User, foreign_key: :uploaded_by_user_id)
    has_many(:chunks, Platform.Files.Chunk, foreign_key: :file_id)

    field(:name, :string)
    field(:original_filename, :string)
    field(:content_type, :string)
    field(:byte_size, :integer)
    field(:storage_key, :string)
    field(:content_hash, :string)
    field(:ingest_status, :string, default: "pending")

    # What we *meant* to do with the bytes, as opposed to what happened
    # (`ingest_status`). `"human_only"` files are stored for people and
    # deliberately never indexed for agents (task 019fd02d).
    field(:ingest_intent, :string, default: "attempt")

    # Soft-delete marker (task 019f7cb0 stage 2). Set/cleared exclusively by
    # `Platform.Files.delete_file/2` and `restore_file/2` via a dedicated
    # change — deliberately NOT in `@cast_fields`, so bulk attrs can never
    # flip a row in or out of the deleted state.
    field(:deleted_at, :utc_datetime_usec)

    # Consecutive failed ingest attempts (task 01a0008b stage 1).
    # `ingest_status` holds only the latest outcome, so this is what tells
    # "failed once" from "failed three times". Moved exclusively by
    # `Platform.Files.update_ingest_status/2` — `"failed"` increments,
    # `"ingested"` resets to 0 — and deliberately NOT in `@cast_fields`,
    # for the same reason as `deleted_at` above: bulk attrs from an upload
    # form or an MCP tool must never be able to set a file's failure
    # history.
    field(:ingest_failure_count, :integer, default: 0)

    # Catalog card backlink (task 01a0008c). `card_file_key` is the wiki
    # file_key of this file's card page — `project/<uuid>/page/files/
    # <slug>.md`. Nil means "no card yet", which is what the backfill
    # selects on; a failed LLM pass is deliberately indistinguishable
    # from never-attempted, because the retry strategy IS the backfill.
    field(:card_file_key, :string)
    field(:card_generated_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @cast_fields ~w(
    project_id
    org_id
    uploaded_by_user_id
    name
    original_filename
    content_type
    byte_size
    storage_key
    content_hash
    ingest_status
    ingest_intent
    card_file_key
    card_generated_at
  )a

  @required_fields ~w(project_id content_type byte_size storage_key)a

  @doc "Valid `ingest_status` values, kept in sync with the DB check constraint."
  @spec valid_ingest_statuses() :: [String.t()]
  def valid_ingest_statuses, do: @valid_ingest_statuses

  @doc "Valid `ingest_intent` values, kept in sync with the DB check constraint."
  @spec valid_ingest_intents() :: [String.t()]
  def valid_ingest_intents, do: @valid_ingest_intents

  @doc """
  Changeset for inserting or updating a `Platform.Files.File`.

  Required fields: `:project_id`, `:content_type`, `:byte_size`,
  `:storage_key`. `:content_hash` is required for any row whose
  `ingest_status` is NOT `"pending"` — Stage 3 of the Files MCP adds
  the presigned-upload branch which reserves a row before bytes hit
  the object store, so the hash isn't known at insert time. Once the
  row transitions to `"ingested"` / `"failed"` the hash must be set
  (the DB-level check constraint
  `platform_files_content_hash_required_when_finalized_check` enforces
  the same invariant).

  Foreign-key constraints surface as friendly errors when project, org,
  or user references are missing. Content-hash uniqueness is scoped per
  project — the same bytes uploaded twice in the same project collide;
  the same bytes in two different projects each get their own row.
  """
  def changeset(file, attrs) do
    file
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> validate_content_hash_when_finalized()
    |> validate_number(:byte_size, greater_than_or_equal_to: 0)
    |> validate_inclusion(:ingest_status, @valid_ingest_statuses)
    |> validate_inclusion(:ingest_intent, @valid_ingest_intents)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:org_id)
    |> foreign_key_constraint(:uploaded_by_user_id)
    |> unique_constraint([:content_hash, :project_id],
      name: :platform_files_content_hash_project_id_index,
      message: "already exists in this project"
    )
    |> unique_constraint(:storage_key, message: "must be unique")
    |> check_constraint(:content_hash,
      name: :platform_files_content_hash_required_when_finalized_check,
      message: "is required once ingest_status is not pending"
    )
    |> check_constraint(:ingest_intent,
      name: :platform_files_ingest_intent_check,
      message: "is invalid"
    )
    |> check_constraint(:ingest_status,
      name: :platform_files_not_attempted_requires_human_only_check,
      message: "cannot be not_attempted unless ingest_intent is human_only"
    )
  end

  # Mirrors the DB-level check constraint added in the Stage 3 migration:
  # rows in `ingest_status = "pending"` may have NULL `content_hash`; any
  # other status requires a hash. This runs BEFORE the constraint hits the
  # DB so changeset users see a friendly error.
  defp validate_content_hash_when_finalized(changeset) do
    status =
      get_field(changeset, :ingest_status) || "pending"

    hash = get_field(changeset, :content_hash)

    if status == "pending" or (is_binary(hash) and hash != "") do
      changeset
    else
      add_error(
        changeset,
        :content_hash,
        "is required once ingest_status is not pending"
      )
    end
  end
end
