-module(inactive_commands_test_ffi).
-export([erts_root/0]).

% The root of the Erlang installation the tests run on.
erts_root() ->
    list_to_binary(code:root_dir()).
