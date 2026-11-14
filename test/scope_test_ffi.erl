-module(scope_test_ffi).
-export([reductions/0]).

% The reductions the calling process has run, for bounding an inference's work.
reductions() ->
    {reductions, Count} = erlang:process_info(self(), reductions),
    Count.
