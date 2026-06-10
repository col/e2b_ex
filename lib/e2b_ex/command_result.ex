defmodule E2bEx.CommandResult do
  @moduledoc """
  Result of a completed sandbox command (see `E2bEx.Commands.run/4`).

  `exit_code` is `0` for success. `error` carries a command-level error string
  reported by envd in the process `end` event (distinct from an operation-level
  `{:error, %E2bEx.Error{}}`, which signals the command could not be run).
  """

  @type t :: %__MODULE__{
          stdout: String.t(),
          stderr: String.t(),
          exit_code: integer(),
          error: String.t() | nil
        }

  defstruct stdout: "", stderr: "", exit_code: 0, error: nil
end
