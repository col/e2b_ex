defmodule E2bEx.Commands.Fold do
  @moduledoc false
  # Pure, delivery-agnostic folding of decoded Connect process events into a
  # CommandResult. `apply_event/2` returns the produced output events so callers
  # deliver them however they like: run/4 turns them into on_stdout/on_stderr
  # callbacks, HandleServer into `{ref, _}` messages.

  alias E2bEx.CommandResult

  @type output :: {:stdout, binary()} | {:stderr, binary()}

  defstruct result: %CommandResult{}, ended: false

  @type t :: %__MODULE__{result: CommandResult.t(), ended: boolean()}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec apply_event(t(), map()) :: {:ok, t(), [output()]} | {:error, :invalid_base64}
  def apply_event(acc, %{"data" => %{"stdout" => chunk}}) do
    with {:ok, bytes} <- decode_chunk(chunk) do
      {:ok, %{acc | result: %{acc.result | stdout: acc.result.stdout <> bytes}}, [{:stdout, bytes}]}
    end
  end

  def apply_event(acc, %{"data" => %{"stderr" => chunk}}) do
    with {:ok, bytes} <- decode_chunk(chunk) do
      {:ok, %{acc | result: %{acc.result | stderr: acc.result.stderr <> bytes}}, [{:stderr, bytes}]}
    end
  end

  def apply_event(acc, %{"end" => end_event}) do
    result = %{
      acc.result
      | exit_code: Map.get(end_event, "exitCode", 0),
        error: Map.get(end_event, "error")
    }

    {:ok, %{acc | result: result, ended: true}, []}
  end

  def apply_event(acc, _other), do: {:ok, acc, []}

  @spec result(t()) :: CommandResult.t()
  def result(%__MODULE__{result: result}), do: result

  @spec ended?(t()) :: boolean()
  def ended?(%__MODULE__{ended: ended}), do: ended

  defp decode_chunk(chunk) do
    case Base.decode64(chunk) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :invalid_base64}
    end
  end
end
