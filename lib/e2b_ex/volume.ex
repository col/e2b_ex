defmodule E2bEx.Volume do
  @moduledoc "A team volume, decoded from create/get/list responses."

  @type t :: %__MODULE__{
          volume_id: String.t() | nil,
          name: String.t() | nil,
          token: String.t() | nil
        }

  defstruct [:volume_id, :name, :token]

  @doc false
  @spec from_api(map()) :: t()
  def from_api(m) when is_map(m) do
    %__MODULE__{volume_id: m["volumeID"], name: m["name"], token: m["token"]}
  end
end
