[
  workspace: [root: "..", project_globs: ["components/*", "extensions/*"]],
  artifacts: [
    sprout: [
      mode: :source_project,
      roots: ["."],
      source_project: [
        files: ~w(mix.exs VERSION components/pure/lib components/runtime/lib priv test README.md),
        structural_inputs: ["VERSION"]
      ],
      package: [name: "sprout", otp_app: :sprout, version: "0.1.0", description: "Sprout"],
      output: [],
      verify: [hex_publish: false]
    ]
  ]
]
