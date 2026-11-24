# The public package is the repository root. The full verification copy also
# carries the maintainer suite. The Hex allowlist remains owned by mix.exs.
root = Path.expand("..", __DIR__)
lock = if File.regular?(Path.join(root, "mix.lock")), do: ["mix.lock"], else: []

[
  workspace: [root: "..", project_globs: ["."]],
  artifacts: [
    weld: [
      mode: :source_project,
      roots: ["."],
      source_project: [
        files: ~w(mix.exs .formatter.exs .credo.exs README.md CHANGELOG.md LICENSE AGENTS.md lib assets guides scripts test build_support) ++ lock,
        structural_inputs: ["mix.exs"]
      ],
      package: [
        name: "weld",
        otp_app: :weld,
        version: "0.15.0",
        elixir: "~> 1.18",
        description: "Deterministic Hex package projection for Elixir monorepos"
      ],
      verify: [hex_build: true, hex_publish: true]
    ]
  ]
]
