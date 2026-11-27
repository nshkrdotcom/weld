# Native qualification fixture

This package compiles a C NIF from shipped C and header inputs, checks their
pinned SHA-256 values, and copies a declared bootstrap input into the consumer's
build `priv` directory. It needs a C compiler, Make, and the running OTP headers.
It downloads no native source. The source, Hex consumer, and offline rebuild
must all return 42 and read the relocated bootstrap payload.
