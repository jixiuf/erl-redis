%%%----------------------------------------------------------------------
%%%
%%% @copyright erl-redis 2010
%%%
%%% @author litaocheng@gmail.com
%%% @doc the interface for redis
%%% @end
%%%
%%%----------------------------------------------------------------------
-module(redis).
-author('ltiaocheng@gmail.com').
-vsn('0.1').
-include("redis.hrl").

-export([i/0]).
-compile([export_all]).
-compile(inline).
-compile({inline_size, 30}).

%% connection pool size
-define(DEF_POOL, 2).

%% @doc show stats info in the stdout
-spec i() -> 'ok'.
i() ->
    ok.

%% @doc return the redis version info
%% first element is the redis client version,
%% second element is the lowest redis server version supported
-spec vsn() -> {string(), string()}.
vsn() ->
    {get_app_vsn(), "1.2.5"}.

%% @doc return the server info
-spec servers() -> [single_server()].
servers() ->
    redis_manager:server_info().

%% @doc return the server config type
-spec server_type() -> server_type().
server_type() ->
    redis_manager:server_type().

%% @doc set single redis server
-spec single_server(Host :: inet_host(), Port :: inet_port()) ->
    'ok' | {'error', 'already_started'}.
single_server(Host, Port) ->
    single_server(Host, Port, ?DEF_POOL).

%% @doc set single redis server, with the connection pool option
-spec single_server(Host :: inet_host(), Port :: inet_port(), Pool :: pos_integer()) ->
    'ok' | {'error', 'already_started'}.
single_server(Host, Port, Pool) ->
    single_server(Host, Port, Pool, "").

%% @doc set single redis server, with the connection pool and passwd options
-spec single_server(Host :: inet_host(), Port :: inet_port(), 
        Pool :: pos_integer(), Passwd :: passwd()) ->
    'ok' | {'error', 'already_started'}.
single_server(Host, Port, Pool, Passwd) ->
    redis_app:start_manager({single, {Host, Port, Pool}}, Passwd).

%% @doc set the multi servers 
-spec multi_servers(Servers :: [single_server()]) ->
    'ok' | {'error', 'already_started'}.
multi_servers(Servers) ->
    multi_servers(Servers, "").

%% @doc set the multiple servers, with passwd option
-spec multi_servers(Servers :: [single_server()], Passwd :: passwd()) ->
    'ok' | {'error', 'already_started'}.
multi_servers(Servers, Passwd) ->
    redis_app:start_manager({dist, redis_dist:new(Servers)}, Passwd).

%%------------------------------------------------------------------------------
%% generic commands
%%------------------------------------------------------------------------------

%% @doc test if the specified key exists
%% O(1)
-spec exists(Key :: key()) -> 
    boolean().
exists(Key) ->
    R = call_key(Key, line(<<"EXISTS">>, Key)),
    int_bool(R).

%% @doc remove the specified key, return ture if deleted, 
%% otherwise return false
%% O(1)
-spec delete(Keys :: [key()]) -> 
    boolean().
delete(Key) ->
    R = call_key(Key, line(<<"DEL">>, Key)),
    int_bool(R).

%% @doc remove the specified keys, return the number of
%% keys removed.
%% O(1)
-spec multi_delete(Keys :: [key()]) -> 
    non_neg_integer().
multi_delete(Keys) ->
    Type = <<"DEL">>,
    ClientKeys = redis_manager:partition_keys(Keys),
    ?DEBUG2("client keys is ~p", [ClientKeys]),
    L =
    [begin
        Cmd = line_list([Type | KLPart]),
        call(Client, Cmd)
    end || {Client, KLPart} <- ClientKeys],
    lists:sum(L).

%% @doc return the type of the value stored at key
%% O(1)
-spec type(Key :: key()) -> 
    value_type().
type(Key) ->
    call_key(Key, line(<<"TYPE">>, Key)).

%% @doc return the keys list matching a given pattern,
%% return the {[key()], [server()]}, the second element in tuple is
%% the bad servers.
%% O(n)
-spec keys(Pattern :: pattern()) -> 
    {[key()], [server()]}.
