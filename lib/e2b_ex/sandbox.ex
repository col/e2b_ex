defmodule E2bEx.Sandbox do
  @moduledoc "A sandbox, decoded from create/get/list responses."

  @type t :: %__MODULE__{
          template_id: String.t() | nil,
          sandbox_id: String.t() | nil,
          alias: String.t() | nil,
          domain: String.t() | nil,
          started_at: String.t() | nil,
          end_at: String.t() | nil,
          state: String.t() | nil,
          cpu_count: integer() | nil,
          memory_mb: integer() | nil,
          disk_size_mb: integer() | nil,
          envd_version: String.t() | nil,
          envd_access_token: String.t() | nil,
          traffic_access_token: String.t() | nil,
          allow_internet_access: boolean() | nil,
          metadata: map() | nil,
          network: map() | nil,
          lifecycle: map() | nil,
          volume_mounts: list() | nil
        }

  defstruct [
    :template_id,
    :sandbox_id,
    :alias,
    :domain,
    :started_at,
    :end_at,
    :state,
    :cpu_count,
    :memory_mb,
    :disk_size_mb,
    :envd_version,
    :envd_access_token,
    :traffic_access_token,
    :allow_internet_access,
    :metadata,
    :network,
    :lifecycle,
    :volume_mounts
  ]

  @doc false
  @spec from_api(map()) :: t()
  def from_api(m) when is_map(m) do
    %__MODULE__{
      template_id: m["templateID"],
      sandbox_id: m["sandboxID"],
      alias: m["alias"],
      domain: m["domain"],
      started_at: m["startedAt"],
      end_at: m["endAt"],
      state: m["state"],
      cpu_count: m["cpuCount"],
      memory_mb: m["memoryMB"],
      disk_size_mb: m["diskSizeMB"],
      envd_version: m["envdVersion"],
      envd_access_token: m["envdAccessToken"],
      traffic_access_token: m["trafficAccessToken"],
      allow_internet_access: m["allowInternetAccess"],
      metadata: m["metadata"],
      network: m["network"],
      lifecycle: m["lifecycle"],
      volume_mounts: m["volumeMounts"]
    }
  end
end

defmodule E2bEx.SandboxMetric do
  @moduledoc "A point-in-time resource-usage metric for a sandbox."

  @type t :: %__MODULE__{
          timestamp: String.t() | nil,
          timestamp_unix: integer() | nil,
          cpu_count: integer() | nil,
          cpu_used_pct: float() | nil,
          mem_used: integer() | nil,
          mem_total: integer() | nil,
          mem_cache: integer() | nil,
          disk_used: integer() | nil,
          disk_total: integer() | nil
        }

  defstruct [
    :timestamp,
    :timestamp_unix,
    :cpu_count,
    :cpu_used_pct,
    :mem_used,
    :mem_total,
    :mem_cache,
    :disk_used,
    :disk_total
  ]

  @doc false
  @spec from_api(map()) :: t()
  def from_api(m) when is_map(m) do
    %__MODULE__{
      timestamp: m["timestamp"],
      timestamp_unix: m["timestampUnix"],
      cpu_count: m["cpuCount"],
      cpu_used_pct: m["cpuUsedPct"],
      mem_used: m["memUsed"],
      mem_total: m["memTotal"],
      mem_cache: m["memCache"],
      disk_used: m["diskUsed"],
      disk_total: m["diskTotal"]
    }
  end
end

defmodule E2bEx.SandboxLog do
  @moduledoc "A structured sandbox log entry."

  @type t :: %__MODULE__{
          timestamp: String.t() | nil,
          message: String.t() | nil,
          level: String.t() | nil,
          fields: map() | nil
        }

  defstruct [:timestamp, :message, :level, :fields]

  @doc false
  @spec from_api(map()) :: t()
  def from_api(m) when is_map(m) do
    %__MODULE__{
      timestamp: m["timestamp"],
      message: m["message"],
      level: m["level"],
      fields: m["fields"]
    }
  end
end

defmodule E2bEx.Snapshot do
  @moduledoc "Result of snapshotting a sandbox."

  @type t :: %__MODULE__{snapshot_id: String.t() | nil, names: [String.t()] | nil}

  defstruct [:snapshot_id, :names]

  @doc false
  @spec from_api(map()) :: t()
  def from_api(m) when is_map(m) do
    %__MODULE__{snapshot_id: m["snapshotID"], names: m["names"]}
  end
end
