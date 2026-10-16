defmodule Platform.Social.Publisher do
  @moduledoc """
  The vendor-independent publishing contract (task 01a140a9, Social 2/7).

  The vendor is not chosen yet (Zernio vs self-hosted Postiz), so nothing in
  Social knows which one it talks to except the adapter module and ONE config
  key:

      config :social, :publisher, Platform.Social.Publisher.Fake

  `impl/0` reads that key on every call. dev and test select
  `Platform.Social.Publisher.Fake` (`apps/social/config/config.exs`); prod
  sets nothing, so `impl/0` answers `{:error, :publisher_not_configured}`
  and nothing publishes in prod until a vendor is picked.

  ## Secrets

  An adapter never reads a key from config, env, the DB or a struct field.
  The account's API key and each profile's webhook secret live in the Vault
  and are read with `Platform.Social.Secrets` (the `Platform.Mail` accessor
  pattern). A missing secret fails closed.

  ## The publish guard

  `publish/2` is called from exactly ONE place, `Platform.Social.Publishing.publish_post/2`,
  which re-reads the post under a row lock and refuses unless it is
  `approved` with a human approver. A test pins the single call site.
  """

  @typedoc "A post's media, vendor-neutral. `duration_s` is `nil` for images or when unknown."
  @type media :: %{
          url: String.t(),
          content_type: String.t() | nil,
          byte_size: non_neg_integer() | nil,
          duration_s: number() | nil
        }

  @typedoc """
  The vendor-neutral publish request. `idempotency_key` is the post id, so a
  retried publish is a replay at the vendor, not a second post.
  """
  @type request :: %{
          body: String.t() | nil,
          link_url: String.t() | nil,
          scheduled_at: DateTime.t() | nil,
          media: [media()],
          is_aigc: boolean(),
          ai_disclosure: String.t() | nil,
          platform: String.t(),
          idempotency_key: String.t()
        }

  @type publish_result :: %{
          external_id: binary(),
          status: :scheduled | :published,
          external_url: binary() | nil
        }

  @type status_result :: %{
          status: :scheduled | :published | :failed,
          external_url: binary() | nil,
          error: String.t() | nil
        }

  @typedoc "One status event from a verified webhook delivery."
  @type event :: %{
          event_id: String.t() | nil,
          external_id: String.t() | nil,
          kind: :published | :failed | :ignored,
          external_url: String.t() | nil,
          error: String.t() | nil
        }

  @type delivery :: %{raw_body: binary(), headers: map()}

  @type account :: Platform.Social.Account.t()

  @doc "Starts OAuth for `account`. `opts` carries `:redirect_url` (and `:profile`)."
  @callback connect_url(account(), keyword()) :: {:ok, String.t()} | {:error, term()}

  @doc "Creates (or schedules) the post at the vendor."
  @callback publish(account(), request()) :: {:ok, publish_result()} | {:error, term()}

  @doc "Reads a post's state at the vendor."
  @callback status(account(), external_id :: String.t()) ::
              {:ok, status_result()} | {:error, term()}

  @doc "Deletes (cancels) a post at the vendor."
  @callback delete(account(), external_id :: String.t()) :: :ok | {:error, term()}

  @doc """
  Verifies a webhook delivery's signature over the RAW body with `secret`
  and normalizes it into events. Anything unverifiable is
  `{:error, :invalid_signature}`.
  """
  @callback verify_webhook(delivery(), secret :: binary()) ::
              {:ok, [event()]} | {:error, :invalid_signature}

  @doc """
  The configured adapter module, read from `config :social, :publisher` on
  every call, or `{:error, :publisher_not_configured}` when it is unset.
  """
  @spec impl() :: module() | {:error, :publisher_not_configured}
  def impl do
    case Application.get_env(:social, :publisher) do
      nil -> {:error, :publisher_not_configured}
      module when is_atom(module) -> module
    end
  end
end
