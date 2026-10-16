defmodule Platform.Social.Publisher.Zernio do
  @moduledoc """
  `Platform.Social.Publisher` over Zernio's REST API (task 01a140a9, Social
  2/7, stage 4). The ONLY vendor-specific code in Social: if Postiz is picked
  instead, this file, its test and its config entry are what change.

  Opt-in only, and selected nowhere yet (no vendor is chosen, no keys exist):

      config :social, :publisher, Platform.Social.Publisher.Zernio

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
    * `GET /v1/connect/{platform}?profileId=&redirect_url=` answers `{authUrl}`.
      The platform enum says `twitter` for X. TikTok connects through Zernio's own
      TikTok for Business app (direct post, https://docs.zernio.com/platforms/tiktok).
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

  The API key is read ONLY from the Vault (`Platform.Social.Secrets.account_key/1`:
  `get_unique` on `account.secret_slug`, scope and accessor `{:integration, account.id}`).
  Missing or undecryptable is `{:error, :credentials_unavailable}` and NO
  request is sent. HTTP is Req: `base_url` from
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

  defp api_key(account) do
    case Secrets.account_key(account) do
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
