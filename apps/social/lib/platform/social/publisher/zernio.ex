defmodule Platform.Social.Publisher.Zernio do
  @moduledoc """
  `Platform.Social.Publisher` over Zernio's REST API (task 01a140a9, Social
  2/7, stage 4). The ONLY vendor-specific code in Social: if Postiz is picked
  instead, this file, its test and its config entry are what change.

  Selected by config (`config :social, :publisher, Platform.Social.Publisher.Zernio`),
  which prod sets at boot from `SOCIAL_PUBLISHER` (`Platform.Social.RuntimeConfig`).

  ## API facts (looked up 2026-10-15)

    * Base `https://zernio.com/api`, paths under `/v1`, `Authorization: Bearer <key>`
      (OpenAPI servers: https://docs.zernio.com/api/openapi).
    * `POST /v1/posts` (https://docs.zernio.com/posts/create-post): `content`,
      `mediaItems [{type, url}]`, `platforms [{platform, accountId, platformSpecificData}]`,
      `scheduledFor` (ISO 8601), `timezone`, `publishNow`, `tiktokSettings`; optional
      `Idempotency-Key` header (we send the post id). 201 created, 200 idempotent
      replay, 409 duplicate content within 24h (`existingPostId`), 429 rate limited.
    * `GET` / `DELETE /v1/posts/{postId}`; statuses published, failed, partial,
      scheduled, publishing, draft, cancelled; per-platform `platformPostUrl`,
      `errorMessage`.
    * `POST /v1/profiles` (https://docs.zernio.com/profiles/create-profile, fetched
      2026-10-17): `name` required (unique per Zernio team), optional `externalId`
      (1-255 chars, unique per owner; we send our profile id); optional
      `Idempotency-Key` header (we send our profile id). 201 answers
      `{message, profile: {_id}}`. 409 on a duplicate name carries
      `details.existingProfileId`; 409 code `profile_external_id_conflict` on a
      duplicate externalId; 422 on an Idempotency-Key reused with another body.
      A name conflict is NEVER adopted: names are unique per org here
      (`[org_id, name]`), not per install, so another org's profile can hold it.
    * `GET /v1/connect/{platform}?profileId=&redirect_url=` answers `{authUrl}`.
      The platform enum says `twitter` for X. TikTok connects through Zernio's own
      TikTok for Business app (direct post, https://docs.zernio.com/platforms/tiktok).
    * `GET /v1/accounts?profileId=` (https://docs.zernio.com/accounts/list-accounts,
      fetched 2026-10-17): `page` and `limit` go together or not at all (we send
      neither, which lists every account). 200 answers `{accounts: [...],
      hasAnalyticsAccess}`; each entry carries `_id`, `platform` (`twitter` for X),
      `profileId`, `username`, `displayName`, `profileUrl`, `isActive`. The
      multi-tenant guide says to identify accounts by `accountId` (`_id`), never
      by profile + platform. 401 and 503 are listed.
    * `DELETE /v1/accounts/{accountId}` (https://docs.zernio.com/accounts/delete-account,
      fetched 2026-10-17): 200 answers `{message: "Account disconnected successfully"}`,
      401 unauthorized, 404 means the account is already disconnected (it sits in a
      1h grace window), so `disconnect_account/1` maps 404 to `:ok`. ASSUMPTION: the
      same `_id` can be reconnected through OAuth later; nothing here depends on it.
    * Webhooks (https://docs.zernio.com/webhooks, https://docs.zernio.com/webhooks/posts):
      `X-Zernio-Signature` (legacy `X-Late-Signature`) = lowercase-hex HMAC-SHA256 of
      the RAW body with the endpoint secret, no timestamp; event id `payload.id`
      (also `X-Zernio-Event-Id`); envelope `{id, event, post, timestamp}`; published
      entries carry `platformPostId`/`publishedUrl`, failed ones `error`/`errorCategory`.
      Up to 7 delivery attempts. TikTok's `publishedUrl` can be empty until
      `post.tiktok.url_resolved`.
    * AI disclosure: TikTok `tiktokSettings.video_made_with_ai`, X
      `platformSpecificData.madeWithAi`, Instagram `isAiGenerated`, YouTube
      `containsSyntheticMedia`.
    * TikTok requires `privacy_level`, `allow_comment`, `content_preview_confirmed: true`,
      `express_consent_given: true`.
    * Rate limits: 60 to 1,200 requests/minute by plan, plus per-account caps
      (X 50/day, IG 100/day, 25 posts/hour velocity). 429 maps to `:rate_limited`.

  Each ASSUMPTION the docs do not settle is isolated in one private function
  or attribute, commented `ASSUMPTION`.

  ## Secrets and transport

  The API key is ONE install-level key, read ONLY from the Vault
  (`Platform.Social.Secrets.zernio_api_key/0`: `get_unique` on
  `"social:zernio:api_key"`, scope and accessor `{:integration, nil}`), and
  entered by a human through `Secrets.put_zernio_api_key/2`. The account and
  profile carry only Zernio's ids (`provider_account_ref`,
  `provider_profile_ref`). Missing, blank or undecryptable is
  `{:error, :credentials_unavailable}` and NO request is sent. HTTP is Req: `base_url` from
  `config :social, Platform.Social.Publisher.Zernio, base_url:`, merged with
  `config :social, :zernio_req_options` (tests inject `plug: {Req.Test, __MODULE__}`).
  Config never holds a key. POST is never retried: the Idempotency-Key makes a
  caller's retry safe instead.
  """

  @behaviour Platform.Social.Publisher

  alias Platform.Social.Secrets

  @default_base_url "https://zernio.com/api"
  @signature_headers ["x-zernio-signature", "x-late-signature"]

  # Our platform names to Zernio's enum (it says "twitter" for X).
  @platforms %{
    "x" => "twitter",
    "linkedin" => "linkedin",
    "tiktok" => "tiktok",
    "instagram" => "instagram",
    "youtube" => "youtube"
  }

  # ── Callbacks ────────────────────────────────────────────────────────

  @impl true
  def ensure_profile(profile) do
    case profile_ref(profile) do
      ref when is_binary(ref) ->
        {:ok, ref}

      nil ->
        with {:ok, key} <- api_key(nil) do
          request(key)
          |> Req.post(
            url: "/v1/profiles",
            json: %{name: profile.name, externalId: profile.id},
            headers: [{"idempotency-key", profile.id}],
            retry: false
          )
          |> handle_profile(profile)
        end
    end
  end

  @impl true
  def platforms do
    Enum.filter(Platform.Social.Account.platforms(), &Map.has_key?(@platforms, &1))
  end

  @impl true
  def connect_url(account, opts) do
    profile_ref = opts |> Keyword.get(:profile) |> profile_ref()
    redirect_url = Keyword.get(opts, :redirect_url)

    with {:ok, key} <- api_key(account),
         {:ok, platform} <- platform(account.platform),
         true <- is_binary(profile_ref) || {:error, :profile_not_linked} do
      request(key)
      |> Req.get(
        url: "/v1/connect/#{platform}",
        params: [profileId: profile_ref, redirect_url: redirect_url]
      )
      |> handle(fn
        %{"authUrl" => url} when is_binary(url) -> {:ok, url}
        _ -> {:error, :unexpected_response}
      end)
    end
  end

  # Profile ref first, then the key, then the ONE request: no ref or no key
  # means nothing is sent. The short receive_timeout and no retry bound how
  # long a LiveView event can block on it.
  @impl true
  def list_accounts(profile) do
    with ref when is_binary(ref) <- profile_ref(profile) || {:error, :profile_not_linked},
         {:ok, key} <- api_key(nil) do
      request(key)
      |> Req.get(
        url: "/v1/accounts",
        params: [profileId: ref],
        retry: false,
        receive_timeout: 5_000
      )
      |> handle(fn
        %{"accounts" => entries} when is_list(entries) ->
          {:ok, entries |> Enum.map(&connected_account/1) |> Enum.reject(&is_nil/1)}

        _ ->
          {:error, :unexpected_response}
      end)
    end
  end

  @impl true
  def publish(account, request) do
    with {:ok, key} <- api_key(account),
         {:ok, platform} <- platform(request.platform),
         {:ok, media} <- media_items(request.media) do
      body = post_body(account, platform, request, media)

      request(key)
      |> Req.post(
        url: "/v1/posts",
        json: body,
        headers: [{"idempotency-key", request.idempotency_key}],
        retry: false
      )
      |> handle(fn resp_body ->
        case post_id(resp_body) do
          id when is_binary(id) ->
            post = resp_post(resp_body)
            {status, url} = publish_status(post, account)
            {:ok, %{external_id: id, status: status, external_url: url}}

          _ ->
            {:error, :unexpected_response}
        end
      end)
    end
  end

  @impl true
  def status(account, external_id) do
    with {:ok, key} <- api_key(account) do
      request(key)
      |> Req.get(url: "/v1/posts/#{URI.encode(external_id)}")
      |> handle(fn resp_body ->
        post = resp_post(resp_body)
        entry = account_entry(post, account)

        status =
          case post["status"] do
            "published" -> :published
            "failed" -> :failed
            "cancelled" -> :failed
            "partial" -> if published_entry?(entry), do: :published, else: :failed
            _ -> :scheduled
          end

        error =
          cond do
            status != :failed -> nil
            post["status"] == "cancelled" -> "cancelled at vendor"
            true -> (entry && (entry["errorMessage"] || entry["error"])) || "failed at the vendor"
          end

        {:ok,
         %{
           status: status,
           external_url: entry && (entry["platformPostUrl"] || entry["publishedUrl"]),
           error: error
         }}
      end)
    end
  end

  @impl true
  def delete(account, external_id) do
    with {:ok, key} <- api_key(account) do
      request(key)
      |> Req.delete(url: "/v1/posts/#{URI.encode(external_id)}")
      |> handle(fn _ -> :ok end)
    end
  end

  # Ref first, then the key, then the ONE request: no ref or no key means
  # nothing is sent. Zernio answers 404 for an account it already
  # disconnected, so a repeat is :ok; everything else goes through handle/2.
  @impl true
  def disconnect_account(account) do
    with ref when is_binary(ref) <- account_ref(account) || {:error, :not_connected},
         {:ok, key} <- api_key(account) do
      case request(key) |> Req.delete(url: "/v1/accounts/#{URI.encode(ref)}") do
        {:ok, %Req.Response{status: 404}} -> :ok
        result -> handle(result, fn _ -> :ok end)
      end
    end
  end

  @impl true
  def verify_webhook(%{raw_body: raw_body, headers: headers}, secret) do
    with true <- is_binary(raw_body) and is_binary(secret) and secret != "",
         signature when is_binary(signature) <- signature(headers),
         expected = :crypto.mac(:hmac, :sha256, secret, raw_body) |> Base.encode16(case: :lower),
         # ASSUMPTION: the docs' sample compares with `!==`; we compare in constant time.
         true <- Plug.Crypto.secure_compare(expected, String.downcase(String.trim(signature))),
         {:ok, %{} = payload} <- Jason.decode(raw_body) do
      {:ok, [event(payload, header(headers, "x-zernio-event-id"))]}
    else
      _ -> {:error, :invalid_signature}
    end
  end

  def verify_webhook(_delivery, _secret), do: {:error, :invalid_signature}

  # ── Request building ─────────────────────────────────────────────────

  defp request(key) do
    config = Application.get_env(:social, __MODULE__, [])

    Req.new(
      base_url: Keyword.get(config, :base_url) || @default_base_url,
      auth: {:bearer, key},
      receive_timeout: 15_000
    )
    |> Req.merge(Application.get_env(:social, :zernio_req_options, []))
  end

  # One key for the install; the account is not consulted.
  defp api_key(_account) do
    case Secrets.zernio_api_key() do
      {:ok, key} -> {:ok, key}
      _ -> {:error, :credentials_unavailable}
    end
  end

  defp platform(ours) do
    case Map.fetch(@platforms, ours) do
      {:ok, theirs} -> {:ok, theirs}
      :error -> {:error, {:unsupported_platform, ours}}
    end
  end

  defp profile_ref(%{provider_profile_ref: ref}) when is_binary(ref) and ref != "", do: ref
  defp profile_ref(_), do: nil

  defp account_ref(%{provider_account_ref: ref}) when is_binary(ref) do
    if String.trim(ref) == "", do: nil, else: ref
  end

  defp account_ref(_), do: nil

  # A vendor fetches media by URL; one without a URL cannot be sent.
  defp media_items(media) do
    if Enum.all?(media, &is_binary(&1[:url])),
      do: {:ok, Enum.map(media, &%{type: media_type(&1.content_type), url: &1.url})},
      else: {:error, :media_url_unavailable}
  end

  # ASSUMPTION: Zernio's mediaItems `type` takes "video" and "image"; a GIF
  # is sent as an image.
  defp media_type("video/" <> _), do: "video"
  defp media_type(_), do: "image"

  defp post_body(account, platform, request, media) do
    base = %{
      content: content(request),
      mediaItems: media,
      platforms: [
        %{
          platform: platform,
          accountId: account.provider_account_ref,
          platformSpecificData: platform_specific(request.platform, request.is_aigc)
        }
      ],
      timezone: "UTC"
    }

    base
    |> schedule(request.scheduled_at)
    |> tiktok(request)
  end

  defp content(%{body: body, link_url: link}) when is_binary(link) and link != "",
    do: Enum.join(Enum.reject([body, link], &(&1 in [nil, ""])), "\n\n")

  defp content(%{body: body}), do: body || ""

  defp schedule(body, %DateTime{} = at), do: Map.put(body, :scheduledFor, DateTime.to_iso8601(at))
  defp schedule(body, _), do: Map.put(body, :publishNow, true)

  defp platform_specific("x", aigc), do: %{madeWithAi: aigc == true}
  defp platform_specific("instagram", aigc), do: %{isAiGenerated: aigc == true}
  defp platform_specific("youtube", aigc), do: %{containsSyntheticMedia: aigc == true}
  defp platform_specific(_, _), do: %{}

  defp tiktok(body, %{platform: "tiktok", is_aigc: aigc}) do
    Map.put(body, :tiktokSettings, %{
      privacy_level: "PUBLIC_TO_EVERYONE",
      allow_comment: true,
      allow_duet: true,
      allow_stitch: true,
      content_preview_confirmed: true,
      express_consent_given: true,
      video_made_with_ai: aigc == true
    })
  end

  defp tiktok(body, _request), do: body

  # ── Response handling ────────────────────────────────────────────────

  defp handle({:ok, %Req.Response{status: status, body: body}}, on_success)
       when status in 200..299,
       do: on_success.(body)

  defp handle({:ok, %Req.Response{status: 409, body: body}}, _),
    do: {:error, {:duplicate_content, is_map(body) && body["existingPostId"]}}

  defp handle({:ok, %Req.Response{status: 429}}, _), do: {:error, :rate_limited}

  defp handle({:ok, %Req.Response{status: status}}, _) when status in [401, 403],
    do: {:error, :credentials_rejected}

  defp handle({:ok, %Req.Response{status: 404}}, _), do: {:error, :not_found}

  defp handle({:ok, %Req.Response{status: status, body: body}}, _) when status in 400..499,
    do: {:error, "Zernio refused the request (HTTP #{status}): #{message(body)}"}

  defp handle({:ok, %Req.Response{status: status}}, _),
    do: {:error, "Zernio is unavailable (HTTP #{status})"}

  defp handle({:error, exception}, _),
    do: {:error, "Zernio could not be reached: #{Exception.message(exception)}"}

  defp message(%{"error" => e}) when is_binary(e), do: e
  defp message(%{"message" => m}) when is_binary(m), do: m
  defp message(_), do: "no detail"

  # 409 is profile-specific here, so it is matched BEFORE the shared handle/2
  # (whose 409 clause means duplicate post content).
  defp handle_profile({:ok, %Req.Response{status: 409, body: body}}, profile) do
    if profile_conflict_code(body) == "profile_external_id_conflict" do
      # externalId is our own profile id, so the existing profile is ours.
      case profile_conflict_existing_id(body) do
        id when is_binary(id) and id != "" -> {:ok, id}
        _ -> {:error, :profile_conflict}
      end
    else
      # A name conflict: never adopted (another org may own that name).
      {:error, {:profile_name_taken, profile.name}}
    end
  end

  defp handle_profile(result, _profile) do
    handle(result, fn resp_body ->
      case profile_id(resp_body) do
        id when is_binary(id) and id != "" -> {:ok, id}
        _ -> {:error, :unexpected_response}
      end
    end)
  end

  # Documented: the created profile is `profile._id`.
  # ASSUMPTION: also accept a root `_id`.
  defp profile_id(%{"profile" => %{"_id" => id}}) when is_binary(id), do: id
  defp profile_id(%{"_id" => id}) when is_binary(id), do: id
  defp profile_id(_), do: nil

  # ASSUMPTION: the conflict `code` and `details` sit at the body root, or
  # under an `error` object; the docs show neither placement for the
  # externalId conflict.
  defp profile_conflict_code(%{"code" => code}) when is_binary(code), do: code
  defp profile_conflict_code(%{"error" => %{"code" => code}}) when is_binary(code), do: code
  defp profile_conflict_code(_), do: nil

  defp profile_conflict_existing_id(%{"details" => %{"existingProfileId" => id}}), do: id

  defp profile_conflict_existing_id(%{"error" => %{"details" => %{"existingProfileId" => id}}}),
    do: id

  defp profile_conflict_existing_id(_), do: nil

  # ASSUMPTION: a create response nests the post under "post" (Post._id) or
  # returns it at the root (_id); accept both.
  defp post_id(%{"post" => %{"_id" => id}}) when is_binary(id), do: id
  defp post_id(%{"_id" => id}) when is_binary(id), do: id
  defp post_id(_), do: nil

  defp resp_post(%{"post" => %{} = post}), do: post
  defp resp_post(%{} = post), do: post
  defp resp_post(_), do: %{}

  defp publish_status(%{"status" => "published"} = post, account) do
    entry = account_entry(post, account)
    {:published, entry && (entry["platformPostUrl"] || entry["publishedUrl"])}
  end

  defp publish_status(_post, _account), do: {:scheduled, nil}

  # ASSUMPTION: a post's platforms[] entry for our account is the one whose
  # accountId equals account.provider_account_ref (only the field names are
  # documented). We send one platform per post, so a lone entry is ours.
  defp account_entry(%{"platforms" => [entry]}, _account) when is_map(entry), do: entry

  defp account_entry(%{"platforms" => entries}, account) when is_list(entries),
    do: Enum.find(entries, &(is_map(&1) and &1["accountId"] == account.provider_account_ref))

  defp account_entry(_post, _account), do: nil

  defp published_entry?(%{} = entry),
    do:
      entry["status"] == "published" or present?(entry["platformPostId"]) or
        present?(entry["publishedUrl"]) or present?(entry["platformPostUrl"])

  defp published_entry?(_), do: false

  # ── Account list ─────────────────────────────────────────────────────

  # Zernio's enum back to our names; a platform we don't support is dropped.
  @our_platforms Map.new(@platforms, fn {ours, theirs} -> {theirs, ours} end)

  defp connected_account(%{"_id" => ref, "platform" => theirs} = entry)
       when is_binary(ref) and ref != "" do
    case Map.fetch(@our_platforms, theirs) do
      {:ok, ours} ->
        %{
          ref: ref,
          platform: ours,
          profile_ref: entry_profile_ref(entry["profileId"]),
          username: if(is_binary(entry["username"]), do: entry["username"]),
          active?: active?(entry)
        }

      :error ->
        nil
    end
  end

  defp connected_account(_entry), do: nil

  # Documented: the sample shows `profileId` as an object `{_id, name, slug}`.
  # ASSUMPTION: it may also arrive as a plain id string; accept both.
  defp entry_profile_ref(%{"_id" => id}) when is_binary(id) and id != "", do: id
  defp entry_profile_ref(id) when is_binary(id) and id != "", do: id
  defp entry_profile_ref(_), do: nil

  # ASSUMPTION: `isActive: false` means the account is not usable. Only an
  # explicit false counts; the entry's status field is undocumented and unread.
  defp active?(%{"isActive" => false}), do: false
  defp active?(_entry), do: true

  # ── Webhook normalization ────────────────────────────────────────────

  defp signature(headers), do: Enum.find_value(@signature_headers, &header(headers, &1))

  defp header(headers, name) do
    Enum.find_value(headers, fn {k, v} -> if String.downcase(to_string(k)) == name, do: v end)
  end

  defp event(payload, header_event_id) do
    post = if is_map(payload["post"]), do: payload["post"], else: %{}
    entry = webhook_entry(post)
    {kind, error} = webhook_kind(payload["event"], entry)

    %{
      event_id: payload["id"] || header_event_id,
      external_id: post["_id"] || post["id"],
      kind: kind,
      external_url: if(kind == :published, do: blank_to_nil(entry && entry["publishedUrl"])),
      error: error
    }
  end

  # ASSUMPTION: we send one platform per post, so the webhook's first
  # platforms[] entry is our account's.
  defp webhook_entry(%{"platforms" => [entry | _]}) when is_map(entry), do: entry
  defp webhook_entry(_post), do: nil

  # ASSUMPTION: post.partial is published if our entry published, otherwise
  # failed; post.cancelled is failed "cancelled at vendor"; every other event
  # (including post.tiktok.url_resolved for now) is ignored.
  defp webhook_kind("post.published", _entry), do: {:published, nil}
  defp webhook_kind("post.failed", entry), do: {:failed, entry_error(entry)}
  defp webhook_kind("post.cancelled", _entry), do: {:failed, "cancelled at vendor"}

  defp webhook_kind("post.partial", entry) do
    if published_entry?(entry), do: {:published, nil}, else: {:failed, entry_error(entry)}
  end

  defp webhook_kind(_event, _entry), do: {:ignored, nil}

  defp entry_error(%{"error" => e} = entry) when is_binary(e) and e != "" do
    case entry["errorCategory"] do
      c when is_binary(c) and c != "" -> "#{e} (#{c})"
      _ -> e
    end
  end

  defp entry_error(_), do: "failed at the vendor"

  defp present?(v), do: is_binary(v) and v != ""
  defp blank_to_nil(v), do: if(present?(v), do: v)
end
