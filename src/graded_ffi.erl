-module(graded_ffi).
-export([read_stdin/0]).

read_stdin() ->
    read_stdin(<<>>).

read_stdin(Acc) ->
    case io:get_line(standard_io, <<>>) of
        eof -> Acc;
        {error, _} -> Acc;
        Line ->
            LineBin = unicode:characters_to_binary(Line),
            read_stdin(<<Acc/binary, LineBin/binary>>)
    end.
