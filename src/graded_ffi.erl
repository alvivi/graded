-module(graded_ffi).
-export([read_stdin/0, priv_directory/0]).

% Read all of standard input to EOF and return it as a single binary.
read_stdin() ->
    unicode:characters_to_binary(read_lines(standard_io)).

% graded's own `priv` directory, located via the loaded application rather than
% the process working directory. Absolute when graded runs from a release or
% erlang-shipment, relative when run in-tree, but always anchored on the install
% location. `{error, nil}` when the application is not loaded.
priv_directory() ->
    case code:priv_dir(graded) of
        {error, _} -> {error, nil};
        Dir -> {ok, unicode:characters_to_binary(Dir)}
    end.

read_lines(Device) ->
    case io:get_line(Device, "") of
        eof -> [];
        {error, _} -> [];
        Line -> [Line | read_lines(Device)]
    end.
