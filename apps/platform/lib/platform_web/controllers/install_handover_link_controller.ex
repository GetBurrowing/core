defmodule PlatformWeb.InstallHandoverLinkController do
  @moduledoc """
  `POST /api/install/handover-link`: the installer's way to get the owner's
  durable sign-in link (`Platform.SignIn.DurableLink`) at bootstrap, so the
  "ready" email can carry a button that still works days later.

  Authenticated with `Authorization: Bearer <the install's STATIC_API_KEY>`
  (core's copy, `Platform.SignInAdmin.Config.bearer_matches?/1`), the same
  check the deep health probe uses. A missing or wrong key answers a bare
  404, indistinguishable from "no such route", so the endpoint is not
  discoverable and not a way to probe which emails exist.

  Body: `{"email": "...", "sub": "..."}`. `sub` is optional.

  ## Why this can create the owner's Burrow user

  Burrow users are normally created on first OIDC callback, and the owner has
  not signed in yet when bootstrap runs. A link needs a user id to sign, so
  when no Burrow user has the email and the installer supplied `sub` (the
  pocket-id user id it just created), this creates the user the way
  `Platform.SignInAdmin.invite/2` does: `Accounts.find_or_create_from_oidc/1`
  with that sub. The first root-org membership and the email-domain admin
  rule apply exactly as they do on first login, and the later real login
  finds the same row by sub. Without `sub` an unknown email is a 404 and
  nothing is created.
  """
  use PlatformWeb, :controller

  alias Platform.Accounts
  alias Platform.SignIn.DurableLink
  alias Platform.SignInAdmin.Config

  def create(conn, params) do
    if Config.bearer_matches?(get_req_header(conn, "authorization")) do
      do_create(conn, params)
    else
      conn |> put_status(:not_found) |> text("Not Found")
    end
  end

  defp do_create(conn, %{"email" => email} = params) when is_binary(email) do
    email = email |> String.trim() |> String.downcase()

    case find_or_create(email, params["sub"]) do
      {:ok, user} ->
        json(conn, %{url: DurableLink.url(user, :handover)})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{
          error: "no_such_user",
          message: "No Burrow user has that email and no sub was given"
        })

      {:error, :archived} ->
        conn
        |> put_status(:conflict)
        |> json(%{
          error: "user_archived",
          message: "That user is archived or sign-in is disabled"
        })

      {:error, _} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "user_not_created", message: "The Burrow user could not be created"})
    end
  end

  defp do_create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "invalid_email", message: "email is required"})
  end

  defp find_or_create(email, sub) do
    existing =
      [include_archived: true, query: email]
      |> Accounts.list_users()
      |> Enum.find(&(is_binary(&1.email) and String.downcase(&1.email) == email))

    case {existing, sub} do
      {%{archived_at: %DateTime{}}, _} ->
        {:error, :archived}

      {%{} = user, _} ->
        {:ok, user}

      {nil, sub} when is_binary(sub) and sub != "" ->
        Accounts.find_or_create_from_oidc(%{
          sub: sub,
          email: email,
          name: email |> String.split("@") |> hd()
        })

      {nil, _} ->
        {:error, :not_found}
    end
  end
end
