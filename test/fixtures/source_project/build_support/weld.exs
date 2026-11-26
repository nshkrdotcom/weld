[
  schema: 2,
  workspace: [root: "..", projects: [".", "components/*", "extensions/*"]],
  artifacts: [
    sprout: [
      layout: :preserve,
      roots: ["."],
      preserve: [
        files: ~w(mix.exs VERSION components/pure/lib components/runtime/lib priv test README.md),
        inputs: [[path: "VERSION", type: :file]]
      ],
      verify: [hex_publish_check: false]
    ]
  ]
]
