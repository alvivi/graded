-module(answer_census_ffi).
-export([sha256_hex/1]).

% The lowercase hexadecimal SHA-256 digest of Content.
sha256_hex(Content) ->
    Digest = crypto:hash(sha256, Content),
    list_to_binary([io_lib:format("~2.16.0b", [Byte]) || <<Byte>> <= Digest]).
