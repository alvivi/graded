-module(graded_ffi).
-export([read_stdin/0]).

% Read all of standard input to EOF and return it as a single binary.
read_stdin() ->
    unicode:characters_to_binary(read_lines(standard_io)).

read_lines(Device) ->
    case io:get_line(Device, "") of
        eof -> [];
        {error, _} -> [];
        Line -> [Line | read_lines(Device)]
    end.
