# An explicitly authorized SANDBOX CONTRACT TEST of the existing HTTP adapter.
# This does not implement release publication or enable production writes.
alias Weld.Core.Identity
alias Weld.Shell.Hex
alias Weld.Hash

args = case System.argv() do ["--" | args] -> args; args -> args end
{opts, rest} = OptionParser.parse!(args, strict: [api_url: :string, repo_url: :string,
  public_key: :string, archive: :string, docs: :string, output: :string,
  evidence_path: :string, permit_sandbox_writes: :boolean, reconcile: :boolean])
required = [:api_url, :repo_url, :public_key, :archive, :docs, :output, :evidence_path]
unless rest == [] and Enum.all?(required, &is_binary(opts[&1])), do: raise("missing conformance options; see scripts/qc/README.md")
for url <- [opts[:api_url], opts[:repo_url]] do
  uri = URI.parse(url)
  forbidden = uri.host in ["hex.pm", "api.hex.pm", "repo.hex.pm", "hexdocs.pm"] or String.ends_with?(uri.host || "", ".hexdocs.pm")
  unless uri.scheme == "https" and is_nil(uri.userinfo) and is_nil(uri.query) and not forbidden,
    do: raise("conformance writes require a separately authorized HTTPS sandbox, never the public Hex service")
end
key = System.fetch_env!("WELD_QC_SANDBOX_API_KEY")
config = :hex_core.default_config() |> Map.merge(%{api_url: opts[:api_url], repo_url: opts[:repo_url],
  repo_public_key: File.read!(opts[:public_key]), api_key: key})
transport = Hex.http_transport(config)
package = Hex.package_observation!(opts[:archive])
_ = Hex.docs_observation!(opts[:docs])
name = package.metadata["name"]
version = package.metadata["version"]
unless String.starts_with?(name, "weld_qc_"), do: raise("sandbox package names must start with weld_qc_")
archive = File.read!(opts[:archive])
docs = File.read!(opts[:docs])
sha = %{package: Identity.raw(archive), docs: Identity.raw(docs)}
output = Path.expand(opts[:output])
route = opts[:evidence_path]
unless String.starts_with?(route, "weld-qc/") and not String.contains?(route, ["..", "?", "#", ":", "\\"]),
  do: raise("evidence-path must be a credential-free weld-qc/ sandbox API route")
read = fn ->
  case :hex_api.get(config, route) do
    {:ok, {200, _, %{"schema" => "weld.sandbox-receipts/1", "package" => ^name, "version" => ^version} = evidence}} -> evidence
    _ -> raise("sandbox has no supported authenticated request-body receipts; conformance remains unqualified")
  end
end
persist = fn operation, facts ->
  File.write!(Path.join(output, operation <> "-" <> Weld.Output.nonce() <> ".json"), Identity.canonical(facts), [:exclusive, :sync])
end
if opts[:reconcile] do
  unless File.regular?(Path.join(output, "intent.json")), do: raise("reconcile requires a previous exact sandbox intent")
  intent = Jason.decode!(File.read!(Path.join(output, "intent.json")))
  unless intent["package_sha256"] == sha.package and intent["docs_sha256"] == sha.docs and intent["destination"] == transport.trust.destination,
    do: raise("reconcile inputs differ from the previous sandbox intent")
else
  unless opts[:permit_sandbox_writes] == true, do: raise("pass --permit-sandbox-writes only after authorizing this exact sandbox package and endpoint")
  unless File.mkdir(output) == :ok, do: raise("output exists; use --reconcile, never repeat uncertain writes")
  preflight = read.()
  for part <- ["package_receipt", "docs_receipt"] do
    unless preflight[part] == %{"state" => "absent", "authoritative" => true},
      do: raise("sandbox preflight does not prove absence including staged requests")
  end
  intent = %{"schema" => "weld.sandbox-intent/1", "destination" => transport.trust.destination,
    "package" => name, "version" => version, "package_sha256" => sha.package, "docs_sha256" => sha.docs}
  File.write!(Path.join(output, "intent.json"), Identity.canonical(intent), [:exclusive, :sync])
  for {part, bytes} <- [package: archive, docs: docs] do
    if part == :docs do
      receipt = read.()["package_receipt"]
      unless receipt["state"] == "confirmed" and receipt["received_sha256"] == sha.package,
        do: raise("sandbox package is not confirmed; reconcile staged/unknown upload before any further test")
    end
    persist.("submitting", %{"part" => to_string(part), "sha256" => Map.fetch!(sha, part)})
    response = try do
      transport.write.(part, name, version, bytes)
    rescue
      _ -> {:error, :possible_send}
    catch
      _, _ -> {:error, :possible_send}
    end
    case response do
      {:ok, {status, _, _}} when status in 200..299 -> persist.("response", %{"part" => to_string(part), "http_status" => status})
      _ ->
        persist.("unknown", %{"part" => to_string(part), "code" => "possible_send_requires_reconcile"})
        raise("sandbox upload was not confirmed; only --reconcile is safe")
    end
  end
end
observation = read.()
checks = for {part, expected} <- sha do
  receipt = observation[to_string(part) <> "_receipt"]
  is_map(receipt) and receipt["state"] == "confirmed" and receipt["authoritative"] == true and
    receipt["received_sha256"] == expected and receipt["archive_sha256"] == expected
end
conformant = Enum.all?(checks) and observation["staged_readback_exercised"] == true and
  observation["tls_peer_verification"] == true and observation["signature_origin_verification"] == true
adapter_readback = Map.new([:package, :docs], fn part ->
  observation = try do
    case transport.read.(part, name, version) do
      {:ok, facts} when is_map(facts) ->
        facts |> Map.take([:state, :code, :sha256, :authoritative])
        |> Map.new(fn {key, value} -> {to_string(key), value} end)
      _ -> %{"state" => "unknown", "authoritative" => false}
    end
  rescue
    _ -> %{"state" => "unknown", "code" => "adapter_read_failed", "authoritative" => false}
  end
  {to_string(part), observation}
end)
# The sandbox supplies receipt facts; they must describe bytes recorded at its
# receiving HTTP boundary, not a checksum echoed back from the request client.
report = %{"schema" => "weld.hex-conformance-observation/2", "adapter" => "hex_core/0.21.1",
  "adapter_sha256" => Hash.sha256_file(to_string(:code.which(:hex_api_release))),
  "destination" => transport.trust.destination, "package_body_sha256" => sha.package,
  "docs_body_sha256" => sha.docs, "authenticated" => true,
  "conformant" => conformant, "production_enabled" => false,
  "adapter_readback" => adapter_readback,
  "scope" => "sandbox_receiver_receipts_do_not_qualify_public_docs_readback",
  "reason" => if(conformant, do: "sandbox_exact_bytes_and_staged_readback_observed", else: "unsupported_or_incomplete_authenticated_readback")}
persist.("observation", report)
IO.puts(Identity.canonical(report))
unless conformant, do: System.halt(2)
