defmodule E2bEx.FilesystemEvent do
  @moduledoc "A filesystem change event from `E2bEx.Filesystem.watch_dir/4`."

  alias E2bEx.EntryInfo

  @type t :: %__MODULE__{
          name: String.t() | nil,
          type: :create | :write | :remove | :rename | :chmod | nil,
          entry: EntryInfo.t() | nil
        }

  defstruct [:name, :type, :entry]

  @doc false
  @spec from_api(map()) :: t()
  def from_api(m) when is_map(m) do
    %__MODULE__{
      name: m["name"],
      type: decode_type(m["type"]),
      entry: decode_entry(m["entry"])
    }
  end

  defp decode_type("EVENT_TYPE_CREATE"), do: :create
  defp decode_type("EVENT_TYPE_WRITE"), do: :write
  defp decode_type("EVENT_TYPE_REMOVE"), do: :remove
  defp decode_type("EVENT_TYPE_RENAME"), do: :rename
  defp decode_type("EVENT_TYPE_CHMOD"), do: :chmod
  defp decode_type(_), do: nil

  defp decode_entry(m) when is_map(m), do: EntryInfo.from_api(m)
  defp decode_entry(_), do: nil
end
