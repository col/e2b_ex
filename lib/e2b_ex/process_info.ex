defmodule E2bEx.ProcessInfo do
  @moduledoc """
  A running command or PTY session, as returned by `E2bEx.Commands.list/2`.
  """

  @type t :: %__MODULE__{
          pid: non_neg_integer(),
          tag: String.t() | nil,
          cmd: String.t(),
          args: [String.t()],
          envs: %{String.t() => String.t()},
          cwd: String.t() | nil
        }

  defstruct [:pid, :tag, :cmd, :args, :envs, :cwd]

  @doc false
  @spec from_api(map()) :: t()
  def from_api(%{"config" => config} = entry) do
    %__MODULE__{
      pid: entry["pid"],
      tag: entry["tag"],
      cmd: config["cmd"],
      args: config["args"] || [],
      envs: config["envs"] || %{},
      cwd: config["cwd"]
    }
  end
end
