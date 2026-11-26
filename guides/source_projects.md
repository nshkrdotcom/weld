# Preserved source projects

A `:preserve` layout retains an existing root or nested Mix project. Declare exactly one root and explicitly list the files and directories required for independent verification in `preserve.files`. Mix owns the Hex package metadata and allowlist. Include test support, scripts and configuration needed by verification; they need not enter the published archive. Path dependencies must resolve within the declared detached project or be converted into proper external requirements by the artifact policy.

Use `mix weld project --kind full`, `mix weld verify`, and `mix weld prepare`. Live copies are only for development. A qualified full copy must be usable after removing access to the original checkout. Consumer projects should use ordinary Mix dependencies, not Weld.
