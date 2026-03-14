defmodule Platform.TestOIDCStrategy do
  def authorize_url(config) do
    query =
      URI.encode_query(%{
        "client_id" => config[:client_id],
        "nonce" => config[:nonce],
        "redirect_uri" => config[:redirect_uri],
        "state" => config[:state]
      })

    {:ok, %{url: "https://issuer.example.com/authorize?" <> query}}
  end

  def callback(_config, params) do
    Application.get_env(:platform, :oidc_mock_response) ||
      {:ok,
       %{
         user: %{
           "sub" => params["sub"] || "test-subject",
           "email" => params["email"] || "user@example.com",
           "name" => params["name"] || "Test User"
         },
         token: %{"id_token" => "test-id-token"}
       }}
  end
end
