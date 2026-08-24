-module(graded_pack_ffi).
-export([inject_spec/4, verify_tarball/2, read_package_identity/1,
         files_of/1]).

% Inject a `.graded` spec into a hex tarball, following hex_tarball.erl's
% mechanics:
%   - gunzip contents.tar.gz, add the spec to the inner tar, re-gzip
%   - splice the archive-relative spec path into metadata.config's files list
%   - assert the metadata files list equals the inner tar contents
%   - recompute the inner checksum over VERSION ++ metadata ++ contents.tar.gz
%   - rebuild the outer tar (VERSION, metadata.config, contents.tar.gz, CHECKSUM)
% Re-running on an already-packed tarball replaces the spec entry rather than
% appending a duplicate, so the result stays canonical.
% Both scratch paths — the work directory and OutTar itself — are created here
% and owned here: each is an exclusive create that fails on a pre-existing path,
% and only what this invocation created is ever removed.
% Returns {ok, Checksum} (uppercase hex) or {error, Reason} (a binary message).
inject_spec(InTar, SpecBin, EntryName, OutTar) ->
    OutTarPath = unicode:characters_to_list(OutTar),
    WorkDir = OutTarPath ++ ".work",
    case file:make_dir(WorkDir) of
        ok ->
            try
                inject_into(unicode:characters_to_list(InTar), SpecBin,
                    unicode:characters_to_list(EntryName), OutTarPath, WorkDir)
            after
                file:del_dir_r(WorkDir)
            end;
        {error, eexist} ->
            {error, iolist_to_binary(["scratch directory already exists: ",
                WorkDir, "; remove it and retry"])};
        {error, Reason} ->
            {error, format_reason(Reason)}
    end.

% Create the output tarball with an O_EXCL open and write it through the
% descriptor that open returns.
%
% Creating exclusively and then closing would only prove the path was free at
% that instant: erl_tar:open/2 takes a filename, so it re-opens by name and
% follows a symlink planted in between. That is not hygiene — verify_tarball
% re-opens the result by name and the flow renames it over the original, and on
% Windows renaming a file with an open handle fails. erl_tar:init/3 takes user
% data and an I/O fun instead, so the archive goes through the retained
% descriptor and the path is never resolved a second time.
inject_into(InTarPath, SpecBin, Entry, OutTarPath, WorkDir) ->
    case file:open(OutTarPath, [write, exclusive, binary]) of
        {ok, Fd} ->
            try
                do_inject(InTarPath, SpecBin, Entry, Fd, WorkDir)
            catch
                throw:{graded_error, Msg} -> failed_inject(OutTarPath, Fd, Msg);
                _:Reason ->
                    failed_inject(OutTarPath, Fd, format_reason(Reason))
            after
                file:close(Fd)
            end;
        {error, eexist} ->
            {error, iolist_to_binary(["output path already exists: ",
                OutTarPath, "; remove it and retry"])};
        {error, Reason} ->
            {error, format_reason(Reason)}
    end.

% A half-written output tarball is this invocation's own, so it goes; a path
% that was already there never reaches here, because the exclusive create
% refused it. Closing before deleting keeps the order Windows needs.
failed_inject(OutTarPath, Fd, Msg) ->
    _ = file:close(Fd),
    _ = file:delete(OutTarPath),
    {error, Msg}.

% erl_tar's I/O interface over a descriptor the caller owns. `close` is a no-op
% so erl_tar:close/1 flushes the archive and leaves the descriptor open for
% inject_into's `after` to close — erl_tar:close/1 is not reached on a throw, so
% closing here would leak the descriptor on exactly the paths that matter.
tar_io(write, {Fd, Bytes}) -> file:write(Fd, Bytes);
tar_io(position, {Fd, Pos}) -> file:position(Fd, Pos);
tar_io(close, _) -> ok.

