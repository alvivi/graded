-module(graded_pack_ffi).
-export([inject_spec/4, verify_tarball/2, read_package_identity/1, files_of/1,
         reserve_path/1]).

% Atomically reserve Path for this invocation: an O_EXCL create, which fails
% with eexist on any existing path and refuses to follow symlinks — a dangling
% symlink is rejected rather than followed and written through. Returns
% {ok, nil} or {error, Reason}.
reserve_path(Path) ->
    case file:open(unicode:characters_to_list(Path), [write, exclusive]) of
        {ok, Fd} ->
            ok = file:close(Fd),
            {ok, nil};
        {error, Reason} ->
            {error, format_reason(Reason)}
    end.

% Inject a `.graded` spec into a hex tarball, following hex_tarball.erl's
% mechanics:
%   - gunzip contents.tar.gz, add the spec to the inner tar, re-gzip
%   - splice the archive-relative spec path into metadata.config's files list
%   - assert the metadata files list equals the inner tar contents
%   - recompute the inner checksum over VERSION ++ metadata ++ contents.tar.gz
%   - rebuild the outer tar (VERSION, metadata.config, contents.tar.gz, CHECKSUM)
% Re-running on an already-packed tarball replaces the spec entry rather than
% appending a duplicate, so the result stays canonical.
% Returns {ok, Checksum} (uppercase hex) or {error, Reason} (a binary message).
inject_spec(InTar, SpecBin, EntryName, OutTar) ->
    OutTarPath = unicode:characters_to_list(OutTar),
    % All scratch state lives inside one exclusively-created work directory, so
    % cleanup only ever deletes what this invocation created — a pre-existing
    % path with the same name is an error, never a recursive delete.
    WorkDir = OutTarPath ++ ".work",
    case file:make_dir(WorkDir) of
        ok ->
            try
                do_inject(unicode:characters_to_list(InTar), SpecBin,
                    unicode:characters_to_list(EntryName), OutTarPath, WorkDir)
            catch
                throw:{graded_error, Msg} -> {error, Msg};
                _:Reason -> {error, format_reason(Reason)}
            after
                file:del_dir_r(WorkDir)
            end;
        {error, eexist} ->
            {error, iolist_to_binary(["scratch directory already exists: ",
                WorkDir, "; remove it and retry"])};
        {error, Reason} ->
            {error, format_reason(Reason)}
    end.

