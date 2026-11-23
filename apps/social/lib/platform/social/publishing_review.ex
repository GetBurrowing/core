defmodule Platform.Social.PublishingReview do
  @moduledoc "Read-only fields for an already-authorized publishing reviewer. No authorization or snapshot is retained here."
  alias Platform.Social.{PlatformOptions, Publishing}

  def details(post, account, zone) do
    options = post.platform_options || %{}

    extras =
      for field <- PlatformOptions.fields(account.platform),
          field.key != "title",
          value = options[field.key],
          is_binary(value) and String.trim(value) != "",
          do: {field.label, value}

    time =
      case post.scheduled_at do
        %DateTime{} = at ->
          local =
            case DateTime.shift_zone(at, zone || "Etc/UTC") do
              {:ok, local} -> local
              _ -> at
            end

          Calendar.strftime(local, "%a %d %b %Y, %H:%M %Z") <>
            " · " <>
            Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")

        _ ->
          "Not set"
      end

    ai = if post.is_aigc, do: [{"AI-generated content", "Yes"}], else: []
    disclosure = Publishing.disclosure(post)

    labels =
      if is_binary(disclosure) and String.trim(disclosure) != "",
        do: [{"AI disclosure", disclosure}],
        else: []

    [{"Publish time", time}] ++ extras ++ ai ++ labels
  end
end
