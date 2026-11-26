# The public package is the repository root. The full verification copy also
# carries the maintainer suite. The Hex allowlist remains owned by mix.exs.
root = Path.expand("..", __DIR__)
lock = if File.regular?(Path.join(root, "mix.lock")), do: ["mix.lock"], else: []

[
  schema: 2,
  workspace: [root: "..", projects: ["."]],
  artifacts: [
    weld: [
      layout: :preserve,
      roots: ["."],
      preserve: [
        files: ~w(mix.exs .formatter.exs .credo.exs README.md CHANGELOG.md LICENSE AGENTS.md lib assets guides scripts test build_support) ++ lock,
        inputs: [[path: "mix.exs", type: :file]]
      ],
      verify: [hex_build: true, hex_publish_check: false]
    ]
  ]
]
