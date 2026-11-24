[
  workspace: [root: "..", project_globs: ["extensions/*"]],
  artifacts: [
    workshop_palette: [
      mode: :source_project,
      roots: ["extensions/palette"],
      external_projects: ["."],
      source_project: [
        files: ~w(mix.exs VERSION build_support source priv checks),
        structural_inputs: ["VERSION", "build_support/package.exs"]
      ],
      package: [
        name: "workshop_palette",
        otp_app: :workshop_palette,
        version: "0.1.0",
        description: "Portable workshop palette"
      ],
      verify: [hex_publish: false]
    ]
  ]
]
