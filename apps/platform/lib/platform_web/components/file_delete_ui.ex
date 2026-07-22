defmodule PlatformWeb.Components.FileDeleteUI do
  @moduledoc """
  Delete affordance + undo toast for the Files surface (task 019f7cb0
  stage 5).

  Two pieces that work together on `PlatformWeb.FilesLive`:

    * `delete_file_button/1` — the persistent ghost + `error` Delete
      control that lives in the file-detail action row (desktop aside
      AND mobile drawer — never on table rows, which stay data-only).
      When the viewer cannot delete it renders disabled-but-visible:
      `opacity-50` + `aria-disabled` + tooltip, never hidden (persistent
      controls over reveal, locked design direction).

    * `file_undo_toast/1` — the signature element. Delete is optimistic
      with NO confirm dialog (ratified: undo over consent); the toast IS
      the confirmation. Inverted `--color-neutral` fill, `elev-3`
      (toast shadow per foundations §7), filename in `body` type, the
      Undo action in `--color-primary` small-strong. Bottom-anchored
      above the mobile bottom nav via the canonical
      `safe-area + --bottom-nav-height` calc (foundations §8.2).

  ## Events the host LiveView must handle

    * `"delete_file"` — `%{"id" => file_id}`; soft-delete via
      `Platform.Files.delete_file/2`, drop the row optimistically, show
      the toast.
    * `"undo_delete"` — restore via `Platform.Files.restore_file/2` and
      reinsert the row.

  Render the toast as a TOP-LEVEL sibling, never inside an `:if`
  wrapper — pinned chrome nested in a conditional region remounts when
  the region toggles.
  """

  use Phoenix.Component

  alias Platform.Files

  @doc """
  Persistent Delete button for the file-detail action row.

  `can_delete` reflects the page's authorization for mutating actions —
  for Files that is actor presence (`current_user_id` in session; the
  route is already behind RequireAuth, so this is a defensive rail, not
  a role gate). The button stays rendered either way; the disabled
  state is visible + explained, and the host's `"delete_file"` handler
  re-checks before acting (aria-disabled does not block clicks).
  """
  attr :file, Files.File, required: true
  attr :can_delete, :boolean, required: true
  attr :id, :string, required: true

  attr :data_role, :string,
    default: "files-detail-delete",
    doc: "e2e selector; the mobile drawer instance overrides for uniqueness."

  attr :class, :string, default: nil, doc: "extra classes (mobile adds min-h-11 hit area)."

  def delete_file_button(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      phx-click="delete_file"
      phx-value-id={@file.id}
      class={[
        "btn btn-ghost btn-sm shrink-0 text-error active:bg-error active:text-error-content",
        @class,
        !@can_delete && "opacity-50"
      ]}
      aria-disabled={if !@can_delete, do: "true"}
      title={if !@can_delete, do: "Sign in to delete files"}
      data-role={@data_role}
    >
      <span class="hero-trash size-4"></span> Delete
    </button>
    """
  end

  @doc """
  Undo toast shown after an optimistic file delete.

  `toast` is `nil` (hidden) or `%{name: display_name}` (shown) — the
  host keeps the deleted row + timer in its own state; this component
  only renders. `role="status"` + `aria-live="polite"` announce the
  deletion without stealing focus during the ~8s undo window.
  """
  attr :toast, :map,
    default: nil,
    doc: "nil when hidden; %{name: display_name} (extra keys ignored) when shown."

  def file_undo_toast(assigns) do
    ~H"""
    <div
      :if={@toast}
      id="files-undo-toast"
      data-role="files-undo-toast"
      role="status"
      aria-live="polite"
      class="fixed inset-x-0 bottom-[calc(env(safe-area-inset-bottom)+1.5rem+var(--bottom-nav-height,0px))] z-50 mx-auto flex w-fit max-w-[calc(100vw-2rem)] items-center gap-4 rounded-box bg-neutral px-4 py-3 text-neutral-content shadow-md"
    >
      <p class="min-w-0 truncate text-base">{@toast.name} deleted</p>
      <button
        type="button"
        phx-click="undo_delete"
        class="min-h-11 shrink-0 rounded px-2 text-sm font-medium uppercase tracking-wide text-primary transition-colors hover:bg-neutral-content/10 focus-visible-ring"
        data-role="files-undo-button"
      >
        Undo
      </button>
    </div>
    """
  end
end
