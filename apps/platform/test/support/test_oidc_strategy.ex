defmodule Platform.TestOIDCStrategy do
  def authorize_url(config) do
    state = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    nonce = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

    # Every `authorization_params` entry reaches the URL, as Assent's OIDC
    # strategy does, so a test can see an added `prompt` (task 01a1ccd4
    # stage 4, mutation M9).
    extra =
      config
      |> Keyword.get(:authorization_params, [])
      |> Map.new(fn {k, v} -> {to_string(k), v} end)

    query =
      extra
      |> Map.merge(%{
        "client_id" => config[:client_id],
        "nonce" => nonce,
        "redirect_uri" => config[:redirect_uri],
        "state" => state
      })
      |> URI.encode_query()

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
