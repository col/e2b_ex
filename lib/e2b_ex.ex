defmodule E2bEx do
  @moduledoc """
  Elixir client for the [E2B](https://e2b.dev) API (Sandboxes, Templates, Tags).

  ## Quick start

      client = E2bEx.client(api_key: "e2b_...")

      {:ok, sandbox} = E2bEx.Sandboxes.create(client, %{templateID: "base"})
      {:ok, sandboxes} = E2bEx.Sandboxes.list(client)
      :ok = E2bEx.Sandboxes.kill(client, sandbox.sandbox_id)

  Every call returns `{:ok, value}` / `:ok`, or `{:error, %E2bEx.Error{}}`.

  See `E2bEx.Sandboxes`, `E2bEx.Templates`, and `E2bEx.Tags` for the full API.
  """

  @doc "Build a client. See `E2bEx.Client.new/1` for options."
  @spec client(keyword()) :: E2bEx.Client.t()
  defdelegate client(opts \\ []), to: E2bEx.Client, as: :new
end