keys(Pattern) ->
    {Replies, BadServers} = call_clients_one(line(<<"KEYS">>, Pattern)),
    Keys = lists:append([redis_proto:tokens(R, ?SEP) || {_Server, R} <- Replies]),
    {Keys, BadServers}.

%% @doc return a randomly selected key from the currently selected DB
%% O(1)
-spec random_key() -> 
    key() | null().
random_key() ->
    F = 
    fun
        (null) ->
            false;
        (_) ->
            true
    end,
    catch call_any(line(<<"RANDOMKEY">>), F).

%% @doc atmoically renames key OldKey to NewKey
%% NOTE: MUST single mode
%% O(1)
-spec rename(OldKey :: key(), NewKey :: key()) -> 
    'ok' | error_reply().
rename(OldKey, NewKey) ->
    {ok, Client} = redis_manager:get_client_smode(OldKey),
    call(Client, line(<<"RENAME">>, OldKey, NewKey)).

%% @doc  rename oldkey into newkey  but fails if the destination key newkey already exists. 
%% NOTE: MUST single mode
%% O(1)
-spec rename_not_exists(OldKey :: key(), NewKey :: key()) -> 
    boolean() | error_reply().
rename_not_exists(OldKey, NewKey) ->
    {ok, Client} = redis_manager:get_client_smode(OldKey),
    R = call(Client, line(<<"RENAMENX">>, OldKey, NewKey)),
    int_may_bool(R).

%% @doc return the nubmer of keys in all the currently selected database
%% O(1)
-spec dbsize() -> 
    {integer() , [server()]}.
dbsize() ->
    {Replies, BadServers} = call_clients_one(line(<<"DBSIZE">>)),
    Size = 
    lists:foldl(
        fun({_Server, R}, Acc) ->
            R + Acc
        end,
    0, Replies),
    {Size, BadServers}.

%% @doc set a timeout on the specified key, after the Time the Key will
%% automatically deleted by server.
%% O(1)
-spec expire(Key :: key(), Time :: second()) -> 
    boolean().
expire(Key, Time) ->
    R = call_key(Key, line(<<"EXPIRE">>, Key, ?N2S(Time))),
    int_bool(R).

%% @doc set a unix timestamp on the specified key, the Key will
%% automatically deleted by server at the TimeStamp in the future.
%% O(1)
-spec expire_at(Key :: key(), TimeStamp :: timestamp()) -> 
    boolean().
expire_at(Key, TimeStamp) ->
    R = call_key(Key, line(<<"EXPIREAT">>, Key, ?N2S(TimeStamp))),
    int_bool(R).

%% @doc return the remaining time to live in seconds of a key that
%% has an EXPIRE set
%% O(1)
-spec ttl(Key :: key()) -> non_neg_integer().
ttl(Key) ->
    call_key(Key, line(<<"TTL">>, Key)).

%% @doc select the DB with have the specified zero-based numeric index
%% ??
-spec select(Index :: index()) ->
    'ok' | {'error', [server()]}.
select(Index) ->
    redis_manager:select_db(Index).

%% @doc move the specified key  from the currently selected DB to the specified
%% destination DB
%% NOTE: MUST single mode
-spec move(Key :: key(), DBIndex :: index()) ->
    boolean() | error_reply().
move(Key, DBIndex) ->
    {ok, Client} = redis_manager:get_client_smode(Key),
    R = call(Client, line(<<"MOVE">>, Key, ?N2S(DBIndex))),
    int_may_bool(R).

%% @doc delete all the keys of the currently selected DB
-spec flush_db() -> 'ok' | {'error', [server_regname()]}.
flush_db() ->
    {_Replies, BadServers} = call_clients_one(line(<<"FLUSHDB">>)),
    case BadServers of
        [] ->
            ok;
        [_|_] ->
            {error, BadServers}
    end.
            
-spec flush_all() -> 'ok' | {'error', [server_regname()]}.
flush_all() ->
    {_Replies, BadServers} = call_clients_one(line(<<"FLUSHALL">>)),
    case BadServers of
        [] ->
            ok;
        [_|_] ->
            {error, BadServers}
    end.

