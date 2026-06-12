defmodule Mix.Tasks.E2b.Terminal do
  @shortdoc "Open an interactive terminal into a sandbox PTY"

  @moduledoc """
  Open a raw interactive terminal into a sandbox's PTY. Run this from a normal
  shell (NOT from `iex`) — it puts your terminal into raw mode and forwards
  keystrokes to the remote shell.

      mix e2b.terminal SANDBOX_ID        # attach to a running sandbox
      mix e2b.terminal --template base   # create a fresh sandbox, attach, kill on exit

  The API key is taken from `--api-key`, else the `E2B_API_KEY` environment
  variable, else `config :e2b_ex, api_key: ...`.

  To leave, end the remote shell (`exit` or Ctrl-D). On a normal exit the terminal
  is restored automatically; after an abrupt `kill -9`, run `reset`.
  """

  use Mix.Task

  alias E2bEx.{Pty, Sandboxes}

  @impl Mix.Task
  def run(argv) do
    Application.ensure_all_started(:e2b_ex)
    {api_key, target} = parse!(argv)
    client = E2bEx.client(api_key: api_key)
    {sandbox, created?} = resolve_sandbox!(client, target)
    open(client, sandbox, created?)
  end

  @doc false
  @spec parse!([String.t()]) :: {String.t(), {:id, String.t()} | {:template, String.t()}}
  def parse!(argv) do
    {opts, args, _invalid} =
      OptionParser.parse(argv, strict: [template: :string, api_key: :string], aliases: [t: :template])

    api_key =
      opts[:api_key] || System.get_env("E2B_API_KEY") || Application.get_env(:e2b_ex, :api_key) ||
        Mix.raise("No API key. Pass --api-key, set E2B_API_KEY, or config :e2b_ex, api_key: ...")

    target =
      cond do
        args != [] -> {:id, hd(args)}
        opts[:template] -> {:template, opts[:template]}
        true -> Mix.raise("Usage: mix e2b.terminal SANDBOX_ID | --template TEMPLATE")
      end

    {api_key, target}
  end

  defp resolve_sandbox!(client, {:id, id}) do
    case Sandboxes.connect(client, id, 60) do
      {:ok, sandbox} -> {sandbox, false}
      {:error, error} -> Mix.raise("Could not connect to sandbox #{id}: #{inspect(error)}")
    end
  end

  defp resolve_sandbox!(client, {:template, tmpl}) do
    case Sandboxes.create(client, %{templateID: tmpl}) do
      {:ok, sandbox} -> {sandbox, true}
      {:error, error} -> Mix.raise("Could not create sandbox from #{tmpl}: #{inspect(error)}")
    end
  end

  defp open(client, sandbox, created?) do
    {cols, rows} = terminal_size()
    orig = String.trim(to_string(:os.cmd(~c"stty -g </dev/tty")))

    result =
      try do
        _ = :os.cmd(~c"stty raw -echo </dev/tty")

        case Pty.create(client, sandbox, cols: cols, rows: rows, timeout_ms: 0) do
          {:ok, handle} -> Pty.Terminal.run(handle, size: &terminal_size/0)
          {:error, error} -> Mix.raise("Could not open PTY: #{inspect(error)}")
        end
      after
        # An empty `orig` (no controlling tty) degrades to a harmless `stty </dev/tty`.
        _ = :os.cmd(~c"stty #{orig} </dev/tty")
        if created?, do: kill_quietly(client, sandbox.sandbox_id)
      end

    # Now that the terminal is restored (cooked mode), report the outcome.
    IO.binwrite(:stdio, "\n")

    case result do
      {:error, error} -> Mix.shell().error("Terminal session ended with an error: #{inspect(error)}")
      _ -> :ok
    end
  end

  # Best-effort cleanup of a sandbox we created. We're unwinding, so warn rather
  # than raise if the kill fails — otherwise a leaked, billable sandbox goes unnoticed.
  defp kill_quietly(client, sandbox_id) do
    case Sandboxes.kill(client, sandbox_id) do
      :ok -> :ok
      {:error, error} -> Mix.shell().error("Failed to kill sandbox #{sandbox_id}: #{inspect(error)}")
    end
  end

  # stty size prints "rows cols"; we return {cols, rows}. Falls back to 80x24.
  defp terminal_size do
    case :os.cmd(~c"stty size </dev/tty") |> to_string() |> String.split() do
      [rows, cols] -> {String.to_integer(cols), String.to_integer(rows)}
      _ -> {80, 24}
    end
  end
end
