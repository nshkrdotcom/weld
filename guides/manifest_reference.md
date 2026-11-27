# Manifest reference

Weld evaluates one trusted Elixir manifest, normally `build_support/weld.exs`. Evaluating that file and probing its Mix projects runs repository code. Work only with a trusted checkout. Probe VMs isolate host Mix/module state and clear unnecessary subprocess overrides; they are not a security sandbox for malicious source code.

The manifest must return a schema 2 keyword list. Every option object is closed: unknown fields and duplicate keys fail with a diagnostic path. Keyed collections also reject duplicates after atom/string identifiers are normalized. Defaults are applied once. No old schema, discovery fallback, layout alias, duplicate native package identity, or state migration is accepted.

Metadata is observed separately in `dev`, `test`, and `prod`, using bounded fresh VMs and one shared observation per project/environment for a command. This includes a production branch even when development and test happen to agree. Identical dependency declarations stay unchanged; conditional requirements retain only the environments where they are active. Mixed `only: [:docs, :test]` or docs/dev/test dependencies belong to both corresponding graph views and do not become runtime publication requirements.

Project app/version, package metadata, compiler implementation/options and application callbacks must stay stable across these observations. Test compiler roots may differ through their explicitly modeled test paths, but production roots must match development roots. Unsupported environment-dependent semantics are an error with the project, environment and field identified; they are never silently replaced by development values. Conditional declarations naming an unobserved custom environment must be made stable across the observed environments so Weld can preserve their explicit scope without guessing.

## Workspace and graph policy

```elixir
[
  schema: 2,
  workspace: [root: "..", projects: ["core/*", "apps/*", "extensions/*", "tooling/*"]],
  classify: [tooling: ["tooling/test_support"], proofs: [], ignored: []],
  publication: [
    internal_only: ["core/contracts"],
    separate: ["extensions/codec"],
    optional: [color: ["extensions/color"]]
  ],
  dependencies: [engine: [requirement: "~> 2.0", opts: []]],
  artifacts: [
    sdk: [
      layout: :components,
      roots: ["core/engine"],
      package: [name: "sdk", otp_app: :sdk, version: "2.0.0"],
      verify: [hex_publish_check: false]
    ]
  ]
]
```

This example assumes those projects exist and their real Mix declarations satisfy the graph. Classification and publication role are separate facts. Unclassified projects are runtime projects. Classification groups are disjoint; publication roles, including optional-feature membership, are disjoint. Unknown references, duplicate OTP apps, duplicate IDs and overlapping globs fail. Merely discovering a project does not select or publish it.

| Top-level field | Shape and behavior |
| --- | --- |
| `schema` | Required integer `2`. |
| `workspace` | Required `root` relative to manifest directory, plus nonempty explicit project directory globs in `projects`. Declare `"."` to include the root project. |
| `classify` | `tooling`, `proofs`, `ignored` lists of project IDs; all default empty. |
| `publication` | `internal_only`, `separate`, and `optional` feature-to-project lists; defaults empty. |
| `dependencies` | App-keyed canonical external declarations: `[requirement: string_or_nil, opts: keyword]`. |
| `project_inputs` | Project-ID-keyed lists of additional input declarations. |
| `artifacts` | Nonempty artifact-ID-keyed options. IDs are safe path segments and normalize to strings. |

The checkout root is Git's repository root. For non-Git development, an explicit `--root` supplies that locator; otherwise the declared workspace root is used. `workspace.root` selects where project globs expand, but project IDs, artifact roots, global inputs and documentation paths are always checkout-relative. For example, a discovery root `packages/sdk` with glob `apps/*` yields the project ID `packages/sdk/apps/client`. The manifest may sit elsewhere inside the same checkout. Portable inventories, Git source proofs and affected reports use those same paths; generated output targets are relative to the standalone project.

Discovery and source observations exclude `.git`, `.weld`, `deps`, `_build`, `.mix_sources.json`, `doc`, `dist` and `tmp`. Declaring a required input under an excluded directory fails as missing; it does not partially include generated state. The observation is bounded by 250,000 entries, including directories and special entries, and 512 MiB of file bytes.

