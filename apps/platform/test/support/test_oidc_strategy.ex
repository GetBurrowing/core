defmodule Platform.TestOIDCStrategy do
  def authorize_url(config) do
    state = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    nonce = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

    query =
      URI.encode_query(%{
        "client_id" => config[:client_id],
        "nonce" => nonce,
        "redirect_uri" => config[:redirect_uri],
        "state" => state
      })

    {:ok,
     %{
       url: "https://issuer.example.com/authorize?" <> query,
       session_params: %{state: state, nonce: nonce}
     }}
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
         userinfo: %{
           "sub" => params["sub"] || "test-subject",
           "email" => params["email"] || "user@example.com",
           "name" => params["name"] || "Test User"
         },
         id_token: %{
           "sub" => params["sub"] || "test-subject",
           "email" => params["email"] || "user@example.com",
           "name" => params["name"] || "Test User",
           "picture" => params["picture"] || "https://issuer.example.com/avatars/test-user.png"
         },
         token: %{"id_token" => "test-id-token"}
       }}
  end
end
