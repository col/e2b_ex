defmodule E2bEx.Webhook do
  @moduledoc "A registered webhook, decoded from create/get/list/update responses."

  @type t :: %__MODULE__{
          id: String.t() | nil,
          team_id: String.t() | nil,
          name: String.t() | nil,
          created_at: String.t() | nil,
          enabled: boolean() | nil,
          url: String.t() | nil,
          events: [String.t()] | nil
        }

  defstruct [:id, :team_id, :name, :created_at, :enabled, :url, :events]

  @doc false
  @spec from_api(map()) :: t()
  def from_api(m) when is_map(m) do
    %__MODULE__{
      id: m["id"],
      team_id: m["teamId"],
      name: m["name"],
      created_at: m["createdAt"],
      enabled: m["enabled"],
      url: m["url"],
      events: m["events"]
    }
  end
end