%%------------------------------------------------------------------------------
%% string commands 
%%------------------------------------------------------------------------------

%% @doc set the string as value of the key
%% O(1)
-spec set(Key :: key(), Val :: string_value()) ->
    'ok'.
set(Key, Val) ->
    call_key(Key, bulk(<<"SET">>, Key, Val)).
    
%% @doc get the value of specified key
%% O(1)
-spec get(Key :: key()) ->
    null() | binary().
get(Key) ->
    call_key(Key, line(<<"GET">>, Key)).

%% @doc atomatic set the value and return the old value
%% O(1)
-spec getset(Key :: key(), Val :: string_value()) ->
    null() | binary() | error_reply(). 
getset(Key, Val) ->
    call_key(Key, bulk(<<"GETSET">>, Key, Val)).

%% @doc get the values of all the specified keys
%% O(1)
-spec multi_get(Keys :: [key()]) ->
    [string() | null()].
multi_get(Keys) ->
    Type = <<"MGET">>,
    Len = length(Keys),
    KeyIs = lists:zip(lists:seq(1, Len), Keys),
    KFun = fun({_Index, K}) -> K end,
    ClientKeys = redis_manager:partition_keys(KeyIs, KFun),
    ?DEBUG2("get client keys partions is ~p", [ClientKeys]),

    L =
    [begin
        KsPart = [KFun(KI) || KI <- KIsPart],
        Cmd = line_list([Type | KsPart]),

        Replies = redis_client:send(Client, Cmd),
        lists:zip(KIsPart, Replies)
    end || {Client, KIsPart} <- ClientKeys],
    AllReplies = lists:append(L),
    % return the result in the same order with Keys
    SortedReplies = lists:sort(AllReplies),
    {KeyIs, Replies} = lists:unzip(SortedReplies),
    Replies.

%% @doc set value, if the key already exists no operation is performed
%% O(1)
-spec set_not_exists(Key :: key(), Val :: string()) -> 
    boolean().
set_not_exists(Key, Val) ->
    R = call_key(Key, bulk(<<"SETNX">>, Key, Val)),
    int_bool(R).

%% @doc set the respective keys to respective values
%% NOTE: MUST single mode
%% O(1)
-spec multi_set(KeyVals :: [{key(), string_value()}]) ->
    'ok'.
multi_set(KeyVals) ->
    {ok, Client} = redis_manager:get_client_smode(),
    L = [<<"MSET">> | lists:append([[K, V] || {K, V} <- KeyVals])],
    call(Client, mbulk(L)).

%% @doc set the respective keys to respective values, either all the
%% key-value paires or not none at all are set.
%% NOTE: MUST single mode
%% O(1)
-spec multi_set_not_exists(KeyVals :: [{key(), string_value()}]) ->
    boolean().
multi_set_not_exists(KeyVals) ->
    {ok, Client} = redis_manager:get_client_smode(),
    L = [<<"MSETNX">> | lists:append([[K, V] || {K, V} <- KeyVals])],
    R = call(Client, mbulk(L)),
    int_bool(R).

%% @doc increase the integer value of key
%% O(1)
-spec incr(Key :: key()) -> 
    integer().
incr(Key) ->
    call_key(Key, line(<<"INCR">>, Key)).

%% @doc increase the integer value of key by integer
%% O(1)
-spec incr(Key :: key(), N :: integer()) -> 
    integer().
incr(Key, N) ->
    call_key(Key, line(<<"INCRBY">>, Key, ?N2S(N))).

%% @doc decrease the integer value of key
%% O(1)
-spec decr(Key :: key()) -> 
    integer().
decr(Key) ->
    call_key(Key, line(<<"DECR">>, Key)).

%% @doc decrease the integer value of key by integer
%% O(1)
-spec decr(Key :: key(), N :: integer()) -> 
    integer().
decr(Key, N) ->
    call_key(Key, line(<<"DECRBY">>, Key, ?N2S(N))).

