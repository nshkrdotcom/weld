# Consumer repository integration

Install Weld 0.20.0 only in the maintainer environment, with `runtime: false`. Downstream users consume a detached ordinary Mix project, a tracked projection branch or a Hex package. Do not add Weld to generated runtime dependencies. Declare all workspace projects and native inputs in schema 2. Resolve and lock published dependencies, then qualify consumers from a separate temporary directory without the source checkout or its path dependencies available. Verify both a base library and optional extension packages when applicable.