A local path dependency resolves by its normalized declared path. A nonpath app dependency binds a discovered project only when identity is unambiguous and compatible. Canonical dependency overrides may select Hex or Git, preserve scopes, and cannot use `path`. An outside-checkout source path with an explicit canonical replacement is retained for operational source probing, but portable metadata records an opaque external input reference and locator digest. Such unknown source content disables proof reuse and keeps affected analysis conservative; no raw absolute external locator enters the portable plan. A Hex declaration needs a valid version requirement. Git/GitHub declarations may omit the requirement; `git` and `github`, Git and Hex options, and multiple `branch`/`tag`/`ref` selectors are rejected. A Git-only option needs a Git source. `only` and `targets` are atoms or nonempty atom lists; runtime/optional/override/submodules are booleans. Unsupported Mix options are rejected.

Remote Git requirements are supported for non-Hex artifacts. An effective `git` locator naming a local repository, including absolute paths, relative paths and `file://` URLs, is rejected before rendering. Components and flat can replace that source with a canonical remote Git or versioned Hex declaration; preserve requires changing the native declaration because it does not rewrite Mix code. Source local Git locators with a canonical replacement become opaque input references in portable metadata. Selected internal `path` dependencies retain their ordinary layout ownership rules.

## Artifact options

| Field | Shape and default |
| --- | --- |
| `layout` | Required `:components`, `:flat`, or `:preserve`. |
| `roots` | Required nonempty unique project IDs. |
| `include` | Explicit additional project seeds; default `[]`. |
| `features` | Declared optional feature names; default `[]`. |
| `external` | Reachable project IDs at which every dependency view stops; default `[]`. Disjoint from roots/includes/enabled features. |
| `inputs` | Checkout-relative structural declarations `[path: ..., type: :file/:tree/:glob, required: true]`; default `[]`. |
| `package` | Required for generated layouts, forbidden for preserve. |
| `docs` | Generated-layout documentation options; native preserve owns its docs configuration. |
| `files` | Generated-only `[docs: [], assets: []]`, containing checkout-relative files or trees. |
| `preserve` | Preserve-only `files` and additional project-relative structural `inputs`. |
| `flat` | Flat-only options described below. |
| `verify` | Verification policy described below. |

Optional features add explicit roots; they do not include all optional projects. `publication.separate` prevents silent composition but permits an artifact rooted at the separate project. An external cut must actually be reachable, must match the target's package identity/version, and cannot also be copied as source or support. A preserved project already declares the desired external package dependency in its native Mix file; Weld does not rewrite it.

### Generated package metadata

```elixir
package: [
  name: "sdk",
  otp_app: :sdk,
  version: "2.0.0",
  elixir: "~> 1.18",
  description: "Standalone SDK",
  licenses: ["MIT"],
  links: %{"Source" => "https://example.test/sdk"},
  dev_deps: [{:credo, "~> 1.7", only: [:dev, :test], runtime: false}]
]
```

Name, OTP app and semantic version are required. Elixir defaults to `~> 1.18`; description, licenses and links have documented generated defaults. Development dependencies must be versioned Hex dependencies scoped to dev/test and `runtime: false`. Generated dependencies are selected by the compiled graph, not pasted from arbitrary source dependencies.

`docs_main` is not a package key. Configure `docs.main`. A redundant generated `maintainers` field is omitted because Hex does not use it as authoritative maintainer ownership. Native preserve metadata remains owned by Mix/Hex.

### Documentation and root files

```elixir
docs: [
  main: "readme",
  source_url: "https://example.test/sdk",
  source_ref: "sdk-v2.0.0",
  logo: "assets/logo.svg",
  assets: %{"assets" => "assets"},
  extra_titles: %{"README.md" => "Overview"},
  groups_for_extras: [{"Start here", ["README.md", "guides/start.md"]}],
  mermaid: true,
  hook_file: "build_support/docs_hook.html"
],
files: [docs: ["README.md", "guides/start.md"], assets: ["assets"]]
```

