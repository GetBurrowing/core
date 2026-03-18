defmodule Mix.Tasks.Platform.GenVapidKeys do
  @moduledoc """
  Generate a VAPID key pair for Web Push notifications.

  ## Usage

      mix platform.gen_vapid_keys

  Prints the public and private keys in URL-safe base64 encoding.
  Set these as `VAPID_PUBLIC_KEY` and `VAPID_PRIVATE_KEY` environment variables.
  """

  use Mix.Task

  @shortdoc "Generate a VAPID key pair for Web Push"

  @impl true
  def run(_args) do
    {public, private} = :crypto.generate_key(:ecdh, :prime256v1)

    public_key = Base.url_encode64(public, padding: false)
    private_key = Base.url_encode64(private, padding: false)

    Mix.shell().info("""

    VAPID Key Pair Generated
    ========================

    VAPID_PUBLIC_KEY=#{public_key}
    VAPID_PRIVATE_KEY=#{private_key}

    Add these to your environment or .env file.
    """)
  end
end
