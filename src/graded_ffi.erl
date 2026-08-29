-module(graded_ffi).
-export([read_stdin/0, priv_directory/0, version/0]).

% Read all of standard input to EOF, as `{ok, Binary}` or `{error, Reason}`.
% The read is set to UTF-8 explicitly, so the two targets agree on encoding as
% well as on failure: a mid-read error is reported rather than folded into eof,
% which truncated the input and let `format` write a shortened file back.
read_stdin() ->
    _ = io:setopts(standard_io, [{encoding, utf8}]),
    case read_lines(standard_io) of
        {error, Reason} ->
            {error, Reason};
        {ok, Lines} ->
            case unicode:characters_to_binary(Lines) of
                Binary when is_binary(Binary) -> {ok, Binary};
                _ -> {error, <<"stdin could not be read: not valid UTF-8">>}
            end
    end.

% graded's own `priv` directory, located via the loaded application rather than
% the process working directory. Absolute when graded runs from a release or
% erlang-shipment, relative when run in-tree, but always anchored on the install
% location. `{error, nil}` when the application is not loaded.
priv_directory() ->
    case code:priv_dir(graded) of
        {error, _} -> {error, nil};
        Dir -> {ok, unicode:characters_to_binary(Dir)}
    end.

% graded's own version, read from the loaded application's `vsn` (sourced from
% `gleam.toml` at build time) rather than hardcoded. `<<"unknown">>` when the
% application key can't be resolved.
version() ->
    _ = application:load(graded),
    case application:get_key(graded, vsn) of
        {ok, Vsn} -> unicode:characters_to_binary(Vsn);
        _ -> <<"unknown">>
    end.

read_lines(Device) ->
    case io:get_line(Device, "") of
        eof ->
            {ok, []};
        {error, Reason} ->
            {error, read_error(Reason)};
        Line ->
            case read_lines(Device) of
                {ok, Rest} -> {ok, [Line | Rest]};
                {error, Reason} -> {error, Reason}
            end
    end.

% The sentence both targets word a read failure with, the platform's own reason
% after it.
read_error(Reason) ->
    unicode:characters_to_binary(
        io_lib:format("stdin could not be read: ~p", [Reason])
    ).