Docs keys are `main` (default `readme`), `logo`, `homepage_url`, `source_url`, `source_ref`, `assets`, `extra_titles`, `groups_for_extras`, `mermaid` (default false), and `hook_file`. Assets and extra titles are string maps; groups are ordered label/path pairs. Referenced docs and assets must be covered by the planned files. Hook files are regular contained checkout files, require Mermaid, and are copied verbatim. Without a custom hook, generated Mermaid docs use the checked-in built-in hook. Use an immutable projection ref for source links.

### Additional and native inputs

```elixir
project_inputs: [
  "extensions/codec": [
    [path: "Makefile", type: :file, roles: [:native], target: :relative],
    [path: "native/pins", type: :tree, roles: [:native], target: :relative],
    [path: "VERSION", type: :file, roles: [:generation], target: :none],
    [path: "optional/*.h", type: :glob, roles: [:native], target: :relative, required: false]
  ]
]
```

Input roles are `:compile`, `:runtime`, `:native`, `:test`, `:docs`, `:metadata`, `:lock`, `:generation`, `:structure`, and `:verification`. Roles are nonempty and unique. Native/runtime/compile/docs roles publish by default when copied. Mixed publication and verification/structural roles require an explicit `publish: true` or `false`. `publish: true` requires `target: :relative`; `:none` represents input-only structural/recipe facts.

Paths are project-relative for `project_inputs`, checkout-relative for artifact `inputs`, and native-root-relative for `preserve.inputs`. `type` is explicitly `:file`, `:tree`, or `:glob`. `required` defaults true. Missing optional inputs remain absence/glob watches, so later appearance invalidates the relevant view. Inputs affect only artifacts that select, verify, or require their owning project at a boundary.

Components map relative inputs beneath the component. Flat maps them through its collision policy. Preserve requires copied inputs to be covered by `preserve.files`. Declare version/build helpers, native source, pinned checksums and custom compiler inputs. Never include credentials, caches, `.git`, or managed Weld state. Paths cannot escape the checkout, contain traversal/empty/backslash components, or follow unsafe symlinks/special files.

### Flat layout

`flat` accepts `readme`, `shared_test_configs: []`, `extra_test_deps: []`, and `test_support: []`. Readme is checkout-relative. The other project lists declare the exact supported set. If discovered support differs, compilation fails. Root/source test helpers are mapped deterministically; unsupported dynamic helper/config expressions fail with diagnostics.

Flat retains the explicit restriction against `verify.artifact_tests` and configured `smoke`; it verifies its mapped source suites. Use components or preserve when that contract is required. `flat` on another layout, or `preserve` on a generated layout, is rejected even when its value is empty.

### Preserve layout

```elixir
[
  schema: 2,
  workspace: [root: "..", projects: ["."]],
  artifacts: [
    native_sdk: [
      layout: :preserve,
      roots: ["."],
      preserve: [files: ["mix.exs", "lib", "test", "README.md", "LICENSE"]],
      verify: [hex_publish_check: false]
    ]
  ]
]
```

The list is an example for a project containing those paths. Add an existing `mix.lock`, config, compiler/include/native trees, helpers and all required support. Omit nonexistent files; missing lock is watched and qualification resolves its standalone lock. Preserve has exactly one root, no includes/features, and no generated package/docs/files override. Files are explicit disjoint project-relative paths; a parent plus one of its descendants is an error. Native `mix.exs` supplies all package identity and callbacks. See [preserved source projects](source_projects.md).

## Verification policy

`verify` accepts `artifact_tests: []` in stable declared order, `component_tests: false`, `hex_build: true`, `hex_publish_check: true`, `smoke: nil` or `[entry_file: "path"]`, and `context: []`.

Component tests are components-only. Preserve runs native tests rather than extra artifact suites. If Hex building is disabled, explicitly set `hex_publish_check: false`; contradictory settings fail. Gate records state exactly which checks ran and why an eligible gate was skipped. Disabling Hex does not mean omitting ordinary source/project qualification.

Context names declare public, nonsecret environment or external facts. Caller context is supplied through the command/API. Proof records use digests and explicit trust coordinates, not raw credential values or every inherited environment variable. Missing/opaque external facts make reuse ineligible. Declaring context is a responsibility contract, not enforcement that arbitrary Mix code reads only declared inputs.
