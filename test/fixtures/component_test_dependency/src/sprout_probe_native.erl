-module(sprout_probe_native).
-export([value/0]).
-include("sprout_probe.hrl").

value() -> ?PROBE_VALUE.
