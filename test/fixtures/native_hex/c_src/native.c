#include "erl_nif.h"
#include "value.h"

static ERL_NIF_TERM value(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  (void)argv;
  return enif_make_int(env, WELD_NATIVE_VALUE);
}

static ErlNifFunc functions[] = {{"value", 0, value, 0}};
ERL_NIF_INIT(Elixir.WeldNativeProbe, functions, NULL, NULL, NULL, NULL)
