-module(graded_pack_ffi).
-export([inject_spec/4, verify_tarball/2, read_package_identity/1]).

% Inject a `.graded` spec into a hex tarball, following hex_tarball.erl's
% mechanics:
%   - gunzip contents.tar.gz, add the spec to the inner tar, re-gzip
%   - splice the archive-relative spec path into metadata.config's files list
%   - assert the metadata files list equals the inner tar contents
%   - recompute the inner checksum over VERSION ++ metadata ++ contents.tar.gz
%   - rebuild the outer tar (VERSION, metadata.config, contents.tar.gz, CHECKSUM)
% Returns {ok, Checksum} (uppercase hex) or {error, Reason} (a binary message).
inject_spec(InTar, SpecBin, EntryName, OutTar) ->
    try
        InTarPath = unicode:characters_to_list(InTar),
        OutTarPath = unicode:characters_to_list(OutTar),
        {ok, Outer} = erl_tar:extract(InTarPath, [memory]),
        Version = proplists:get_value("VERSION", Outer),
        MetaBin = proplists:get_value("metadata.config", Outer),
        Contents = proplists:get_value("contents.tar.gz", Outer),
        Entry = unicode:characters_to_list(EntryName),

        % inner tar: extract, add spec, re-create, re-gzip.
        {ok, Inner} = erl_tar:extract({binary, zlib:gunzip(Contents)}, [memory]),
        InnerTmp = OutTarPath ++ ".inner",
        {ok, T} = erl_tar:open(InnerTmp, [write]),
        lists:foreach(fun({N, B}) -> ok = erl_tar:add(T, B, N, []) end, Inner),
        ok = erl_tar:add(T, SpecBin, Entry, []),
        ok = erl_tar:close(T),
        {ok, InnerBytes} = file:read_file(InnerTmp),
        ok = file:delete(InnerTmp),
        NewContents = zlib:gzip(InnerBytes),

        % metadata: textually insert the spec path as the first files entry,
        % preserving hex's <<"..."/utf8>> formatting and all other bytes.
        Marker = <<"{<<\"files\">>, [\n">>,
        NewLine = iolist_to_binary(["  <<\"", EntryName, "\"/utf8>>,\n"]),
        NewMeta = binary_replace_once(MetaBin, Marker,
            <<Marker/binary, NewLine/binary>>),
        NewMeta =:= MetaBin andalso throw({graded_error,
            <<"metadata.config files-list marker not found">>}),

        % assert the metadata files list matches the inner contents as sets.
        InnerNames = lists:sort([Entry | [N || {N, _} <- Inner]]),
        MetaFiles = lists:sort(files_of(NewMeta)),
        InnerNames =:= MetaFiles orelse throw({graded_error,
            <<"metadata files list does not match inner tar contents">>}),

        % inner checksum over the final bytes.
        Hash = crypto:hash(sha256,
            <<Version/binary, NewMeta/binary, NewContents/binary>>),
        Checksum = binary:encode_hex(Hash, uppercase),

        % rebuild outer tar.
        {ok, O} = erl_tar:open(OutTarPath, [write]),
        ok = erl_tar:add(O, Version, "VERSION", []),
        ok = erl_tar:add(O, NewMeta, "metadata.config", []),
        ok = erl_tar:add(O, NewContents, "contents.tar.gz", []),
        ok = erl_tar:add(O, Checksum, "CHECKSUM", []),
        ok = erl_tar:close(O),
        {ok, Checksum}
    catch
        throw:{graded_error, Msg} -> {error, Msg};
        _:Reason -> {error, format_reason(Reason)}
    end.

% Assert a written tarball is internally consistent: the stored CHECKSUM equals
% the recomputed inner checksum, the metadata files list equals the inner tar
% contents, and EntryName appears in both. Returns ok or {error, Reason}.
verify_tarball(TarPath, EntryName) ->
    try
        {ok, Outer} = erl_tar:extract(unicode:characters_to_list(TarPath), [memory]),
        Version = proplists:get_value("VERSION", Outer),
        MetaBin = proplists:get_value("metadata.config", Outer),
        Contents = proplists:get_value("contents.tar.gz", Outer),
        Stored = proplists:get_value("CHECKSUM", Outer),
        Entry = unicode:characters_to_list(EntryName),

        Hash = crypto:hash(sha256,
            <<Version/binary, MetaBin/binary, Contents/binary>>),
        Recomputed = binary:encode_hex(Hash, uppercase),
        Stored =:= Recomputed orelse throw({graded_error,
            <<"stored CHECKSUM does not match recomputed inner checksum">>}),

        {ok, Inner} = erl_tar:extract({binary, zlib:gunzip(Contents)}, [memory]),
        InnerNames = lists:sort([N || {N, _} <- Inner]),
        MetaFiles = lists:sort(files_of(MetaBin)),
        InnerNames =:= MetaFiles orelse throw({graded_error,
            <<"metadata files list does not match inner tar contents">>}),
        lists:member(Entry, InnerNames) orelse throw({graded_error,
            <<"injected spec not present in the tarball">>}),
        {ok, nil}
    catch
        throw:{graded_error, Msg} -> {error, Msg};
        _:Reason -> {error, format_reason(Reason)}
    end.

% Read {name, version} from a hex tarball's metadata.config. Both are returned
% as binaries. {error, Reason} if the tarball or fields can't be read.
read_package_identity(TarPath) ->
    try
        {ok, Outer} = erl_tar:extract(unicode:characters_to_list(TarPath), [memory]),
        MetaBin = proplists:get_value("metadata.config", Outer),
        Terms = config_terms(MetaBin),
        Name = to_binary(proplists:get_value(<<"name">>, Terms)),
        Version = to_binary(proplists:get_value(<<"version">>, Terms)),
        case {Name, Version} of
            {undefined, _} -> {error, <<"tarball metadata has no name">>};
            {_, undefined} -> {error, <<"tarball metadata has no version">>};
            _ -> {ok, {Name, Version}}
        end
    catch
        _:Reason -> {error, format_reason(Reason)}
    end.

% The files list from a metadata.config binary, as a list of charlists.
files_of(MetaBin) ->
    Terms = config_terms(MetaBin),
    [unicode:characters_to_list(F)
     || F <- proplists:get_value(<<"files">>, Terms, [])].

% Parse a metadata.config binary into a proplist of Erlang terms. hex writes it
% as a sequence of dot-terminated terms.
config_terms(Bin) ->
    {ok, Tokens, _} = erl_scan:string(unicode:characters_to_list(Bin)),
    parse_terms(Tokens, []).

parse_terms([], Acc) -> lists:reverse(Acc);
parse_terms(Tokens, Acc) ->
    {Before, [Dot | Rest]} = lists:splitwith(
        fun({dot, _}) -> false; (_) -> true end, Tokens),
    {ok, Term} = erl_parse:parse_term(Before ++ [Dot]),
    parse_terms(Rest, [Term | Acc]).

to_binary(undefined) -> undefined;
to_binary(V) when is_binary(V) -> V;
to_binary(V) when is_list(V) -> unicode:characters_to_binary(V).

binary_replace_once(Bin, From, To) ->
    case binary:match(Bin, From) of
        nomatch -> Bin;
        {Start, Len} ->
            <<Pre:Start/binary, _:Len/binary, Post/binary>> = Bin,
            <<Pre/binary, To/binary, Post/binary>>
    end.

format_reason(Reason) ->
    unicode:characters_to_binary(io_lib:format("~p", [Reason])).
