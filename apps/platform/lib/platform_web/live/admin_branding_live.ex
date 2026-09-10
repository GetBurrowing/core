defmodule PlatformWeb.AdminBrandingLive do
  @moduledoc """
  Branding — the admin surface that sets this install's PWA identity
  (task `01a0879a` stage 4).

  Stages 1–3 shipped the read path (`Platform.Branding`), the derivation
  (`Platform.Branding.IconSet`) and the public serving route. Until this
  surface existed none of it was reachable by a human: changing the
  install's icon meant replacing files in `priv/static` and redeploying.
  This is the form that removes the redeploy.

  ## Admin panel, not org settings

  An org in Suite is a CLIENT, not a deployment. One install serves many
  orgs and they all get the same home-screen icon, so branding is an
  install-wide setting behind the Fabrikam-admin tier — the same
  `live_session :admin` gate `/admin/orgs` and `/admin/users` sit behind.
  There is deliberately no branding column on `orgs`.

  ## ONE upload, not seven fields

  The admin uploads a single square. `IconSet.derive/2` produces all seven
  variants from it, so the form never asks for a favicon, an apple-touch
  icon and a maskable Android icon separately. There is exactly ONE
  `live_file_input` on this page — `PlatformWeb.FilesLive` carries a
  standing note that two inputs sharing one upload ref is already at the
  limit of what is maintainable; this surface does not add to that.

  ## Authorization — defence in depth

    * The route is in the `:admin` `live_session`, whose
      `PlatformWeb.LiveAuth.on_mount(:ensure_admin, ...)` hook
      halt-redirects a non-admin mount (`live_auth.ex`, the
      `socket.assigns[:fabrikam_admin?]` branch).
    * AND both writes re-check: `Branding.update_identity/2` and
      `Branding.put_source/3` run `Tenancy.fabrikam_admin?/1` on the actor we
      thread in from `@current_user_record`. Neither check is load-bearing
      alone.

  ## The type check is at consume time, on the FILENAME

  `accept/0` is built from `IconStorage.allowed_content_types/0` so the
  picker filter cannot drift from what the server enforces — but the
  picker is a hint. `Phoenix.LiveView`'s own `accept` validation
  short-circuits on the CLIENT-REPORTED type, so a file named
  `payload.svg` claiming `image/png` clears it. `allowed_entry?/1` below
  resolves the filename instead, which is the check that catches it. This
  mirrors `PlatformWeb.ControlCenter.AgentAvatarUpload` deliberately;
  read its moduledoc before deleting either half as redundant.

  ## The label budget is guidance, NOT validation

  iOS truncates a home-screen label at ~11–12 characters and Android at
  ~12, so "Ellis Suite" renders as "Ellis S…" — the differentiator
  survives only if it comes FIRST. The form shows a live count against 11
  and says so, and then accepts whatever the admin types. Blocking a
  longer name would be wrong: the manifest `name` is also used untruncated
  in the install prompt and the app switcher.
  """
  use PlatformWeb, :live_view

  alias Platform.Branding
  alias Platform.Branding.IconSet
  alias Platform.Branding.IconStorage
  alias Platform.Branding.InstallBranding

  @upload_name :source
  # The source is derived down to 512px at most, so nothing here needs a
  # document's budget. 10 MB comfortably clears a 2048px PNG export.
  @max_file_size 10 * 1024 * 1024

  # The label budget the helper text and the live counter both read. iOS is
  # the tighter of the two platforms; see the moduledoc.
  @label_budget 11

  @doc "The `allow_upload/3` name this surface consumes."
  @spec upload_name() :: atom()
  def upload_name, do: @upload_name

  @doc "Characters a home-screen label can show before the OS truncates."
  @spec label_budget() :: pos_integer()
  def label_budget, do: @label_budget

  @doc """
  The `:accept` list for `allow_upload/3`.

  Built from `IconStorage.allowed_content_types/0` so the picker filter
  cannot drift from the list the server enforces. Both the MIME types and
  their extensions are included: LiveView matches an entry on either, and
  the extension arm keeps an iOS pick labelled `application/octet-stream`
  from being bounced before it reaches the filename check.
  """
  @spec accept() :: [String.t()]
  def accept do
    Enum.flat_map(IconStorage.allowed_content_types(), fn type ->
      [type | Enum.map(MIME.extensions(type), &("." <> &1))]
    end)
  end

  @doc "Human-facing list of accepted formats, from the same allowlist."
  @spec accept_label() :: String.t()
  def accept_label do
    IconStorage.allowed_content_types()
    |> Enum.map(&(&1 |> String.split("/") |> List.last() |> String.upcase()))
    |> Enum.uniq()
    |> Enum.join(", ")
  end

  @doc "Human-facing size ceiling, so helper text cannot drift from it."
  @spec max_file_size_label() :: String.t()
  def max_file_size_label, do: "#{div(@max_file_size, 1024 * 1024)} MB"

  @doc """
  The server-side type check — see the moduledoc.

  An extension MIME cannot recognise resolves to
  `application/octet-stream` and is DEFERRED rather than rejected, because
  `IconStorage.put_source/3` then enforces the reported content type and
  `IconSet.derive/2` refuses anything libvips cannot open. Rejecting here
  would bounce ordinary iOS picks.
  """
  @spec allowed_entry?(map()) :: boolean()
  def allowed_entry?(%{client_name: client_name}) do
    case MIME.from_path(to_string(client_name)) do
      "application/octet-stream" -> true
      inferred -> inferred in IconStorage.allowed_content_types()
    end
  end

  def allowed_entry?(_entry), do: false

  @doc "Maps an `upload_errors/1,2` reason to copy an admin can act on."
  @spec error_message(term()) :: String.t()
  def error_message(:too_large),
    do: "That image is over #{max_file_size_label()}. Export it smaller."

  def error_message(:not_accepted), do: unsupported_message()
  def error_message(:too_many_files), do: "One source image at a time — the newest pick wins."
  def error_message(:external_client_failure), do: "The upload did not finish. Try again."
  def error_message(reason), do: "The upload failed (#{inspect(reason)})."

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Platform.PubSub, Branding.pubsub_topic())
    end

    {:ok,
     socket
     |> assign(:page_title, "Branding")
     |> assign(:upload_error, nil)
     |> assign(:saved?, false)
     |> assign_branding(Branding.get())
     |> allow_upload(@upload_name,
       accept: accept(),
       auto_upload: true,
       max_entries: 1,
       max_file_size: @max_file_size,
       progress: &handle_source_progress/3
     )}
  end

  @impl true
  def handle_params(_params, _url, socket), do: {:noreply, socket}

  @impl true
  def handle_event("validate_identity", %{"branding" => params}, socket) do
    changeset =
      socket.assigns.branding
      |> InstallBranding.identity_changeset(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:form, to_form(changeset, as: :branding))
     |> assign(:app_name_length, name_length(params["app_name"]))}
  end

  def handle_event("save_identity", %{"branding" => params}, socket) do
    case Branding.update_identity(actor(socket), params) do
      {:ok, %InstallBranding{} = branding} ->
        {:noreply,
         socket
         |> assign_branding(branding)
         |> assign(:saved?, true)
         |> put_flash(:info, "Branding saved.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :branding))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have access to that page.")}
    end
  end

  # `auto_upload: true` needs a change handler to exist on the upload form,
  # but there is nothing to validate: the entry drains itself through
  # `handle_source_progress/3`. Clearing the previous error is the whole
  # body — a stale rejection must not sit above a fresh pick.
  def handle_event("validate_source", _params, socket) do
    {:noreply, assign(socket, :upload_error, nil)}
  end

  # An entry the client cancelled, or one the admin drops after a bad pick.
  def handle_event("cancel_source", %{"ref" => ref}, socket) do
    {:noreply,
     socket
     |> cancel_upload(@upload_name, ref)
     |> assign(:upload_error, nil)}
  end

  @impl true
  def handle_info({:install_branding_updated, %InstallBranding{} = branding}, socket) do
    # A save in a second admin window. Re-read rather than rendering the
    # broadcast payload directly — `Branding.get/0` is one primary-key
    # read and is the module's documented single read path. The payload is
    # matched only to prove the message is ours.
    _ = branding
    {:noreply, assign_branding(socket, Branding.get())}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # ── Upload ────────────────────────────────────────────────────

  defp handle_source_progress(@upload_name, entry, socket) do
    if entry.done? do
      {:noreply, consume_source(socket, entry)}
    else
      {:noreply, socket}
    end
  end

  # The entry is consumed either way, so a rejected file does not linger
  # and re-fire on the next change event. A failure BEFORE the commit in
  # `Branding.put_source/3` has written no row, so the previous branding
  # is still committed and still serving — the error path deliberately
  # does not touch `:branding`.
  defp consume_source(socket, entry) do
    outcome =
      consume_uploaded_entry(socket, entry, fn %{path: path} ->
        {:ok, store(path, entry, socket)}
      end)

    case outcome do
      {:ok, %InstallBranding{} = branding} ->
        socket
        |> assign_branding(branding)
        |> assign(:upload_error, nil)
        |> assign(:saved?, true)
        |> put_flash(:info, "Icons derived from your upload.")

      {:error, reason} ->
        assign(socket, :upload_error, upload_error_message(reason))
    end
  end

  defp store(path, entry, socket) do
    if allowed_entry?(entry) do
      Branding.put_source(actor(socket), {:path, path},
        content_type: entry.client_type,
        filename: entry.client_name || "source"
      )
    else
      {:error, {:unsupported_content_type, entry.client_type}}
    end
  end

  defp upload_error_message({:unsupported_content_type, _reported}), do: unsupported_message()
  defp upload_error_message(:unauthorized), do: "You don't have access to that page."
  defp upload_error_message(reason), do: IconSet.error_message(reason)

  defp unsupported_message do
    "That file type is not supported for an install icon. Use #{accept_label()}."
  end

  # ── Assigns ───────────────────────────────────────────────────

  defp assign_branding(socket, %InstallBranding{} = branding) do
    socket
    |> assign(:branding, branding)
    |> assign(:form, to_form(InstallBranding.identity_changeset(branding, %{}), as: :branding))
    |> assign(:app_name_length, name_length(branding.app_name))
    |> assign(:icons, icon_urls())
  end

  # Read through `Branding.icon_url/1` rather than building a path here:
  # that function is the ONE site that knows the served URL shape, and a
  # second speller would drift the moment the version token moves.
  defp icon_urls do
    Map.new(Branding.variants(), fn variant -> {variant, Branding.icon_url(variant)} end)
  end

  defp name_length(name) when is_binary(name), do: String.length(name)
  defp name_length(_), do: 0

  defp actor(socket), do: socket.assigns[:current_user_record]
end
