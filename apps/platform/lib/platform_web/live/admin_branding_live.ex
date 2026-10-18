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

  An org in Burrow is a CLIENT, not a deployment. One install serves many
  orgs and they all get the same home-screen icon, so branding is an
  install-wide setting behind the root-admin tier — the same
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
      `socket.assigns[:root_admin?]` branch).
    * AND both writes re-check: `Branding.update_identity/2` and
      `Branding.put_source/3` run `Tenancy.root_admin?/1` on the actor we
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

  ## App colours (task 01a0dbee-f598-7001-b450-7890103f44c4 stage 4)

  Three colours per mode (action, surface, optional accent), edited as a
  DRAFT held in `:colors_draft` and saved only on "Save colours". Until then
  the page chrome stays in the saved theme: the draft reaches the paired
  preview only, through `ThemeCss.mode_declarations/2`, the same function the
  root layout's `#install-theme` block is built from, so what the admin
  approves is what the app renders.

    * Each slot has a native colour swatch AND a typeable hex field in one
      form. `validate_colors` reads `_target` to take whichever changed. A
      value that does not parse leaves the last good colour in the draft and
      shows an inline error; a blank value is "Burrow default" (nil).
    * `Palette.checks/2` re-runs on every change. Save is disabled while any
      check blocks, with the reason written beside it. That is convenience:
      `Branding.update_colors/2` re-runs the same checks and refuses, and the
      refusal is rendered if a form bypasses the disabled button.
    * A successful save or reset does a full `redirect/2`, not a
      `push_navigate/2`: the root layout, which carries the install theme,
      only re-renders on a full page load.
  """
  use PlatformWeb, :live_view

  alias Platform.Branding
  alias Platform.Branding.IconSet
  alias Platform.Branding.IconStorage
  alias Platform.Branding.Contrast
  alias Platform.Branding.InstallBranding
  alias Platform.Branding.Palette
  alias Platform.Branding.Presets
  alias Platform.Branding.ThemeCss

  @upload_name :source
  # The source is derived down to 512px at most, so nothing here needs a
  # document's budget. 10 MB comfortably clears a 2048px PNG export.
  @max_file_size 10 * 1024 * 1024

  # The label budget the helper text and the live counter both read. iOS is
  # the tighter of the two platforms; see the moduledoc.
  @label_budget 11

  @modes [:light, :dark]
  @slots [:action, :surface, :accent]
  @save_scope "This changes colours for everyone on this install."

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

  @doc "The Save colours confirmation, one sentence stating the scope."
  @spec save_scope() :: String.t()
  def save_scope, do: @save_scope

  @doc "The colour modes the App colours section edits, in display order."
  @spec modes() :: [:light | :dark]
  def modes, do: @modes

  @doc "The colour slots per mode, in display order."
  @spec slots() :: [:action | :surface | :accent]
  def slots, do: @slots

  @doc "The form field name for one mode's slot, e.g. `\"light_action\"`."
  @spec field(atom(), atom()) :: String.t()
  def field(mode, slot), do: "#{mode}_#{slot}"

  @doc "Human label for a colour slot."
  @spec slot_label(atom()) :: String.t()
  def slot_label(:action), do: "Action"
  def slot_label(:surface), do: "Surface"
  def slot_label(:accent), do: "Accent"

  @doc "Human label for a mode."
  @spec mode_label(atom()) :: String.t()
  def mode_label(:light), do: "Light"
  def mode_label(:dark), do: "Dark"

  @doc """
  The pairing a `Palette.checks/2` entry is about, in words, for the checks
  list under the preview.
  """
  @spec check_label(atom()) :: String.t()
  def check_label(:body_text), do: "Body text on surface"
  def check_label(:button_text), do: "Button text"
  def check_label(:accent_text), do: "Text on accent"
  def check_label(:link_text), do: "Link text on surface"
  def check_label(:action_visibility), do: "Action vs surface"
  def check_label(:focus_ring), do: "Focus ring"

  def check_label(id) do
    case Atom.to_string(id) do
      "collides_with_" <> status -> "Action vs #{status} colour"
      other -> other
    end
  end

  @doc "A contrast ratio as the page prints it (`15.3:1`), floored like Palette's copy."
  @spec format_ratio(float() | nil) :: String.t()
  def format_ratio(nil), do: "hue"

  def format_ratio(ratio),
    do: :erlang.float_to_binary(Float.floor(ratio * 10) / 10, decimals: 1) <> ":1"

  @doc "The chip tone for a check level: pass success, warn warning, block error."
  @spec level_tone(atom()) :: String.t()
  def level_tone(:pass), do: "success"
  def level_tone(:warn), do: "warning"
  def level_tone(:block), do: "error"

  @doc "The word a check level prints as."
  @spec level_word(atom()) :: String.t()
  def level_word(:pass), do: "pass"
  def level_word(:warn), do: "warn"
  def level_word(:block), do: "block"

  @doc """
  The colour a slot actually resolves to for display: the draft value, else
  (accent) the action colour, else the Burrow default. Always `#rrggbb`, so
  it is what a native `<input type="color">` can hold.
  """
  @spec resolved(map(), atom(), atom()) :: String.t()
  def resolved(draft, mode, slot) do
    defaults = Map.fetch!(Palette.suite_defaults(), mode)
    values = Map.fetch!(draft, mode)

    case slot do
      :accent -> values.accent || values.action || defaults.action
      other -> Map.fetch!(values, other) || Map.fetch!(defaults, other)
    end
  end

  @doc "The placeholder a blank hex field shows: the Burrow default, or 'same as action'."
  @spec placeholder(atom(), atom()) :: String.t()
  def placeholder(_mode, :accent), do: "same as action"

  def placeholder(mode, slot),
    do: Palette.suite_defaults() |> Map.fetch!(mode) |> Map.fetch!(slot)

  @doc """
  The inline `style` for a preset card: split diagonally between the preset's
  light and dark surfaces, with each half's action colour available as
  `--swatch-light` / `--swatch-dark`. nil slots (Burrow default) resolve
  through `resolved/3`, so no hex is spelled here.
  """
  @spec preset_style(Presets.t()) :: String.t()
  def preset_style(preset) do
    draft = %{light: preset.light, dark: preset.dark}

    "background:linear-gradient(135deg,#{resolved(draft, :light, :surface)} 50%," <>
      "#{resolved(draft, :dark, :surface)} 50%);" <>
      "--swatch-light:#{resolved(draft, :light, :action)};" <>
      "--swatch-dark:#{resolved(draft, :dark, :action)};"
  end

  @doc "The preview wrapper's inline style for a draft mode: see `ThemeCss.mode_declarations/2`."
  @spec preview_style(map(), atom()) :: String.t() | nil
  def preview_style(draft, mode), do: ThemeCss.mode_declarations(mode, Map.fetch!(draft, mode))

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
    branding = Branding.get()

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Platform.PubSub, Branding.pubsub_topic())
    end

    {:ok,
     socket
     |> assign(:page_title, "Branding")
     |> assign(:upload_error, nil)
     |> assign(:saved?, false)
     |> assign(:colors_preview_mode, :light)
     |> assign_branding(branding)
     |> assign_colors(branding)
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

  def handle_event("match_app_colours", _params, socket) do
    surface = resolved(socket.assigns.colors_draft, :dark, :surface)

    params =
      Map.merge(socket.assigns.form.params || %{}, %{
        "background_color" => surface,
        "theme_color" => surface
      })

    changeset =
      socket.assigns.branding
      |> InstallBranding.identity_changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset, as: :branding))}
  end

  def handle_event("validate_colors", %{"_target" => ["colors", target]} = params, socket) do
    value = get_in(params, ["colors", target])

    case field_for(target) do
      {mode, slot} when is_binary(value) -> {:noreply, put_slot(socket, mode, slot, value)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("validate_colors", _params, socket), do: {:noreply, socket}

  def handle_event("apply_preset", %{"preset" => key}, socket) do
    case Presets.get(key) do
      nil ->
        {:noreply, socket}

      preset ->
        draft = %{light: preset.light, dark: preset.dark}

        {:noreply,
         socket
         |> assign(:colors_preset, preset.key)
         |> assign(:colors_inputs, raw_inputs(draft))
         |> assign(:colors_errors, %{})
         |> assign(:colors_save_errors, [])
         |> assign_draft(draft)}
    end
  end

  def handle_event("preview_mode", %{"mode" => mode}, socket) when mode in ["light", "dark"] do
    {:noreply, assign(socket, :colors_preview_mode, String.to_existing_atom(mode))}
  end

  def handle_event("cancel_colors", _params, socket) do
    {:noreply, assign_colors(socket, socket.assigns.branding)}
  end

  def handle_event("save_colors", _params, socket) do
    draft = socket.assigns.colors_draft

    attrs =
      for mode <- @modes,
          slot <- @slots,
          into: %{"color_preset" => socket.assigns.colors_preset} do
        {field(mode, slot), draft[mode][slot]}
      end

    case Branding.update_colors(actor(socket), attrs) do
      {:ok, %InstallBranding{}} ->
        {:noreply,
         socket
         |> put_flash(:info, "App colours saved.")
         |> redirect(to: ~p"/admin/branding")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :colors_save_errors, changeset_messages(changeset))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have access to that page.")}
    end
  end

  def handle_event("reset_colors", _params, socket) do
    case Branding.reset_colors(actor(socket)) do
      {:ok, %InstallBranding{}} ->
        {:noreply,
         socket
         |> put_flash(:info, "App colours reset to the Burrow default.")
         |> redirect(to: ~p"/admin/branding")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :colors_save_errors, changeset_messages(changeset))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have access to that page.")}
    end
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
    previous = socket.assigns.branding
    fresh = Branding.get()
    socket = assign_branding(socket, fresh)

    # Only a change to the SAVED colours replaces the draft. A name save in
    # this or another window must not discard colours being edited here.
    socket =
      if colours_key(previous) == colours_key(fresh),
        do: socket,
        else: assign_colors(socket, fresh)

    {:noreply, socket}
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

  # ── App colours ───────────────────────────────────────────────

  defp assign_colors(socket, %InstallBranding{} = branding) do
    draft = Branding.app_colors(branding)

    socket
    |> assign(:colors_preset, branding.color_preset)
    |> assign(:colors_inputs, raw_inputs(draft))
    |> assign(:colors_errors, %{})
    |> assign(:colors_save_errors, [])
    |> assign_draft(draft)
  end

  defp assign_draft(socket, draft) do
    checks = Map.new(@modes, &{&1, Palette.checks(&1, Map.fetch!(draft, &1))})

    blocks =
      for mode <- @modes, check <- checks[mode], check.level == :block do
        "#{mode_label(mode)}: #{check.message}"
      end

    socket
    |> assign(:colors_draft, draft)
    |> assign(:colors_checks, checks)
    |> assign(:colors_blocks, blocks)
  end

  # A valid entry is echoed back NORMALISED ('#F55' -> '#ff5555'), so the
  # field says what will be saved; an invalid one is kept RAW beside its error
  # so the admin can see what they typed. LiveView never overwrites a focused
  # input's value, so the HexField hook applies the normalised text on blur
  # (task 01a0dbee-f598-7001-b450-7890103f44c4 stage 5).
  defp put_slot(socket, mode, slot, raw) do
    field = field(mode, slot)

    parsed =
      if String.trim(raw) == "", do: {:ok, nil}, else: Contrast.normalize_hex(raw)

    case parsed do
      {:ok, value} ->
        draft = put_in(socket.assigns.colors_draft, [mode, slot], value)

        socket
        |> assign(:colors_inputs, Map.put(socket.assigns.colors_inputs, field, value || ""))
        |> assign(:colors_errors, Map.delete(socket.assigns.colors_errors, field))
        |> assign(:colors_save_errors, [])
        |> assign_draft(draft)

      :error ->
        socket
        |> assign(:colors_inputs, Map.put(socket.assigns.colors_inputs, field, raw))
        |> assign(
          :colors_errors,
          Map.put(
            socket.assigns.colors_errors,
            field,
            "Not a colour. Use 3 or 6 hex digits, with or without the #."
          )
        )
    end
  end

  # `light_action` or `light_action_swatch` -> {:light, :action}; anything
  # else (a stray field name from a tampered form) -> nil.
  defp field_for(target) do
    name = String.replace_suffix(target, "_swatch", "")

    Enum.find_value(for(m <- @modes, s <- @slots, do: {m, s}), fn {m, s} ->
      field(m, s) == name && {m, s}
    end)
  end

  defp raw_inputs(draft) do
    for mode <- @modes, slot <- @slots, into: %{} do
      {field(mode, slot), draft[mode][slot] || ""}
    end
  end

  defp colours_key(%InstallBranding{} = b), do: {Branding.app_colors(b), b.color_preset}

  defp changeset_messages(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.flat_map(fn {_field, msgs} -> msgs end)
    |> Enum.uniq()
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