do_inject(InTarPath, SpecBin, Entry, OutTarPath, WorkDir) ->
    InnerTmp = filename:join(WorkDir, "inner.tar"),
    InnerDir = filename:join(WorkDir, "contents"),
    assert_safe_name(Entry),
    {ok, Outer} = erl_tar:extract(InTarPath, [memory]),
    Version = proplists:get_value("VERSION", Outer),
    MetaBin = proplists:get_value("metadata.config", Outer),
    Contents = proplists:get_value("contents.tar.gz", Outer),

    % inner tar: unpack to disk (restoring each entry's mode), re-add every
    % entry by path — erl_tar only takes modes from the filesystem, a binary
    % add silently writes 0644 — and replace any existing spec entry.
    InnerRaw = zlib:gunzip(Contents),
    {ok, Table} = erl_tar:table({binary, InnerRaw}, [verbose]),
    assert_safe_table(Table),
    ok = file:make_dir(InnerDir),
    ok = erl_tar:extract({binary, InnerRaw}, [{cwd, InnerDir}]),
    Names = [N || {N, regular, _, _, _, _, _} <- Table, N =/= Entry],
    {ok, T} = erl_tar:open(InnerTmp, [write]),
    lists:foreach(fun(N) ->
        ok = erl_tar:add(T, filename:join(InnerDir, N), N, [])
    end, Names),
    ok = erl_tar:add(T, SpecBin, Entry, []),
    ok = erl_tar:close(T),
    {ok, InnerBytes} = file:read_file(InnerTmp),
    NewContents = zlib:gzip(InnerBytes),

    % metadata: textually insert the spec path as the first files entry,
    % preserving hex's <<"..."/utf8>> formatting and all other bytes. A
    % re-run finds the path already listed and leaves the metadata alone.
    NewMeta = case lists:member(Entry, files_of(MetaBin)) of
        true -> MetaBin;
        false ->
            Marker = <<"{<<\"files\">>, [\n">>,
            NewLine = iolist_to_binary(["  <<\"", Entry, "\"/utf8>>,\n"]),
            Spliced = binary:replace(MetaBin, Marker,
                <<Marker/binary, NewLine/binary>>),
            Spliced =:= MetaBin andalso throw({graded_error,
                <<"metadata.config files-list marker not found">>}),
            Spliced
    end,

    assert_files_match(NewMeta, [Entry | Names]),

    % inner checksum over the final bytes.
    Checksum = checksum(Version, NewMeta, NewContents),

    % rebuild outer tar.
    {ok, O} = erl_tar:open(OutTarPath, [write]),
    ok = erl_tar:add(O, Version, "VERSION", []),
    ok = erl_tar:add(O, NewMeta, "metadata.config", []),
    ok = erl_tar:add(O, NewContents, "contents.tar.gz", []),
    ok = erl_tar:add(O, Checksum, "CHECKSUM", []),
    ok = erl_tar:close(O),
    {ok, Checksum}.

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

        Stored =:= checksum(Version, MetaBin, Contents) orelse throw({graded_error,
            <<"stored CHECKSUM does not match recomputed inner checksum">>}),

        % The table, not a memory extract: an extract yields regular members
        % only, so it would certify a strict subset of what the archive carries.
        {ok, Table} = erl_tar:table({binary, zlib:gunzip(Contents)}, [verbose]),
        assert_safe_table(Table),
        InnerNames = [N || {N, _, _, _, _, _, _} <- Table],
        assert_files_match(MetaBin, InnerNames),
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
        % Only metadata.config is needed; skip materialising the (dominant)
        % contents.tar.gz member.
        {ok, Outer} = erl_tar:extract(unicode:characters_to_list(TarPath),
            [memory, {files, ["metadata.config"]}]),
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

% The inner checksum: uppercase-hex sha256 over VERSION ++ metadata ++
% contents.tar.gz, hashed as iodata so the tarball bytes are never copied.
checksum(Version, Meta, Contents) ->
    binary:encode_hex(crypto:hash(sha256, [Version, Meta, Contents]), uppercase).

% Throw unless every member of an inner tar table is one graded can safely carry
% forward. The rebuild in do_inject re-adds each member by
% filename:join(InnerDir, Name), and filename:join/2 lets an absolute second
% argument win outright — so an absolute name in a crafted archive would read
% the *host* file at that path and embed it in the tarball graded then tells the
% user to publish. Read the table and run this before anything is extracted: a
% name is judged before the archive it came from is written to disk.
assert_safe_table(Table) ->
    lists:foreach(fun assert_safe_member/1, Table).

assert_safe_member({Name, Type, _Size, _MTime, _Mode, _Uid, _Gid}) ->
    assert_safe_name(Name),
    % Only regular members are re-added, so any other kind is dropped from the
    % output rather than carried, and the run then fails on the files-list
    % mismatch naming nothing. Refuse it here, naming the entry and its actual
    % kind. A link's target is invisible to any check here — erl_tar:table/2
    % leaves it out of the tuple — which is why the kind is what is refused.
    Type =:= regular orelse throw({graded_error, iolist_to_binary([
        "graded pack does not support archives with non-regular members (`",
        Name, "` is a ", atom_to_list(Type), ")"])});
assert_safe_member(Member) ->
    throw({graded_error, unicode:characters_to_binary(io_lib:format(
        "unreadable inner tar entry: ~p", [Member]))}).

% Throw unless Name is a relative path with no `..` component.
%
% Path *type* is the test, not a leading slash: filename:pathtype/1 is
% platform-dependent in exactly the way the filename:join/2 it defends is, so
% the guard tracks the operation rather than one platform's spelling of it
% ("C:/x" is relative on Unix and absolute on Windows, and "C:x" is a third
% case — volumerelative — that a slash test misses entirely).
%
% The raw name is what gets checked, never a normalised one: normalising
% collapses an internal `a/../x` to `x` and would admit a name this rule
% rejects. `..` is its own clause because pathtype("..") is `relative`.
assert_safe_name(Name0) ->
    Name = unicode:characters_to_list(Name0),
    filename:pathtype(Name) =:= relative orelse unsafe_name(Name),
    lists:member("..", filename:split(Name)) andalso unsafe_name(Name),
    ok.

unsafe_name(Name) ->
    throw({graded_error, iolist_to_binary([
        "unsafe tar entry name `", Name,
        "`: entries must be relative paths inside the package"])}).

% Throw unless the metadata files list equals the inner tar names as sets.
assert_files_match(MetaBin, InnerNames) ->
    lists:sort(files_of(MetaBin)) =:= lists:sort(InnerNames) orelse
        throw({graded_error,
            <<"metadata files list does not match inner tar contents">>}).

format_reason(Reason) ->
    unicode:characters_to_binary(io_lib:format("~p", [Reason])).
