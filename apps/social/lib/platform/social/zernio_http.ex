defmodule Platform.Social.ZernioHTTP do
  @moduledoc """
  Shared Zernio Req builder for publishing and analytics (task 01a16664).
  Callers obtain the install key through Secrets.zernio_api_key/0 first.
  Keeps the existing publisher base URL and Req.Test injection in one place.
  """

  @doc "Build a request with an already authorized install key."
  @spec request(String.t()) :: Req.Request.t()
  def request(key) do
    config = Application.get_env(:social, Platform.Social.Publisher.Zernio, [])

    Req.new(
      base_url: Keyword.get(config, :base_url) || "https://zernio.com/api",
      auth: {:bearer, key},
      receive_timeout: 15_000
    )
    |> Req.merge(Application.get_env(:social, :zernio_req_options, []))
  end
end
