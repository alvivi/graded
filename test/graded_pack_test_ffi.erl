-module(graded_pack_test_ffi).
-export([build_tarball/4, build_tarball_with_modes/4,
         build_tarball_with_raw_names/4, build_outer_tarball/2, unpack_inner/2,
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
    Contents = inner_gzip(Out, Staging, fun(T) ->
        lists:foreach(fun(P) ->
            Path = binary_to_list(P),
            ok = erl_tar:add(T, filename:join(Staging, Path), Path, [])
        end, Paths)
    end),
    write_outer(Out, Name, Version, Paths, Contents).

% Build a tarball whose inner entry names are stored *verbatim*, including names
% no legitimate hex tarball carries: an absolute path, a `..` component, a
% non-regular member. This is a weapon — it exists to construct the malicious
% archives `graded pack` has to refuse, and belongs in test/ only.
%
% Members is a list of {regular, Name, Content} or {symlink, Name, Target}. A
% regular member is added from a binary, so an arbitrary name is stored without
% ever being staged on disk — staging an absolute name would write to the host
% path the fixture is meant to describe, not create. erl_tar has no binary add
% for a link, so a symlink member is staged for real and added by path; its own
% name must therefore be relative.
build_tarball_with_raw_names(OutPath, Name, Version, Members) ->
    Out = binary_to_list(OutPath),
    Staging = Out ++ ".staging",
    Contents = inner_gzip(Out, Staging, fun(T) ->
        lists:foreach(fun(M) -> add_member(T, Staging, M) end, Members)
    end),
    write_outer(Out, Name, Version, [member_name(M) || M <- Members], Contents).

% Build an outer tar holding exactly Members ({Name, Content} binaries) and
% nothing else, for the malformed-archive diagnostics: a missing member, a
% metadata.config that does not parse, a contents.tar.gz that is not gzip.
build_outer_tarball(OutPath, Members) ->
    write_tar(binary_to_list(OutPath), Members).

% Write a tar of {Name, Content} binaries. erl_tar has no build-to-memory mode,
% so the inner tar goes through a scratch file its caller names.
write_tar(Path, Members) ->
    {ok, T} = erl_tar:open(Path, [write]),
    lists:foreach(fun({N, C}) ->
        ok = erl_tar:add(T, C, binary_to_list(N), [])
    end, Members),
    ok = erl_tar:close(T),
    nil.

% The gzipped inner tar AddFun writes, with the scratch file and staging
% directory it needed cleaned up behind it.
inner_gzip(Out, Staging, AddFun) ->
    InnerTmp = Out ++ ".inner",
    {ok, T} = erl_tar:open(InnerTmp, [write]),
    AddFun(T),
    ok = erl_tar:close(T),
    {ok, InnerBytes} = file:read_file(InnerTmp),
    ok = file:delete(InnerTmp),
    _ = file:del_dir_r(Staging),
    zlib:gzip(InnerBytes).

member_name({regular, Name, _}) -> Name;
member_name({symlink, Name, _}) -> Name.

add_member(T, _Staging, {regular, Name, Content}) ->
    ok = erl_tar:add(T, Content, binary_to_list(Name), []);
add_member(T, Staging, {symlink, Name, Target}) ->
    Rel = binary_to_list(Name),
    relative = filename:pathtype(Rel),
    Abs = filename:join(Staging, Rel),
    ok = filelib:ensure_dir(Abs),
    ok = file:make_symlink(binary_to_list(Target), Abs),
    ok = erl_tar:add(T, Abs, Rel, []).

% The VERSION / metadata.config / contents.tar.gz / CHECKSUM quartet, with the
% metadata files list mirroring Paths so pack's files-list assertion passes and
% the entry-name guard is what rejects a crafted archive.
write_outer(Out, Name, Version, Paths, Contents) ->
    Version0 = <<"3">>,
    Meta = metadata(Name, Version, Paths),
    Hash = crypto:hash(sha256, [Version0, Meta, Contents]),
    Checksum = binary:encode_hex(Hash, uppercase),

    write_tar(Out, [{<<"VERSION">>, Version0},
                    {<<"metadata.config">>, Meta},
                    {<<"contents.tar.gz">>, Contents},
                    {<<"CHECKSUM">>, Checksum}]).

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
