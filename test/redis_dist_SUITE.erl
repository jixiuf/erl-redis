-module(redis_dist_SUITE).

%% Note: This directive should only be used in test suites.
-compile(export_all).

-include("ct.hrl").

suite() -> [
    {timetrap,{minutes,2}}
    ].

init_per_suite(Config) ->
    crypto:start(),
    code:add_path("../ebin"),
    redis_app:start(),
    Servers = [{localhost, 6379, 2}, {localhost, 6380, 3}],
    ok = redis_app:dist_server(Servers, "litao"),
    Redis = redis_app:client(dist),
    %ok = Redis:flush_all(),
    io:format("Redis is ~p~n", [Redis]),
    [{redis_client, Redis}, {redis_type, dist} | Config].

end_per_suite(_Config) ->
    redis_app:stop(),
    crypto:stop(),
    ok.

init_per_testcase(Name, Config) ->
    io:format("..init ~p~n~p~n", [Name, Config]),
    Config.

end_per_testcase(Name, Config) ->
    io:format("...end ~p~n~p~n", [Name, Config]),
    ok.

all() -> 
    [
        do_test
    ].

%%-------------------------------------------------------------------------
%% Test cases starts here.
%%-------------------------------------------------------------------------

do_test(Config) ->
    redis_tests:do(Config).