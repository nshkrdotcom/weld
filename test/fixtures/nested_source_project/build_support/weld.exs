[
  schema: 2,
  workspace: [root: "..", projects: [".", "extensions/*"]],
  artifacts: [
    workshop_palette: [
      layout: :preserve,
      roots: ["extensions/palette"],
      external: ["."],
      preserve: [
        files: ~w(mix.exs VERSION build_support source priv checks),
        inputs: [[path: "VERSION", type: :file], [path: "build_support/package.exs", type: :file]]
      ],
      verify: [hex_publish_check: false]
    ]
  ]
]
