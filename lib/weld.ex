defmodule Weld do
  @moduledoc """
  Deterministic Hex package projection for Elixir monorepos.
  """

  alias Weld.Audit
  alias Weld.Builder
  alias Weld.Manifest

  @doc """
  Builds a standalone publishable projection from a manifest file.
  """
  @spec build!(Path.t(), keyword()) :: Path.t()
  def build!(manifest_path, opts \\ []) do
    manifest_path
    |> Manifest.load!()
    |> Builder.build!(opts)
  end

  @doc """
  Audits a projection manifest for OTP app identity risks.
  """
  @spec audit!(Path.t()) :: Weld.Audit.Report.t()
  def audit!(manifest_path) do
    manifest = Manifest.load!(manifest_path)
    report = Audit.scan!(manifest)

    if manifest.mode == :strict_library_bundle and report.findings != [] do
      details =
        report.findings
        |> Enum.map_join(", ", fn finding ->
          "#{finding.pattern} at #{finding.file}:#{finding.line}"
        end)

      raise Weld.Error, "strict library bundle rejected app-identity-sensitive code: #{details}"
    end

    report
  end

  @doc """
  Audits and builds a projection, then runs compile/docs/package verification in
  the generated directory.
  """
  @spec verify!(Path.t(), keyword()) :: %{audit: Weld.Audit.Report.t(), build_path: Path.t()}
  def verify!(manifest_path, opts \\ []) do
    report = audit!(manifest_path)
    build_path = build!(manifest_path, opts)

    Builder.verify_build!(build_path)

    %{audit: report, build_path: build_path}
  end
end
