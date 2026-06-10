defmodule E2bEx.TemplateBuild do
  @moduledoc "A single template build."

  @type t :: %__MODULE__{
          build_id: String.t() | nil,
          status: String.t() | nil,
          created_at: String.t() | nil,
          updated_at: String.t() | nil,
          finished_at: String.t() | nil,
          cpu_count: integer() | nil,
          memory_mb: integer() | nil,
          disk_size_mb: integer() | nil,
          envd_version: String.t() | nil
        }

  defstruct [
    :build_id,
    :status,
    :created_at,
    :updated_at,
    :finished_at,
    :cpu_count,
    :memory_mb,
    :disk_size_mb,
    :envd_version
  ]

  @doc false
  @spec from_api(map()) :: t()
  def from_api(m) when is_map(m) do
    %__MODULE__{
      build_id: m["buildID"],
      status: m["status"],
      created_at: m["createdAt"],
      updated_at: m["updatedAt"],
      finished_at: m["finishedAt"],
      cpu_count: m["cpuCount"],
      memory_mb: m["memoryMB"],
      disk_size_mb: m["diskSizeMB"],
      envd_version: m["envdVersion"]
    }
  end
end

defmodule E2bEx.Template do
  @moduledoc "A template, decoded from list (`Template`) and get (`TemplateWithBuilds`) responses."

  alias E2bEx.TemplateBuild

  @type t :: %__MODULE__{
          template_id: String.t() | nil,
          build_id: String.t() | nil,
          public: boolean() | nil,
          names: [String.t()] | nil,
          aliases: [String.t()] | nil,
          cpu_count: integer() | nil,
          memory_mb: integer() | nil,
          disk_size_mb: integer() | nil,
          created_at: String.t() | nil,
          updated_at: String.t() | nil,
          last_spawned_at: String.t() | nil,
          spawn_count: integer() | nil,
          build_count: integer() | nil,
          envd_version: String.t() | nil,
          build_status: String.t() | nil,
          builds: [TemplateBuild.t()] | nil
        }

  defstruct [
    :template_id,
    :build_id,
    :public,
    :names,
    :aliases,
    :cpu_count,
    :memory_mb,
    :disk_size_mb,
    :created_at,
    :updated_at,
    :last_spawned_at,
    :spawn_count,
    :build_count,
    :envd_version,
    :build_status,
    :builds
  ]

  @doc false
  @spec from_api(map()) :: t()
  def from_api(m) when is_map(m) do
    %__MODULE__{
      template_id: m["templateID"],
      build_id: m["buildID"],
      public: m["public"],
      names: m["names"],
      aliases: m["aliases"],
      cpu_count: m["cpuCount"],
      memory_mb: m["memoryMB"],
      disk_size_mb: m["diskSizeMB"],
      created_at: m["createdAt"],
      updated_at: m["updatedAt"],
      last_spawned_at: m["lastSpawnedAt"],
      spawn_count: m["spawnCount"],
      build_count: m["buildCount"],
      envd_version: m["envdVersion"],
      build_status: m["buildStatus"],
      builds: decode_builds(m["builds"])
    }
  end

  defp decode_builds(nil), do: nil
  defp decode_builds(builds) when is_list(builds), do: Enum.map(builds, &TemplateBuild.from_api/1)
end

defmodule E2bEx.TemplateAlias do
  @moduledoc "Result of `GET /templates/aliases/:alias`."

  @type t :: %__MODULE__{template_id: String.t() | nil, public: boolean() | nil}

  defstruct [:template_id, :public]

  @doc false
  @spec from_api(map()) :: t()
  def from_api(m) when is_map(m), do: %__MODULE__{template_id: m["templateID"], public: m["public"]}
end

defmodule E2bEx.TemplateTag do
  @moduledoc "A tag assigned to a template build."

  @type t :: %__MODULE__{
          tag: String.t() | nil,
          build_id: String.t() | nil,
          created_at: String.t() | nil
        }

  defstruct [:tag, :build_id, :created_at]

  @doc false
  @spec from_api(map()) :: t()
  def from_api(m) when is_map(m) do
    %__MODULE__{tag: m["tag"], build_id: m["buildID"], created_at: m["createdAt"]}
  end
end
