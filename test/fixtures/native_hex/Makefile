CC ?= cc
CFLAGS ?= -O2

$(OUTPUT)/weld_native_probe.so: c_src/native.c c_src/value.h
	$(CC) $(CFLAGS) -fPIC -shared -I"$(ERL_INCLUDE)" c_src/native.c -o "$@"
