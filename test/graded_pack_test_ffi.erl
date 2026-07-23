-module(graded_pack_test_ffi).
-export([build_tarball/4, unpack_inner/2]).

% Build a minimal hex tarball at OutPath (VERSION, metadata.config,
% contents.tar.gz, CHECKSUM), following hex_tarball's format closely enough for
% graded pack to patch it. InnerFiles is a list of {Path, Content} binaries; the
% metadata.config's files list mirrors those paths, formatted with the exact
% `{<<"files">>, [\n` marker pack's textual splice looks for.
build_tarball(OutPath, Name, Version, InnerFiles) ->
    Paths = [P || {P, _} <- InnerFiles],
    Out = binary_to_list(OutPath),

    InnerTmp = Out ++ ".inner",
    {ok, T} = erl_tar:open(InnerTmp, [write]),
    lists:foreach(fun({P, C}) -> ok = erl_tar:add(T, C, binary_to_list(P), []) end,
                  InnerFiles),
    ok = erl_tar:close(T),
    {ok, InnerBytes} = file:read_file(InnerTmp),
    ok = file:delete(InnerTmp),
    Contents = zlib:gzip(InnerBytes),

    Version0 = <<"3">>,
    Meta = metadata(Name, Version, Paths),
    Hash = crypto:hash(sha256, <<Version0/binary, Meta/binary, Contents/binary>>),
    Checksum = binary:encode_hex(Hash, uppercase),

    {ok, O} = erl_tar:open(Out, [write]),
    ok = erl_tar:add(O, Version0, "VERSION", []),
    ok = erl_tar:add(O, Meta, "metadata.config", []),
    ok = erl_tar:add(O, Contents, "contents.tar.gz", []),
    ok = erl_tar:add(O, Checksum, "CHECKSUM", []),
    ok = erl_tar:close(O),
    nil.

% Unpack a tarball's inner contents (contents.tar.gz) into DestDir, as `gleam`
% does when installing a dependency.
unpack_inner(TarPath, DestDir) ->
    {ok, Outer} = erl_tar:extract(binary_to_list(TarPath), [memory]),
    Contents = proplists:get_value("contents.tar.gz", Outer),
    ok = filelib:ensure_path(DestDir),
    ok = erl_tar:extract({binary, zlib:gunzip(Contents)},
                         [{cwd, binary_to_list(DestDir)}]),
    nil.

metadata(Name, Version, Paths) ->
    FilesEntries = [["  <<\"", P, "\"/utf8>>"] || P <- Paths],
    FilesList = ["{<<\"files\">>, [\n",
                 lists:join(",\n", FilesEntries), "]}.\n"],
    iolist_to_binary([
        "{<<\"name\">>, <<\"", Name, "\"/utf8>>}.\n",
        "{<<\"version\">>, <<\"", Version, "\"/utf8>>}.\n",
        FilesList
    ]).