%%------------------------------------------------------------------------------
%% list commands
%%------------------------------------------------------------------------------

%% @doc add the string Val to the tail of the list stored at Key
%% O(1)
-spec list_push_tail(Key :: key(), Val :: str()) ->
    'ok' | error().
list_push_tail(Key, Val) ->
    call_key(Key, bulk(<<"RPUSH">>, Key, Val)).

%% @doc add the string Val to the head of the list stored at Key
%% O(1)
-spec list_push_head(Key :: key(), Val :: str()) ->
    'ok' | error().
list_push_head(Key, Val) ->
    call_key(Key, bulk(<<"LPUSH">>, Key, Val)).

%% @doc return the length of the list
%% O(1)
-spec list_len(Key :: key()) ->
    length() | error().
list_len(Key) ->
    call_key(Key, line(<<"LLEN">>, Key)).

%% @doc return the specified elements of the list, Start, End are zero-based
%% O(n)
-spec list_range(Key :: key(), Start :: index(), End :: index()) ->
    [value()].
list_range(Key, Start, End) ->
    call_key(Key, line(<<"LRANGE">>, Key, ?N2S(Start), ?N2S(End))).

%% @doc trim an existing list, it will contains the elements specified by 
%% Start End
%% O(n)
-spec list_trim(Key :: key(), Start :: index(), End :: index()) ->
    'ok' | error().
list_trim(Key, Start, End) ->
    call_key(Key, line(<<"LTRIM">>, Key, ?N2S(Start), ?N2S(End))).

%% @doc return the element at Idx in the list(zero-based)
%% O(n)
-spec list_index(Key :: key(), Idx :: index()) ->
    value().
list_index(Key, Idx) ->
    call_key(Key, line(<<"LINDEX">>, Key, ?N2S(Idx))).

%% @doc set the list element at Idx with the new value Val
%% O(n)
-spec list_set(Key :: key(), Idx :: index(), Val :: str()) ->
    'ok' | error().
list_set(Key, Idx, Val) ->
    call_key(Key, bulk(<<"LSET">>, Key, ?N2S(Idx), Val)).

%% @doc remove all the elements in the list whose value are Val
%% O(n)
-spec list_rm(Key :: key(), Val :: str()) ->
    integer().
list_rm(Key, Val) ->
    call_key(Key, bulk(<<"LREM">>, Key, "0", Val)).

%% @doc remove the first N occurrences of the value from head to
%% tail in the list
%% O(n)
-spec list_rm_head(Key :: key(), N :: pos_integer(), Val :: str()) ->
    integer().
list_rm_head(Key, N, Val) ->
    call_key(Key, bulk(<<"LREM">>, Key, ?N2S(N), Val)).

%% @doc remove the first N occurrences of the value from tail 
%% head in the list
%% O(n)
-spec list_rm_tail(Key :: key(), N :: pos_integer(), Val :: str()) ->
    integer().
list_rm_tail(Key, N, Val) ->
    call_key(Key, bulk(<<"LREM">>, Key, ?N2S(-N), Val)).

%% @doc atomically return and remove the first element of the list
%% O(1)
-spec list_pop_head(Key :: key()) ->
    value().
list_pop_head(Key) ->
    call_key(Key, line(<<"LPOP">>, Key)).

%% @doc atomically return and remove the last element of the list
%% O(1)
-spec list_pop_tail(Key :: key()) ->
    value().
list_pop_tail(Key) ->
    call_key(Key, line(<<"RPOP">>, Key)).

%% @doc atomically remove the last element of the SrcKey list and push
%% the element into the DstKey list
%% NOTE: MUST single mode
%% O(1)
list_tail_to_head(SrcKey, DstKey) ->
    {ok, Client} = redis_manager:get_client_smode(SrcKey),
    call(Client, line(<<"RPOPLPUSH">>, SrcKey, DstKey)).

%%------------------------------------------------------------------------------
%%
%% internal API
%%
%%------------------------------------------------------------------------------

%% generate the line 
line(Type) ->
    [Type, ?CRLF].