do_inject(InTarPath, SpecBin, Entry, OutFd, WorkDir) ->
    InnerTmp = filename:join(WorkDir, "inner.tar"),
    InnerDir = filename:join(WorkDir, "contents"),
    assert_safe_name(Entry),
    Outer = extract_outer(InTarPath, []),
    Version = required_member("VERSION", Outer),
    MetaBin = required_member("metadata.config", Outer),
    Contents = required_member("contents.tar.gz", Outer),
    Stored = required_member("CHECKSUM", Outer),

    % inner tar: unpack to disk (restoring each entry's mode), re-add every
    % entry by path — erl_tar only takes modes from the filesystem, a binary
    % add silently writes 0644 — and replace any existing spec entry.
    InnerRaw = gunzip_contents(Contents),
    Table = safe_inner_table(InnerRaw),

    % The input's own integrity, checked once the more specific failures above
    % have had their say. Nothing carries this checksum forward — the rebuild
    % mints a fresh one over the new bytes — so this is the only point where a
    % corrupt or tampered input is still distinguishable from a sound one.
    % Minting a valid checksum over damaged contents would launder the damage
    % into an archive that verifies, and the run ends by telling the user to
    % publish it.
    Stored =:= checksum(Version, MetaBin, Contents) orelse
        fail(["the tarball's stored CHECKSUM does not match its contents; ",
            "rebuild it with `gleam export hex-tarball`"]),

    ok = file:make_dir(InnerDir),
    extract_inner(InnerRaw, InnerDir),
    Names = [N || N <- names(Table), N =/= Entry],
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
            Spliced =:= MetaBin andalso
                fail(["metadata.config files-list marker not found"]),
            Spliced
    end,

    assert_files_match(NewMeta, [Entry | Names]),

    % inner checksum over the final bytes.
    Checksum = checksum(Version, NewMeta, NewContents),

    % rebuild outer tar, through the descriptor inject_into holds open.
    {ok, O} = erl_tar:init(OutFd, write, fun tar_io/2),
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
        Outer = extract_outer(unicode:characters_to_list(TarPath), []),
        Version = required_member("VERSION", Outer),
        MetaBin = required_member("metadata.config", Outer),
        Contents = required_member("contents.tar.gz", Outer),
        Stored = required_member("CHECKSUM", Outer),
        Entry = unicode:characters_to_list(EntryName),

        Stored =:= checksum(Version, MetaBin, Contents) orelse
            fail(["stored CHECKSUM does not match recomputed inner checksum"]),

        % The table, not a memory extract: an extract yields regular members
        % only, so it would certify a strict subset of what the archive carries.
        InnerNames = names(safe_inner_table(gunzip_contents(Contents))),
        assert_files_match(MetaBin, InnerNames),
        lists:member(Entry, InnerNames) orelse
            fail(["injected spec not present in the tarball"]),
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
        Outer = extract_outer(unicode:characters_to_list(TarPath),
            [{files, ["metadata.config"]}]),
        MetaBin = required_member("metadata.config", Outer),
        Terms = config_terms(MetaBin),
        Name = to_binary(proplists:get_value(<<"name">>, Terms)),
        Version = to_binary(proplists:get_value(<<"version">>, Terms)),
        case {Name, Version} of
            {undefined, _} -> {error, <<"tarball metadata has no name">>};
            {_, undefined} -> {error, <<"tarball metadata has no version">>};
            _ -> {ok, {Name, Version}}
        end
    catch
        throw:{graded_error, Msg} -> {error, Msg};
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
    case erl_scan:string(unicode:characters_to_list(Bin)) of
        {ok, Tokens, _} -> parse_terms(Tokens, []);
        {error, Info, _} -> fail(["metadata.config does not scan as Erlang ",
            "terms: ", format_reason(Info)])
    end.

parse_terms([], Acc) -> lists:reverse(Acc);
parse_terms(Tokens, Acc) ->
    case lists:splitwith(fun({dot, _}) -> false; (_) -> true end, Tokens) of
        {_, []} -> fail(["metadata.config has a term with no terminating `.`"]);
        {Before, [Dot | Rest]} ->
            case erl_parse:parse_term(Before ++ [Dot]) of
                {ok, Term} -> parse_terms(Rest, [Term | Acc]);
                {error, Info} -> fail(["metadata.config has a term that ",
                    "does not parse: ", format_reason(Info)])
            end
    end.

to_binary(undefined) -> undefined;
to_binary(V) when is_binary(V) -> V;
to_binary(V) when is_list(V) -> unicode:characters_to_binary(V).

% The inner checksum: uppercase-hex sha256 over VERSION ++ metadata ++
% contents.tar.gz, hashed as iodata so the tarball bytes are never copied.
checksum(Version, Meta, Contents) ->
    binary:encode_hex(crypto:hash(sha256, [Version, Meta, Contents]), uppercase).

% Read an outer tar's members into memory, naming the file rather than
% badmatching on a corrupt or non-tar input — the first thing a malformed file
% hits, and until now the one that produced the least about it.
extract_outer(TarPath, Opts) ->
    case erl_tar:extract(TarPath, [memory | Opts]) of
        {ok, Members} -> Members;
        {error, Reason} -> fail(["could not read ", TarPath,
            " as a hex tarball: ", format_reason(Reason)])
    end.

% A member a hex tarball must carry. proplists:get_value/2 answers `undefined`
% for a missing one, which travels as far as the term that consumes it before
% failing as something else entirely.
required_member(Name, Outer) ->
    case proplists:get_value(Name, Outer) of
        undefined -> fail(["hex tarball has no ", Name, " member"]);
        Value -> Value
    end.

% zlib:gunzip/1 raises data_error on a truncated or corrupt stream.
gunzip_contents(Contents) ->
    try zlib:gunzip(Contents)
    catch _:_ -> fail(["contents.tar.gz is not a readable gzip stream"])
    end.

% The inner tar's table, with every member already judged safe to carry
% forward — the two are one call so that no reader of the table can hold an
% unvalidated one. Gunzipping cleanly says nothing about what the bytes then
% are, so the read has its own diagnostic.
safe_inner_table(InnerRaw) ->
    case erl_tar:table({binary, InnerRaw}, [verbose]) of
        {ok, Table} -> lists:foreach(fun assert_safe_member/1, Table), Table;
        {error, Reason} -> fail(["could not read contents.tar.gz as a tar ",
            "archive: ", format_reason(Reason)])
    end.

names(Table) -> [Name || {Name, _, _, _, _, _, _} <- Table].

% Throw unless a member is one graded can safely carry forward. The rebuild in
% do_inject re-adds each by filename:join(InnerDir, Name), and filename:join/2
% lets an absolute second argument win outright — so an absolute name in a
% crafted archive would read the *host* file at that path and embed it in the
% tarball graded then tells the user to publish. This runs before anything is
% extracted: a name is judged before the archive it came from reaches disk.
assert_safe_member({Name, Type, _Size, _MTime, _Mode, _Uid, _Gid}) ->
    assert_safe_name(Name),
    % Only regular members can be re-added, so any other kind would be dropped
    % from the output rather than carried, and the run would fail on the
    % files-list mismatch naming nothing. Refuse it here, naming the entry and
    % its actual kind. A link's target is invisible to any check here —
    % erl_tar:table/2 leaves it out of the tuple — which is why the kind is
    % what gets refused.
    Type =:= regular orelse fail([
        "graded pack does not support archives with non-regular members (`",
        Name, "` is a ", atom_to_list(Type), ")"]).

% Whatever erl_tar rejects that graded's own rules did not anticipate. The
% unsafe-name and unsafe-symlink refusals it would otherwise raise here are
% unreachable — safe_inner_table has already refused both, before extraction.
extract_inner(InnerRaw, InnerDir) ->
    case erl_tar:extract({binary, InnerRaw}, [{cwd, InnerDir}]) of
        ok -> ok;
        {error, Reason} -> fail(["could not unpack contents.tar.gz: ",
            format_reason(Reason)])
    end.

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
    fail(["unsafe tar entry name `", Name,
        "`: entries must be relative paths inside the package"]).

% Throw unless the metadata files list equals the inner tar names as sets.
assert_files_match(MetaBin, InnerNames) ->
    lists:sort(files_of(MetaBin)) =:= lists:sort(InnerNames) orelse
        fail(["metadata files list does not match inner tar contents"]).

% Every diagnostic this module raises, as one message the callers' catch
% clauses turn back into {error, Binary}.
fail(Parts) -> throw({graded_error, iolist_to_binary(Parts)}).

format_reason(Reason) ->
    unicode:characters_to_binary(io_lib:format("~p", [Reason])).
