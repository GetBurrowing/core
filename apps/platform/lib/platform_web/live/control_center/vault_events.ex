defmodule PlatformWeb.ControlCenter.VaultEvents do
  @moduledoc """
  The Control Center's write path into `Platform.Vault` — the front door that
  did not exist.

  Until this module, `Platform.Vault` was complete (`put/4`, `rotate/3`,
  `get/2`, `delete/2`, Cloak-encrypted, with grants and an access log) and
  entirely unreachable from a browser except as a side effect of onboarding an
  external agent (`PlatformWeb.ControlCenter.OnboardingEvents.persist_credential/2`,
  which calls `Vault.put_inline/2` only when you are also creating an agent).
  Adding a standalone provider key meant an `iex` session on a production host.
  A sanctioned path nobody can walk is how secrets end up pasted into chat
  messages, which are permanent rows every participant and every agent reading
  scrollback can see.

  ## The secret is write-only, and never enters socket assigns

  The submitted secret is read out of the event params, handed to the vault,
  and dropped. It is never assigned, so it cannot reach a template, a LiveView
  diff, a flash, or a crash dump — the absence is structural rather than a
  discipline about which `value=` attributes we remember to omit.

  `retain/1` is the enforcement point: everything that survives a failed submit
  goes through it, and it drops `"secret"`. Note that the vault's own error
  path is a leak vector this has to defend against — `Vault.put/4` returns
  `{:error, %Ecto.Changeset{}}` on a duplicate slug and that changeset carries
  the plaintext in `changes.encrypted_data`. So the changeset is never assigned
  and never rendered; only a hand-written message derived from
  `changeset.errors` (field names and messages, never values) reaches the page.

  ## Reads are member-visible, writes are admin-only, checked server-side

  `/control/:agent_slug` sits in `live_session :authenticated`, so any member
  reads the vault panel — deliberately, it is metadata only. Both handlers here
  re-check `@fabrikam_admin?` themselves before touching `Platform.Vault`. Hiding
  the form is an affordance; a forged event from a non-admin client costs
  nothing to send and is refused by this code, not by the template. Same shape
  as `PlatformWeb.ExperimentsLive`, which the router points at
  (`router.ex`, the comment above `live("/control/experiments", ...)`) as the
  pattern for "anyone may read, admins may write" inside one `live_session`.

  ## Platform scope only

  The form writes `{:platform, nil}` credentials and nothing else. That is not
  a simplification, it is what the vault's authorization model permits: for an
  agent-scoped credential `Platform.Vault`'s `check_access/3` grants `:rotate`
  only to `{:agent, scope_id}` itself or to an explicit `AccessGrant`, and a
  human admin arrives as `{:platform, user_id}`, which falls to the cross-type
  clause and is denied. `put/4` performs no access check at all, so an
  agent-scoped create WOULD succeed — and then could never be rotated from
  here. Offering a create whose rotate is structurally impossible is a trap, so
  the surface stops at the scope it can actually maintain.

  ## Rotate, not delete-then-put

  Replacing a value goes through `Vault.rotate/3`, which updates the row in
  place. The credential keeps its id, so its `Platform.Vault.AccessGrant` rows
  keep pointing at it and `access_log/2` stays continuous, and a `"rotate"`
  entry is appended. `delete/2` then `put/4` would instead `Repo.delete_all`
  every grant (`do_delete/3` does this explicitly, and the DB cascades anyway),
  null out `credential_id` on every retained log row, and mint a new id — the
  same secret, with its authorizations silently revoked and its history
  detached.
  """

  import Phoenix.LiveView, only: [put_flash: 3]
  import Phoenix.Component, only: [assign: 3]

  alias Platform.Vault

  @credential_types ~w(api_key oauth2 token keypair custom)

  @doc "Valid `credential_type` values, straight from `Platform.Vault.Credential`."
  def credential_types, do: @credential_types

  @doc "Blank form params. Contains no `\"secret\"` key — see the moduledoc."
  def blank_form do
    %{
      "slug" => "",
      "name" => "",
      "credential_type" => "api_key",
      "provider" => "",
      "expires_at" => ""
    }
  end

  @doc """
  Handle a Control Center vault event.

  `"toggle_credential_form"` reveals/hides the form; `"create_credential"`
  creates or replaces a platform-scoped credential.
  """
  def handle("toggle_credential_form", _params, socket) do
    admin_only(socket, fn ->
      {:noreply,
       socket
       |> assign(:show_credential_form, !socket.assigns[:show_credential_form])
       |> assign(:credential_form, blank_form())}
    end)
  end

  def handle("create_credential", params, socket) do
    admin_only(socket, fn -> submit(socket, params) end)
  end

  def handle(_event, _params, socket), do: {:noreply, socket}

  # ── The gate ────────────────────────────────────────────────────────────────
  #
  # `fun` is not evaluated at all unless the acting user is a Fabrikam admin, so a
  # refused write cannot have reached Platform.Vault first.
  defp admin_only(socket, fun) do
    if socket.assigns[:fabrikam_admin?] do
      fun.()
    else
      {:noreply, put_flash(socket, :error, "Only Fabrikam admins can change vault credentials.")}
    end
  end

  defp submit(socket, params) do
    slug = params |> Map.get("slug", "") |> to_string() |> String.trim()
    secret = Map.get(params, "secret", "")

    cond do
      slug == "" ->
        {:noreply, reject(socket, params, "A slug is required.")}

      not is_binary(secret) or String.trim(secret) == "" ->
        {:noreply, reject(socket, params, "A secret is required.")}

      true ->
        write(socket, slug, secret, params)
    end
  end

  # `Vault.rotate/3` resolves its target with `lookup_by_slug/2`, which matches
  # on slug ALONE with `limit: 1` and no `order_by` — the vault's uniqueness
  # constraint is per-scope (`vault_credentials_unique_slug_per_scope`), so one
  # slug can legitimately exist at two scopes and which row rotate picks is not
  # determined. Refusing the ambiguous case is the only way this form can
  # promise which credential it just overwrote.
  defp write(socket, slug, secret, params) do
    case Enum.filter(Vault.list([]), &(&1.slug == slug)) do
      [] ->
        create(socket, slug, secret, params)

      [%{scope_type: "platform"}] ->
        replace(socket, slug, secret)

      [%{scope_type: scope_type}] ->
        {:noreply,
         reject(
           socket,
           params,
           "#{slug} already exists at #{scope_type} scope. This form manages platform-scoped credentials only."
         )}

      matches ->
        scopes = matches |> Enum.map(& &1.scope_type) |> Enum.sort() |> Enum.join(", ")

        {:noreply,
         reject(
           socket,
           params,
           "#{slug} exists at more than one scope (#{scopes}). Refusing rather than guessing which one to replace."
         )}
    end
  end

  defp create(socket, slug, secret, params) do
    name = params |> Map.get("name", "") |> to_string() |> String.trim()
    provider = params |> Map.get("provider", "") |> to_string() |> String.trim()

    opts =
      [
        scope: {:platform, nil},
        name: if(name == "", do: slug, else: name),
        provider: if(provider == "", do: nil, else: provider)
      ] ++ expires_at_opt(params)

    case Vault.put(slug, credential_type(params), secret, opts) do
      {:ok, _credential} ->
        {:noreply,
         socket
         |> assign(:show_credential_form, false)
         |> assign(:credential_form, blank_form())
         |> put_flash(:info, "Created platform credential #{slug}.")}

      # The changeset holds the plaintext under `changes.encrypted_data`. Only
      # `changeset_message/1`'s derived string — field names and validation
      # messages — is allowed anywhere near the socket.
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, reject(socket, params, changeset_message(changeset))}
    end
  end

  defp replace(socket, slug, secret) do
    accessor = {:platform, socket.assigns[:current_user_id]}

    case Vault.rotate(slug, secret, accessor: accessor) do
      {:ok, _credential} ->
        {:noreply,
         socket
         |> assign(:show_credential_form, false)
         |> assign(:credential_form, blank_form())
         |> put_flash(
           :info,
           "Replaced the value of #{slug}. Access grants and history preserved."
         )}

      {:error, :access_denied} ->
        {:noreply, put_flash(socket, :error, "The vault refused that rotation.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "#{slug} no longer exists.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not replace #{slug}.")}
    end
  end

  defp credential_type(params) do
    case params |> Map.get("credential_type", "") |> to_string() do
      type when type in @credential_types -> type
      _ -> "api_key"
    end
  end

  # `expires_at` is `:utc_datetime_usec`; the input is a plain date. An
  # unparseable or blank value contributes no option at all rather than a nil
  # one, so `put/4`'s own default is what applies.
  defp expires_at_opt(params) do
    case params |> Map.get("expires_at", "") |> to_string() |> String.trim() do
      "" ->
        []

      date_string ->
        case Date.from_iso8601(date_string) do
          {:ok, date} -> [expires_at: DateTime.new!(date, ~T[23:59:59.999999], "Etc/UTC")]
          {:error, _} -> []
        end
    end
  end

  # Re-render the form with what the admin typed, MINUS the secret, and say why.
  defp reject(socket, params, message) do
    socket
    |> assign(:show_credential_form, true)
    |> assign(:credential_form, retain(params))
    |> put_flash(:error, message)
  end

  # The one place form state is carried across a render. `"secret"` is dropped
  # here, which is why it can never be assigned: a re-typed secret is the price
  # of never holding one in memory longer than the write that consumes it.
  defp retain(params) do
    blank_form()
    |> Map.merge(Map.take(params, Map.keys(blank_form())))
    |> Map.delete("secret")
  end

  defp changeset_message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end
end
