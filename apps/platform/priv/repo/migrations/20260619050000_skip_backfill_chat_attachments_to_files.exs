defmodule Platform.Repo.Migrations.SkipBackfillChatAttachmentsToFiles do
  @moduledoc """
  Stage 6 of task `019ebd47` — deliberate no-op tombstone.

  The original v3 plan for this stage was a backfill that would copy
  `chat_attachments` rows into `platform_files` by deriving
  `project_id` through `chat_space.metadata.task_id → tasks.project_id`.

  After plan approval Rowan determined that derivation is unsound for
  org-level chat spaces — Fabrikam's General channel can discuss any Fabrikam
  project, so no single `project_id` maps cleanly. The product call:
  `chat_attachments` and `platform_files` remain distinct affordances.

  The forward path for promoting a chat attachment into the Files
  store is a user-driven "Save to Files" action on the chat message,
  which lives in a future task. See canvas
  `019eddc2-6c00-7485-bfca-82e6e0d7cc1d` in execution space
  `019ed660-03bb-7f6d-9d17-43a62f813ea0` for the mock + planned UX.

  This migration ships as a no-op so the plan engine can advance past
  Stage 6 without ghost stages. Running `mix ecto.migrate` is safe.
  """
  use Ecto.Migration

  def change do
    :ok
  end
end
