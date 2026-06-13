defmodule E2bEx.EntryInfo do
  @moduledoc "A filesystem entry (file or directory), decoded from envd responses."

  @type t :: %__MODULE__{
          name: String.t() | nil,
          type: :file | :dir | nil,
          path: String.t() | nil,
          size: non_neg_integer() | nil,
          mode: non_neg_integer() | nil,
          permissions: String.t() | nil,
          owner: String.t() | nil,
          group: String.t() | nil,
          modified_time: String.t() | nil,
          symlink_target: String.t() | nil,
          metadata: map() | nil
        }

  defstruct [
    :name,
    :type,
    :path,
    :size,
    :mode,
    :permissions,
    :owner,
    :group,
    :modified_time,
    :symlink_target,
    :metadata
  ]

  @doc false
  @spec from_api(map()) :: t()
  def from_api(m) when is_map(m) do
    %__MODULE__{
      name: m["name"],
      type: decode_type(m["type"]),
      path: m["path"],
      size: m["size"],
      mode: m["mode"],
      permissions: m["permissions"],
      owner: m["owner"],
      group: m["group"],
      modified_time: m["modifiedTime"],
      symlink_target: m["symlinkTarget"],
      metadata: m["metadata"]
    }
  end

  defp decode_type("FILE_TYPE_FILE"), do: :file
  defp decode_type("FILE_TYPE_DIRECTORY"), do: :dir
  defp decode_type(_), do: nil
end
