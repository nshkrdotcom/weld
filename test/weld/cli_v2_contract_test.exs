defmodule Weld.CLIV2ContractTest do
  use ExUnit.Case, async: true
  alias Weld.{CLI, Error}

  test "the registry generates offline help for every command" do
    for command <- Map.keys(CLI.registry()) do
      assert CLI.help(command) =~ "mix weld #{command}"
      request = CLI.parse!(command, ["--help", "--format", "json"])
      assert request.options[:help]
      assert {:ok, help} = Weld.run(request)
      assert is_binary(help)
      assert CLI.exit_status(command, {:ok, help}) == 0
    end
  end

  test "all request conflicts fail during parsing before discovery" do
    for {command, args} <- [
      {"plan", ["--artifact", "one", "--all"]},
      {"graph", ["--all"]}, {"query", ["deps"]},
      {"project", ["--kind", "bundle"]}, {"project", ["--live"]},
      {"prepare", ["--fresh", "--reuse", "ctx"]},
      {"prepare", ["--context", "a", "--reuse", "b"]},
      {"track", ["--current", "--tag", "t", "--tag-release"]},
      {"track", []}, {"reconcile", []}, {"archive", ["--all"]},
      {"path", ["--kind", "run"]}, {"path", ["--run", "x"]},
      {"path", ["--kind", "run", "--run", "../escape"]},
      {"gc", ["--keep", "-1"]}, {"gc", ["--apply", "--dry-run"]},
      {"doctor", ["--fix"]}, {"plan", ["--format", "xml"]},
      {"plan", ["--format", "json", "--format", "text"]},
      {"release-plan", ["--check", "--no-check"]},
      {"affected", ["--base", "a", "--head", "b", "--task", "arbitrary"]}
    ] do
      assert_raise Error, fn -> CLI.parse!(command, args) end
    end
  end

  test "pin and context requests are fully validated and normalized" do
    id = String.duplicate("a", 64)
    assert CLI.parse!("track", ["--identity", id]).options[:identity] == id
    assert_raise Error, fn -> CLI.parse!("track", ["--identity", String.upcase(id)]) end
    assert_raise Error, fn -> CLI.parse!("track", ["--identity", id, "--current"]) end
    assert_raise Error, fn -> CLI.parse!("status", ["--identity", id, "--all"]) end
    request = CLI.parse!("prepare", ["--reuse", "public-context"])
    assert request.options[:context] == "public-context"
    assert request.options[:reuse] == "public-context"
    assert {:error, [%{code: :invalid_arguments}]} = Weld.run(%{command: "plan", options: [all: "yes"]})
    assert {:error, [%{code: :invalid_arguments}]} = Weld.run(%{command: "plan", unexpected: true})
  end

  test "exit statuses distinguish arguments plans effects external uncertainty and partial batches" do
    assert CLI.exit_status("plan", {:error, [CLI.diagnostic(:invalid_arguments, "bad")]}) == 2
    assert CLI.exit_status("project", {:error, [CLI.diagnostic(:unsafe_path, "bad", phase: :manifest)]}) == 2
    assert CLI.exit_status("verify", {:error, [CLI.diagnostic(:qualification_failed, "failed")]}) == 3
    assert CLI.exit_status("publish", {:ok, %{state: "unknown"}}) == 4
    assert CLI.exit_status("prepare", {:ok, %{partial_failure: true}}) == 5
    assert CLI.exit_status("plan", {:ok, %{results: [], partial_failure: false}}) == 0
    assert CLI.exit_status("plan", {:error, [%{"code" => "invalid_manifest", "phase" => "manifest"}]}) == 2
    assert CLI.exit_status("publish", {:error, [%{"code" => "unknown_publish_outcome"}]}) == 4
    assert CLI.exit_status("doctor", {:ok, %{errors: 1}}) == 3
    assert CLI.exit_status("status", {:ok, [%{state: :unprepared}]}) == 0
    assert CLI.exit_status("affected", {:ok, %{affected?: false, results: []}}) == 0
  end

  test "JSON key order and quoted recommendations are deterministic" do
    assert CLI.encode_json(%{z: [%{b: 2, a: 1}], a: true}) == ~s({"a":true,"z":[{"a":1,"b":2}]})
    assert CLI.quote_arg("a b'c") == "'a b'\\''c'"
    assert CLI.render_text("path", %{path: "/tmp/a path", state: :absent}) == "/tmp/a path"
  end
end
