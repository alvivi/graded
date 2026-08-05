-module(graded_pack_test_ffi).
-export([build_tarball/4, build_tarball_with_modes/4, unpack_inner/2,
         metadata_files/1]).

% Build a minimal hex tarball at OutPath (VERSION, metadata.config,
% contents.tar.gz, CHECKSUM), following hex_tarball's format closely enough for
% graded pack to patch it. InnerFiles is a list of {Path, Content} binaries; the
% metadata.config's files list mirrors those paths, formatted with the exact
% `{<<"files">>, [\n` marker pack's textual splice looks for.
build_tarball(OutPath, Name, Version, InnerFiles) ->
    build_tarball_with_modes(OutPath, Name, Version,
        [{P, C, 8#644} || {P, C} <- InnerFiles]).

% Same, with a per-file mode. Files are staged on disk and added by path,
% since erl_tar only takes modes from the filesystem.
build_tarball_with_modes(OutPath, Name, Version, InnerFiles) ->
    Paths = [P || {P, _, _} <- InnerFiles],
    Out = binary_to_list(OutPath),

    Staging = Out ++ ".staging",
    lists:foreach(fun({P, C, Mode}) ->
        Abs = filename:join(Staging, binary_to_list(P)),
        ok = filelib:ensure_dir(Abs),
        ok = file:write_file(Abs, C),
        ok = file:change_mode(Abs, Mode)
    end, InnerFiles),
    InnerTmp = Out ++ ".inner",
    {ok, T} = erl_tar:open(InnerTmp, [write]),
    lists:foreach(fun(P) ->
        Path = binary_to_list(P),
        ok = erl_tar:add(T, filename:join(Staging, Path), Path, [])
    end, Paths),
    ok = erl_tar:close(T),
    {ok, InnerBytes} = file:read_file(InnerTmp),
    ok = file:delete(InnerTmp),
    ok = file:del_dir_r(Staging),
    Contents = zlib:gzip(InnerBytes),

    Version0 = <<"3">>,
    Meta = metadata(Name, Version, Paths),
    Hash = crypto:hash(sha256, [Version0, Meta, Contents]),
    Checksum = binary:encode_hex(Hash, uppercase),

    {ok, O} = erl_tar:open(Out, [write]),
    ok = erl_tar:add(O, Version0, "VERSION", []),
    ok = erl_tar:add(O, Meta, "metadata.config", []),
    ok = erl_tar:add(O, Contents, "contents.tar.gz", []),
    ok = erl_tar:add(O, Checksum, "CHECKSUM", []),
    ok = erl_tar:close(O),
    nil.

% The metadata.config files list of a tarball, for asserting a re-packed
% archive lists each entry exactly once.
metadata_files(TarPath) ->
    {ok, Outer} = erl_tar:extract(binary_to_list(TarPath),
        [memory, {files, ["metadata.config"]}]),
    MetaBin = proplists:get_value("metadata.config", Outer),
    [unicode:characters_to_binary(F) || F <- graded_pack_ffi:files_of(MetaBin)].

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
