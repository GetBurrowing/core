defmodule Platform.Social.WebhookPlug do
  @moduledoc """
  The vendor's signed status webhook (task 01a140a9, Social 2/7), served by
  core's generic extension route seam at
  `POST /api/ext/social/webhooks/:profile_id` (`Platform.Social.Extension.routes/0`).
  Each profile has its own webhook URL and secret at the vendor.

  Core gives this plug NO session and NO auth; the signature is the ONLY
  authentication, verified before any post is read:

    1. the profile is loaded by id;
    2. its secret is read from the Vault (`Platform.Social.Secrets.webhook_secret/1`,
       slug `"social:webhook:<profile_id>"`, scope `{:integration, profile_id}`);
    3. `Publisher.impl().verify_webhook/2` checks the signature over the RAW
       body (`conn.assigns[:raw_body]`, cached by core's `CacheBodyReader`).

  An unknown profile, a missing secret and a bad or missing signature all
  answer the SAME 401, so the endpoint does not reveal which profile ids
  exist (architect note on plan 01a140fa). Nothing about posts is read
  before step 3 passes.

  Each verified event is matched by `external_id` among THAT profile's
  accounts only and applied through `Platform.Social.Publishing.apply_outcome/2`,
  which moves only `approved`/`scheduled` posts, so a replayed delivery
  changes nothing. Unknown ids and `:ignored` events are skipped. The reply
  is a quick 200: the vendor retries any non-2xx (Zernio makes up to 7
  attempts, https://docs.zernio.com/webhooks).
  """

  @behaviour Plug

  import Ecto.Query, only: [from: 2]
  import Plug.Conn

  alias Platform.Repo
  alias Platform.Social.{Account, Health, Post, Profile, Publisher, Publishing, Secrets}

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "POST", path_info: ["webhooks", profile_id]} = conn, _opts) do
    with {:ok, profile} <- load_profile(profile_id),
         {:ok, secret} <- Secrets.webhook_secret(profile),
         adapter when is_atom(adapter) <- Publisher.impl(),
         {raw_body, conn} <- raw_body(conn),
         {:ok, events} <-
           adapter.verify_webhook(
             %{raw_body: raw_body, headers: Map.new(conn.req_headers)},
             secret
           ) do
      applied = Enum.count(events, &apply_event(profile, &1))
      reply(conn, 200, %{ok: true, applied: applied})
    else
      _ -> reply(conn, 401, %{error: "unauthorized"})
    end
  end

  def call(conn, _opts), do: reply(conn, 404, %{error: "not_found"})

  defp load_profile(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Profile{} = profile <- Repo.get(Profile, id) do
      {:ok, profile}
    else
      _ -> {:error, :unauthorized}
    end
  end

  # Core's endpoint caches the raw body for parsed content types; for any
  # other type the body is still unread, so read it here.
  defp raw_body(%Plug.Conn{assigns: %{raw_body: body}} = conn) when is_binary(body),
    do: {body, conn}

  defp raw_body(conn) do
    case read_body(conn, length: 1_000_000) do
      {:ok, body, conn} -> {body, conn}
      _ -> :error
    end
  end

  defp apply_event(_profile, %{kind: :ignored}), do: false

  # Social authoring 9/11: the vendor says one of THIS profile's accounts was
  # disconnected (or connected again). Matched by `provider_account_ref`
  # among the profile's live accounts only; `Platform.Social.Health` marks
  # it and alerts once, so a replay changes nothing.
  defp apply_event(%Profile{} = profile, %{kind: kind, account_ref: ref} = event)
       when kind in [:account_disconnected, :account_connected] and is_binary(ref) and ref != "" do
    case profile_account(profile, ref) do
      nil ->
        false

      account when kind == :account_disconnected ->
        match?({:ok, :alerted, _}, Health.account_disconnected(account, event[:error]))

      account ->
        Health.account_reconnected(account) == {:ok, :reconnected}
    end
  end

  defp apply_event(%Profile{id: profile_id}, %{external_id: external_id} = event)
       when is_binary(external_id) and external_id != "" do
    post =
      Repo.one(
        from(p in Post,
          join: a in Account,
          on: a.id == p.account_id,
          where: a.profile_id == ^profile_id and p.external_id == ^external_id,
          limit: 1
        )
      )

    case post && Publishing.apply_outcome(post, event) do
      {:ok, %Post{}} -> true
      _ -> false
    end
  end

  defp apply_event(_profile, _event), do: false

  defp profile_account(%Profile{id: profile_id}, ref) do
    Repo.one(
      from(a in Account,
        where: a.profile_id == ^profile_id and a.provider_account_ref == ^ref,
        where: is_nil(a.archived_at),
        limit: 1
      )
    )
  end

  defp reply(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end
end
