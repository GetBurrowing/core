defmodule PlatformWeb.AdminVaultLive do
  @moduledoc """
  `/admin/vault` — where an install admin hands a secret to specific agents
  (task 01a131c5 stage 2). The context is `Platform.Vault.Shared`; every
  secret here is `scope_type: "shared"`, readable only through an explicit
  `use` grant, and agents fetch it with `vault_fetch` without the value
  entering chat.

  ## The value is write-only and never enters socket state

  Same discipline as `PlatformWeb.ControlCenter.VaultEvents`. The submitted
  value is read out of the event params, handed to `Shared.create/3` or
  `Shared.rotate/3`, and dropped. It is never assigned, so it cannot reach a
  template, a LiveView diff, a flash or a crash dump.

    * The value input is a plain `<input type="password" name="secret[value]">`
      with no `value=` attribute.
    * `retain/1` is the only path by which submitted form state survives a
      render, and it keeps `"slug"` and `"note"` and nothing else.
    * The agent search is its OWN form, so its `phx-change` never carries the
      value. Its handler takes only `"q"` regardless.
    * The editable fields sit inside a `phx-update="ignore"` container whose
      DOM id carries `@form_nonce`. Searching agents re-renders the page
      without the server ever knowing the typed value, and the ignore keeps
      the browser from wiping it. A failed submit bumps the nonce, so the
      container is replaced and the value field comes back empty.
    * The show toggle is client-side `JS.toggle_attribute` and is rendered
      only while a value input exists. After save or rotate the input is
      gone, replaced by the sealed fingerprint stub.

  ## Authorization — defence in depth

  The route sits in the `:admin` live_session (`:ensure_admin`), AND every
  `Shared.*` call receives `@current_user_record`, which `Shared` re-checks
  with `Platform.Tenancy.root_admin?/1`. A forged event from a session whose
  admin role was revoked after mount is refused by `Shared`, not by this
  module.
  """
  use PlatformWeb, :live_view

  alias Platform.Chat
  alias Platform.Vault.Shared

  @impl true
  def mount(_params, _session, socket) do
    agents = Chat.list_agents_for_picker()

    {:ok,
     socket
     |> assign(:page_title, "Vault")
     |> assign(:agents, agents)
     |> assign(:agent_names, Map.new(agents, &{&1.id, &1.name}))
     |> assign(:secrets, [])
     |> assign(:secret, nil)
     |> assign(:access_log, [])
     |> assign(:show_add, false)
     |> assign(:rotating, false)
     |> assign(:confirm_revoke, false)
     |> assign(:picker_open, false)
     |> assign(:form_nonce, 0)
     |> assign_blank_add()}
  end

  @impl true
  def handle_params(%{"slug" => slug}, _url, %{assigns: %{live_action: :show}} = socket) do
    socket =
      socket |> load_secrets() |> assign(:rotating, false) |> assign(:confirm_revoke, false)

    case Enum.find(socket.assigns.secrets, &(&1.slug == slug)) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "That secret does not exist.")
         |> push_navigate(to: ~p"/admin/vault")}

      secret ->
        {:noreply,
         socket
         |> assign(:secret, secret)
         |> assign(:page_title, "Vault · #{secret.slug}")
         |> assign(:picker_open, false)
         |> assign(:search, "")
         |> load_access_log()}
    end
  end

  def handle_params(_params, _url, socket) do
    {:noreply,
     socket
     |> assign(:secret, nil)
     |> assign(:page_title, "Vault")
     |> load_secrets()}
  end

  # ── Add ───────────────────────────────────────────────────────────────

  @impl true
  def handle_event("open_add", _params, socket) do
    {:noreply, socket |> assign_blank_add() |> assign(:show_add, true) |> bump_nonce()}
  end

  def handle_event("close_add", _params, socket) do
    {:noreply, assign(socket, :show_add, false)}
  end

  # The agent search form carries only `q`. Anything else in the params —
  # including a `"value"` a crafted client might add — is ignored.
  def handle_event("agent_search", params, socket) do
    {:noreply, assign(socket, :search, search_term(params))}
  end

  def handle_event("pick_agent", %{"id" => id}, socket) do
    ids = socket.assigns.add_agent_ids
    ids = if id in ids, do: ids, else: ids ++ [id]
    {:noreply, socket |> assign(:add_agent_ids, ids) |> assign(:search, "")}
  end

  def handle_event("unpick_agent", %{"id" => id}, socket) do
    {:noreply, assign(socket, :add_agent_ids, List.delete(socket.assigns.add_agent_ids, id))}
  end

  def handle_event("save", %{"secret" => params}, socket) when is_map(params) do
    actor = socket.assigns[:current_user_record]

    attrs = %{
      slug: String.trim(params["slug"] || ""),
      value: params["value"],
      note: String.trim(params["note"] || "")
    }

    case Shared.create(actor, attrs, socket.assigns.add_agent_ids) do
      {:ok, summary} ->
        {:noreply,
         socket
         |> assign(:show_add, false)
         |> assign_blank_add()
         |> put_flash(:info, "Secret saved.")
         |> push_patch(to: ~p"/admin/vault/#{summary.slug}")}

      {:error, reason} ->
        {:noreply, reject_add(socket, params, error_message(reason))}
    end
  end

  def handle_event("save", _params, socket) do
    {:noreply, reject_add(socket, %{}, error_message(:value_required))}
  end

  # ── Detail ────────────────────────────────────────────────────────────

  def handle_event("start_rotate", _params, socket) do
    {:noreply, socket |> assign(:rotating, true) |> bump_nonce()}
  end

  def handle_event("cancel_rotate", _params, socket) do
    {:noreply, assign(socket, :rotating, false)}
  end

  def handle_event("rotate", params, %{assigns: %{secret: %{slug: slug}}} = socket) do
    value = get_in(params, ["secret", "value"])

    case Shared.rotate(socket.assigns[:current_user_record], slug, value) do
      {:ok, _summary} ->
        {:noreply,
         socket
         |> assign(:rotating, false)
         |> put_flash(
           :info,
           "Secret rotated. Every granted agent's next fetch gets the new value."
         )
         |> reload_secret()}

      {:error, reason} ->
        {:noreply,
         socket
         |> bump_nonce()
         |> put_flash(:error, error_message(reason))}
    end
  end

  def handle_event("toggle_picker", _params, socket) do
    {:noreply, socket |> assign(:picker_open, !socket.assigns.picker_open) |> assign(:search, "")}
  end

  def handle_event("grant", %{"id" => id}, %{assigns: %{secret: secret}} = socket)
      when not is_nil(secret) do
    ids = secret.granted_agent_ids
    ids = if id in ids, do: ids, else: ids ++ [id]
    {:noreply, socket |> assign(:search, "") |> write_grants(ids, "Agent granted.")}
  end

  def handle_event("ungrant", %{"id" => id}, %{assigns: %{secret: secret}} = socket)
      when not is_nil(secret) do
    {:noreply, write_grants(socket, List.delete(secret.granted_agent_ids, id), "Grant removed.")}
  end

  def handle_event("ask_revoke", _params, socket) do
    {:noreply, assign(socket, :confirm_revoke, true)}
  end

  def handle_event("cancel_revoke", _params, socket) do
    {:noreply, assign(socket, :confirm_revoke, false)}
  end

  def handle_event("revoke", _params, %{assigns: %{secret: %{slug: slug}}} = socket) do
    case Shared.revoke(socket.assigns[:current_user_record], slug) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Secret #{slug} revoked.")
         |> push_patch(to: ~p"/admin/vault")}

      {:error, reason} ->
        {:noreply,
         socket |> assign(:confirm_revoke, false) |> put_flash(:error, error_message(reason))}
    end
  end

  def handle_event(event, _params, socket)
      when event in ~w(rotate grant ungrant revoke) do
    {:noreply, put_flash(socket, :error, "Open a secret first.")}
  end

  # ── Private ───────────────────────────────────────────────────────────

  defp write_grants(socket, ids, ok_message) do
    case Shared.set_grants(socket.assigns[:current_user_record], socket.assigns.secret.id, ids) do
      :ok ->
        socket |> put_flash(:info, ok_message) |> reload_secret()

      {:error, reason} ->
        put_flash(socket, :error, error_message(reason))
    end
  end

  defp reload_secret(socket) do
    slug = socket.assigns.secret.slug
    socket = load_secrets(socket)

    case Enum.find(socket.assigns.secrets, &(&1.slug == slug)) do
      nil -> socket
      secret -> socket |> assign(:secret, secret) |> load_access_log()
    end
  end

  defp load_secrets(socket) do
    case Shared.list(socket.assigns[:current_user_record]) do
      {:ok, secrets} -> assign(socket, :secrets, secrets)
      {:error, _} -> assign(socket, :secrets, [])
    end
  end

  defp load_access_log(socket) do
    case Shared.access_log(socket.assigns[:current_user_record], socket.assigns.secret.slug) do
      {:ok, rows} -> assign(socket, :access_log, rows)
      {:error, _} -> assign(socket, :access_log, [])
    end
  end

  defp assign_blank_add(socket) do
    socket
    |> assign(:add_form, %{"slug" => "", "note" => ""})
    |> assign(:add_agent_ids, [])
    |> assign(:add_error, nil)
    |> assign(:search, "")
  end

  # Re-render the add form with what the admin typed, MINUS the value, and
  # say why. A new nonce replaces the ignored field container, so the value
  # input the browser holds is discarded and comes back empty.
  defp reject_add(socket, params, message) do
    socket
    |> assign(:show_add, true)
    |> assign(:add_form, retain(params))
    |> assign(:add_error, message)
    |> bump_nonce()
  end

  # The one place submitted form state is carried across a render.
  defp retain(params) when is_map(params) do
    %{
      "slug" => to_string(Map.get(params, "slug", "")),
      "note" => to_string(Map.get(params, "note", ""))
    }
  end

  defp bump_nonce(socket), do: assign(socket, :form_nonce, socket.assigns.form_nonce + 1)

  defp search_term(%{"q" => q}) when is_binary(q), do: String.trim(q)
  defp search_term(_), do: ""

  defp error_message(:slug_taken), do: "A secret with this name already exists."

  defp error_message(:invalid_slug),
    do:
      "Names are lowercase letters, digits, dot, dash or underscore, starting with a letter or digit (64 max)."

  defp error_message(:value_required), do: "Paste the secret value."
  defp error_message(:unauthorized), do: "Only an install admin can change the vault."
  defp error_message(:not_found), do: "That secret no longer exists."
  defp error_message(:unknown_agent), do: "One of the selected agents no longer exists."
  defp error_message({:invalid, messages}) when is_list(messages), do: Enum.join(messages, "; ")
  defp error_message(_), do: "The secret could not be saved."

  # ── Components ────────────────────────────────────────────────────────

  attr(:secret, :map, required: true)

  # The signature element: once saved, the value field is REPLACED by a fixed
  # stub (fingerprint + date), never masked. Nothing behind it is retrievable.
  defp sealed_value(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-2">
      <div
        class="min-w-0 flex-1 rounded-lg border border-edge bg-base-200 px-3 py-2 font-mono text-sm text-base-content shadow-inner"
        data-role="vault-sealed-value"
      >
        <span class="text-neutral">saved</span>
        <span class="ml-2" data-role="vault-fingerprint">{@secret.fingerprint}</span>
        <span class="ml-2 text-neutral">{stamp(sealed_at(@secret))}</span>
      </div>
      <button
        type="button"
        class="btn btn-ghost btn-sm"
        phx-click="start_rotate"
        data-role="vault-rotate"
      >
        <span class="hero-arrow-path size-4"></span> Rotate
      </button>
    </div>
    <p class="mt-1 text-xs text-neutral">
      This value will not be shown again. Agents report the same fingerprint from vault_fetch.
    </p>
    """
  end

  attr(:id, :string, required: true)
  attr(:agents, :list, required: true)
  attr(:search, :string, default: "")
  attr(:event, :string, required: true)

  # Its own form, so its phx-change can never carry a secret value.
  defp agent_picker(assigns) do
    ~H"""
    <div class="rounded-lg border border-edge bg-base-100" data-role="vault-agent-picker">
      <form id={@id} phx-change="agent_search" phx-submit="agent_search" class="p-2">
        <input
          type="search"
          name="q"
          value={@search}
          placeholder="Search agents"
          autocomplete="off"
          phx-debounce="150"
          class="input input-bordered input-sm w-full"
        />
      </form>
      <ul class="max-h-56 overflow-y-auto pb-1">
        <li :for={agent <- @agents}>
          <button
            type="button"
            phx-click={@event}
            phx-value-id={agent.id}
            class="flex w-full items-center gap-2 px-3 py-2 text-left text-sm hover:bg-base-200"
            data-role="vault-agent-option"
            data-agent-id={agent.id}
          >
            <span class="hero-plus size-4 text-neutral"></span>
            <span class="truncate">{agent.name}</span>
            <span class="ml-auto shrink-0 font-mono text-xs text-neutral">{agent.slug}</span>
          </button>
        </li>
        <li :if={@agents == []} class="px-3 py-2 text-sm text-neutral">No matching agents.</li>
      </ul>
    </div>
    """
  end

  # ── Template helpers ──────────────────────────────────────────────────

  @doc false
  def agent_name(names, id), do: Map.get(names, id, "inactive agent")

  @doc false
  def granted_summary(_names, []), do: nil

  def granted_summary(names, ids) do
    shown = ids |> Enum.take(2) |> Enum.map(&agent_name(names, &1)) |> Enum.join(", ")
    extra = length(ids) - 2
    if extra > 0, do: "#{shown} +#{extra}", else: shown
  end

  @doc false
  def matching_agents(agents, exclude_ids, search) do
    q = String.downcase(search || "")

    agents
    |> Enum.reject(&(&1.id in exclude_ids))
    |> Enum.filter(fn a ->
      q == "" or String.contains?(String.downcase(a.name || ""), q) or
        String.contains?(String.downcase(a.slug || ""), q)
    end)
    |> Enum.take(8)
  end

  @doc false
  def short_date(nil), do: "never"
  def short_date(%DateTime{} = dt), do: Calendar.strftime(dt, "%d %b")
  def short_date(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%d %b")

  @doc false
  def stamp(nil), do: ""
  def stamp(%DateTime{} = dt), do: Calendar.strftime(dt, "%d %b %H:%M")
  def stamp(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%d %b %H:%M")

  @doc false
  def log_stamp(%{inserted_at: dt}), do: Calendar.strftime(dt, "%d %b %H:%M:%SZ")

  @doc false
  def relative(nil), do: "never"

  def relative(%DateTime{} = dt) do
    secs = DateTime.diff(DateTime.utc_now(), dt)

    cond do
      secs < 60 -> "just now"
      secs < 3600 -> "#{div(secs, 60)}m ago"
      secs < 86_400 -> "#{div(secs, 3600)}h ago"
      true -> "#{div(secs, 86_400)}d ago"
    end
  end

  def relative(%NaiveDateTime{} = dt), do: relative(DateTime.from_naive!(dt, "Etc/UTC"))

  @doc false
  def refused_label(1), do: "1 refused fetch (7d)"
  def refused_label(n), do: "#{n} refused fetches (7d)"

  @doc false
  def sealed_at(secret), do: secret.rotated_at || secret.inserted_at

  @doc false
  def log_actor(names, %{accessor_type: "agent", accessor_id: id}), do: agent_name(names, id)
  def log_actor(_names, %{accessor_type: type}) when type in ["platform", "user"], do: "admin"
  def log_actor(_names, %{accessor_type: type}), do: type || "unknown"

  @doc false
  def log_action(names, %{action: action, metadata: meta}) do
    meta = meta || %{}

    case {action, meta} do
      {"use", _} ->
        "fetched"

      {"read", %{"via" => "ticket_issued"}} ->
        "fetch URL issued"

      {"denied", _} ->
        "fetch"

      {"update", %{"grant" => "added", "agent_id" => id}} ->
        "granted #{agent_name(names, id)}"

      {"update", %{"grant" => "removed", "agent_id" => id}} ->
        "ungranted #{agent_name(names, id)}"

      {"create", _} ->
        "created"

      {"rotate", _} ->
        "rotated"

      {"revoke", _} ->
        "revoked"

      {other, _} ->
        other
    end
  end

  @doc false
  def log_outcome(%{action: "denied"}), do: "refused: not granted"
  def log_outcome(_), do: "ok"

  @doc false
  def log_fingerprint(%{metadata: meta}) when is_map(meta), do: meta["fingerprint"]
  def log_fingerprint(_), do: nil

  @doc false
  def revoke_message(names, secret) do
    case Enum.map(secret.granted_agent_ids, &agent_name(names, &1)) do
      [] -> "No agent holds a grant on #{secret.slug}. Revoking destroys it."
      [one] -> "#{one} will lose access to #{secret.slug}."
      many -> "#{join_names(many)} will lose access to #{secret.slug}."
    end
  end

  defp join_names(names) do
    {init, [last]} = Enum.split(names, -1)
    Enum.join(init, ", ") <> " and " <> last
  end
end
