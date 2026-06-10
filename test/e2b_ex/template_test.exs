defmodule E2bEx.TemplateTest do
  use ExUnit.Case, async: true
  alias E2bEx.{Template, TemplateBuild, TemplateAlias, TemplateTag}

  test "Template.from_api/1 maps fields and nested builds" do
    api = %{
      "templateID" => "tmpl_1",
      "buildID" => "build_1",
      "public" => true,
      "names" => ["team/base"],
      "cpuCount" => 2,
      "memoryMB" => 512,
      "spawnCount" => 5,
      "buildStatus" => "ready",
      "builds" => [%{"buildID" => "build_1", "status" => "ready"}]
    }

    t = Template.from_api(api)
    assert t.template_id == "tmpl_1"
    assert t.public == true
    assert t.spawn_count == 5
    assert [%TemplateBuild{build_id: "build_1", status: "ready"}] = t.builds
  end

  test "TemplateBuild.from_api/1 maps fields" do
    b = TemplateBuild.from_api(%{"buildID" => "b1", "status" => "building", "createdAt" => "t", "cpuCount" => 1, "memoryMB" => 256})
    assert b.build_id == "b1"
    assert b.status == "building"
    assert b.cpu_count == 1
  end

  test "TemplateAlias.from_api/1 maps fields" do
    a = TemplateAlias.from_api(%{"templateID" => "tmpl_1", "public" => false})
    assert a.template_id == "tmpl_1"
    assert a.public == false
  end

  test "TemplateTag.from_api/1 maps fields" do
    tag = TemplateTag.from_api(%{"tag" => "v1", "buildID" => "b1", "createdAt" => "t"})
    assert tag.tag == "v1"
    assert tag.build_id == "b1"
  end
end