line(Type, Arg) ->
    [Type, ?SEP, Arg, ?CRLF].
line(Type, Arg1, Arg2) ->
    [Type, ?SEP, Arg1, ?SEP, Arg2, ?CRLF].
line(Type, Arg1, Arg2, Arg3) ->
    [Type, ?SEP, Arg1, ?SEP, Arg2, ?SEP, Arg3, ?CRLF].
line_list(Parts) ->
    [?SEP | Line] = 
    lists:foldr(
        fun(P, Acc) ->
            [?SEP, P | Acc]
        end,
    [?CRLF], Parts),
    Line.

%% generate the bulk command
bulk(Type, Arg1, Arg2) ->
    L1 = line(Type, Arg1, ?N2S(iolist_size(Arg2))),
    L2 = line(Arg2),
    [L1, L2].
bulk(Type, Arg1, Arg2, Arg3) ->
    L1 = line(Type, Arg1, Arg2, ?N2S(iolist_size(Arg3))),
    L2 = line(Arg3),
    [L1, L2].

%% generate the mbulk command
mbulk(L) ->
    N = length(L),
    Lines = [mbulk1(E) || E <- L],
    ["*", ?N2S(N), ?CRLF | Lines].
mbulk1(B) when is_binary(B) ->
    N = byte_size(B),
    ["$", ?N2S(N), ?CRLF, B, ?CRLF];
mbulk1(L) when is_list(L) ->
    N = length(L),
    ["$", ?N2S(N), ?CRLF, L, ?CRLF].

%% send the command 
call(Client, Cmd) ->
    redis_client:send(Client, Cmd).

%% do the call to the server the key belong to
call_key(Key, Cmd) ->
    {ok, Client} = redis_manager:get_client(Key),
    redis_client:send(Client, Cmd).

%% do the call to one connection with all servers 
call_clients_one(Cmd) ->
    {ok, Clients} = redis_manager:get_clients_one(),
    ?DEBUG2("call clients one : ~p~ncmd :~p", [Clients, Cmd]),
    redis_client:multi_send(Clients, Cmd).

%% do the call to all the connections with all servers
call_clients_all(Cmd) ->
    {ok, Clients} = redis_manager:get_clients_all(),
    ?DEBUG2("call clients all :~p~ncmd :~p", [Clients, Cmd]),
    redis_client:multi_send(Clients, Cmd).

%% do the call to any one server
call_any(Cmd, F) ->
    {ok, Clients} = redis_manager:get_clients_one(),
    ?DEBUG2("call any send cmd ~p by clients:~p", [Cmd, Clients]),
    [V | _] =
    [begin
        Ret = redis_client:send(Client, Cmd),
        case F(Ret) of
            true ->
                throw(Ret);
            false ->
                Ret
        end
    end || Client <- Clients],
    V.


%% convert status code to return
status_return(<<"OK">>) -> ok;
status_return(S) -> S.

%% convert integer to return
int_return(0) -> false;
int_return(1) -> true.

int_bool(0) -> false;
int_bool(1) -> true.

int_may_bool(0) -> false;
int_may_bool(1) -> true;
int_may_bool(V) -> V.

%% get the application vsn
%% return 'undefined' | string().
get_app_vsn() ->
    {ok, App} = application:get_application(),
    {ok, Vsn} = application:get_key(App, vsn),
    Vsn.

%%
%% unit test
%%
-ifdef(TEST).

l2b(Line) ->
    iolist_to_binary(Line).

cmd_line_test_() ->
    [
        ?_assertEqual(<<"EXISTS key1\r\n">>, l2b(line(<<"EXISTS">>, "key1"))),
        ?_assertEqual(<<"EXISTS key2\r\n">>, l2b(line("EXISTS", "key2"))),
        ?_assertEqual(<<"type key1 key2\r\n">>, l2b(line("type", "key1", <<"key2">>))),
        ?_assertEqual(<<"type key1 key2\r\n">>, l2b(line_list(["type", <<"key1">>, "key2"]))),

        ?_assert(true)
    ].
-endif.
