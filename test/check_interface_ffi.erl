-module(check_interface_ffi).
-export([run/1]).

%% Run a shell command, returning its combined output. Only used to ask the
%% compiler for the package interface; nothing parses the result.
run(Command) ->
    list_to_binary(os:cmd(binary_to_list(Command) ++ " 2>&1")).
