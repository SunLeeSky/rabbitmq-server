%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is VMware, Inc.
%% Copyright (c) 2007-2011 VMware, Inc.  All rights reserved.
%%

-module(rabbit_amqqueue).

-export([start/0, stop/0, declare/5, delete_immediately/1, delete/3, purge/1]).
-export([pseudo_queue/2]).
-export([lookup/1, with/2, with_or_die/2, assert_equivalence/5,
         check_exclusive_access/2, with_exclusive_access_or_die/3,
         stat/1, deliver/2, requeue/3, ack/3, reject/4]).
-export([list/1, info_keys/0, info/1, info/2, info_all/1, info_all/2]).
-export([consumers/1, consumers_all/1, consumer_info_keys/0]).
-export([basic_get/3, basic_consume/7, basic_cancel/4]).
-export([notify_sent/2, unblock/2, flush_all/2]).
-export([notify_down_all/2, limit_all/3]).
-export([on_node_down/1]).
-export([store_queue/1]).


%% internal
-export([internal_declare/2, internal_delete/1, run_backing_queue/3,
         sync_timeout/1, update_ram_duration/1, set_ram_duration_target/2,
         set_maximum_since_use/2, maybe_expire/1, drop_expired/1,
         emit_stats/1]).

-include("rabbit.hrl").
-include_lib("stdlib/include/qlc.hrl").

-define(INTEGER_ARG_TYPES, [byte, short, signedint, long]).

%%----------------------------------------------------------------------------

-ifdef(use_specs).

-export_type([name/0, qmsg/0]).

-type(name() :: rabbit_types:r('queue')).

-type(qlen() :: rabbit_types:ok(non_neg_integer())).
-type(qfun(A) :: fun ((rabbit_types:amqqueue()) -> A)).
-type(qmsg() :: {name(), pid(), msg_id(), boolean(), rabbit_types:message()}).
-type(msg_id() :: non_neg_integer()).
-type(ok_or_errors() ::
        'ok' | {'error', [{'error' | 'exit' | 'throw', any()}]}).

-type(queue_or_not_found() :: rabbit_types:amqqueue() | 'not_found').

-spec(start/0 :: () -> [name()]).
-spec(stop/0 :: () -> 'ok').
-spec(declare/5 ::
        (name(), boolean(), boolean(),
         rabbit_framing:amqp_table(), rabbit_types:maybe(pid()))
        -> {'new' | 'existing', rabbit_types:amqqueue()} |
           rabbit_types:channel_exit()).
-spec(lookup/1 ::
        (name()) -> rabbit_types:ok(rabbit_types:amqqueue()) |
                    rabbit_types:error('not_found')).
-spec(with/2 :: (name(), qfun(A)) -> A | rabbit_types:error('not_found')).
-spec(with_or_die/2 ::
        (name(), qfun(A)) -> A | rabbit_types:channel_exit()).
-spec(assert_equivalence/5 ::
        (rabbit_types:amqqueue(), boolean(), boolean(),
         rabbit_framing:amqp_table(), rabbit_types:maybe(pid()))
        -> 'ok' | rabbit_types:channel_exit() |
           rabbit_types:connection_exit()).
-spec(check_exclusive_access/2 ::
        (rabbit_types:amqqueue(), pid())
        -> 'ok' | rabbit_types:channel_exit()).
-spec(with_exclusive_access_or_die/3 ::
        (name(), pid(), qfun(A)) -> A | rabbit_types:channel_exit()).
-spec(list/1 :: (rabbit_types:vhost()) -> [rabbit_types:amqqueue()]).
-spec(info_keys/0 :: () -> rabbit_types:info_keys()).
-spec(info/1 :: (rabbit_types:amqqueue()) -> rabbit_types:infos()).
-spec(info/2 ::
        (rabbit_types:amqqueue(), rabbit_types:info_keys())
        -> rabbit_types:infos()).
-spec(info_all/1 :: (rabbit_types:vhost()) -> [rabbit_types:infos()]).
-spec(info_all/2 :: (rabbit_types:vhost(), rabbit_types:info_keys())
                    -> [rabbit_types:infos()]).
-spec(consumers/1 ::
        (rabbit_types:amqqueue())
        -> [{pid(), rabbit_types:ctag(), boolean()}]).
-spec(consumer_info_keys/0 :: () -> rabbit_types:info_keys()).
-spec(consumers_all/1 ::
        (rabbit_types:vhost())
        -> [{name(), pid(), rabbit_types:ctag(), boolean()}]).
-spec(stat/1 ::
        (rabbit_types:amqqueue())
        -> {'ok', non_neg_integer(), non_neg_integer()}).
-spec(emit_stats/1 :: (rabbit_types:amqqueue()) -> 'ok').
-spec(delete_immediately/1 :: (rabbit_types:amqqueue()) -> 'ok').
-spec(delete/3 ::
        (rabbit_types:amqqueue(), 'false', 'false')
        -> qlen();
        (rabbit_types:amqqueue(), 'true' , 'false')
        -> qlen() | rabbit_types:error('in_use');
        (rabbit_types:amqqueue(), 'false', 'true' )
        -> qlen() | rabbit_types:error('not_empty');
        (rabbit_types:amqqueue(), 'true' , 'true' )
        -> qlen() |
           rabbit_types:error('in_use') |
           rabbit_types:error('not_empty')).
-spec(purge/1 :: (rabbit_types:amqqueue()) -> qlen()).
-spec(deliver/2 :: (pid(), rabbit_types:delivery()) -> boolean()).
-spec(requeue/3 :: (pid(), [msg_id()],  pid()) -> 'ok').
-spec(ack/3 :: (pid(), [msg_id()], pid()) -> 'ok').
-spec(reject/4 :: (pid(), [msg_id()], boolean(), pid()) -> 'ok').
-spec(notify_down_all/2 :: ([pid()], pid()) -> ok_or_errors()).
-spec(limit_all/3 :: ([pid()], pid(), rabbit_limiter:token()) ->
                          ok_or_errors()).
-spec(basic_get/3 :: (rabbit_types:amqqueue(), pid(), boolean()) ->
                          {'ok', non_neg_integer(), qmsg()} | 'empty').
-spec(basic_consume/7 ::
        (rabbit_types:amqqueue(), boolean(), pid(),
         rabbit_limiter:token(), rabbit_types:ctag(), boolean(), any())
        -> rabbit_types:ok_or_error('exclusive_consume_unavailable')).
-spec(basic_cancel/4 ::
        (rabbit_types:amqqueue(), pid(), rabbit_types:ctag(), any()) -> 'ok').
-spec(notify_sent/2 :: (pid(), pid()) -> 'ok').
-spec(unblock/2 :: (pid(), pid()) -> 'ok').
-spec(flush_all/2 :: ([pid()], pid()) -> 'ok').
-spec(internal_declare/2 ::
        (rabbit_types:amqqueue(), boolean())
        -> queue_or_not_found() | rabbit_misc:thunk(queue_or_not_found())).
-spec(internal_delete/1 ::
        (name()) -> rabbit_types:ok_or_error('not_found') |
                    rabbit_types:connection_exit() |
                    fun (() -> rabbit_types:ok_or_error('not_found') |
                               rabbit_types:connection_exit())).
-spec(run_backing_queue/3 ::
        (pid(), atom(),
         (fun ((atom(), A) -> {[rabbit_types:msg_id()], A}))) -> 'ok').
-spec(sync_timeout/1 :: (pid()) -> 'ok').
-spec(update_ram_duration/1 :: (pid()) -> 'ok').
-spec(set_ram_duration_target/2 :: (pid(), number() | 'infinity') -> 'ok').
-spec(set_maximum_since_use/2 :: (pid(), non_neg_integer()) -> 'ok').
-spec(maybe_expire/1 :: (pid()) -> 'ok').
-spec(on_node_down/1 :: (node()) -> 'ok').
-spec(pseudo_queue/2 :: (name(), pid()) -> rabbit_types:amqqueue()).

-endif.

%%----------------------------------------------------------------------------

-define(CONSUMER_INFO_KEYS,
        [queue_name, channel_pid, consumer_tag, ack_required]).

start() ->
    DurableQueues = find_durable_queues(),
    {ok, BQ} = application:get_env(rabbit, backing_queue_module),
    ok = BQ:start([QName || #amqqueue{name = QName} <- DurableQueues]),
    {ok,_} = supervisor:start_child(
               rabbit_sup,
               {rabbit_amqqueue_sup,
                {rabbit_amqqueue_sup, start_link, []},
                transient, infinity, supervisor, [rabbit_amqqueue_sup]}),
    recover_durable_queues(DurableQueues).

stop() ->
    ok = supervisor:terminate_child(rabbit_sup, rabbit_amqqueue_sup),
    ok = supervisor:delete_child(rabbit_sup, rabbit_amqqueue_sup),
    {ok, BQ} = application:get_env(rabbit, backing_queue_module),
    ok = BQ:stop().

find_durable_queues() ->
    Node = node(),
    %% TODO: use dirty ops instead
    rabbit_misc:execute_mnesia_transaction(
      fun () ->
              qlc:e(qlc:q([Q || Q = #amqqueue{pid = Pid}
                                    <- mnesia:table(rabbit_durable_queue),
                                node(Pid) == Node]))
      end).

recover_durable_queues(DurableQueues) ->
    Qs = [start_queue_process(node(), Q) || Q <- DurableQueues],
    [QName || Q = #amqqueue{name = QName, pid = Pid} <- Qs,
              gen_server2:call(Pid, {init, true}, infinity) == {new, Q}].

declare(QueueName, Durable, AutoDelete, Args, Owner) ->
    ok = check_declare_arguments(QueueName, Args),
    {Node, MNodes} = determine_queue_nodes(Args),
    Q = start_queue_process(Node, #amqqueue{name            = QueueName,
                                            durable         = Durable,
                                            auto_delete     = AutoDelete,
                                            arguments       = Args,
                                            exclusive_owner = Owner,
                                            pid             = none,
                                            slave_pids      = [],
                                            mirror_nodes    = MNodes}),
    case gen_server2:call(Q#amqqueue.pid, {init, false}, infinity) of
        not_found -> rabbit_misc:not_found(QueueName);
        Q1        -> Q1
    end.

internal_declare(Q, true) ->
    rabbit_misc:execute_mnesia_tx_with_tail(
      fun () -> ok = store_queue(Q), rabbit_misc:const(Q) end);
internal_declare(Q = #amqqueue{name = QueueName}, false) ->
    rabbit_misc:execute_mnesia_tx_with_tail(
      fun () ->
              case mnesia:wread({rabbit_queue, QueueName}) of
                  [] ->
                      case mnesia:read({rabbit_durable_queue, QueueName}) of
                          []  -> ok = store_queue(Q),
                                 B = add_default_binding(Q),
                                 fun () -> B(), Q end;
                          %% Q exists on stopped node
                          [_] -> rabbit_misc:const(not_found)
                      end;
                  [ExistingQ = #amqqueue{pid = QPid}] ->
                      case rabbit_misc:is_process_alive(QPid) of
                          true  -> rabbit_misc:const(ExistingQ);
                          false -> TailFun = internal_delete(QueueName),
                                   fun () -> TailFun(), ExistingQ end
                      end
              end
      end).

store_queue(Q = #amqqueue{durable = true}) ->
    ok = mnesia:write(rabbit_durable_queue, Q, write),
    ok = mnesia:write(rabbit_queue, Q, write),
    ok;
store_queue(Q = #amqqueue{durable = false}) ->
    ok = mnesia:write(rabbit_queue, Q, write),
    ok.

determine_queue_nodes(Args) ->
    Policy = rabbit_misc:table_lookup(Args, <<"x-ha-policy">>),
    PolicyParams = rabbit_misc:table_lookup(Args, <<"x-ha-policy-params">>),
    case {Policy, PolicyParams} of
        {{_Type, <<"nodes">>}, {array, Nodes}} ->
            case [list_to_atom(binary_to_list(Node)) ||
                     {longstr, Node} <- Nodes] of
                [Node]         -> {Node,   undefined};
                [First | Rest] -> {First,  Rest}
            end;
        {{_Type, <<"all">>}, _} ->
            {node(), all};
        _ ->
            {node(), undefined}
    end.

start_queue_process(Node, Q) ->
    {ok, Pid} = rabbit_amqqueue_sup:start_child(Node, [Q]),
    Q#amqqueue{pid = Pid}.

add_default_binding(#amqqueue{name = QueueName}) ->
    ExchangeName = rabbit_misc:r(QueueName, exchange, <<>>),
    RoutingKey = QueueName#resource.name,
    rabbit_binding:add(#binding{source      = ExchangeName,
                                destination = QueueName,
                                key         = RoutingKey,
                                args        = []}).

lookup(Name) ->
    rabbit_misc:dirty_read({rabbit_queue, Name}).

with(Name, F, E) ->
    case lookup(Name) of
        {ok, Q = #amqqueue{slave_pids = []}} ->
            rabbit_misc:with_exit_handler(E, fun () -> F(Q) end);
        {ok, Q} ->
            E1 = fun () -> timer:sleep(25), with(Name, F, E) end,
            rabbit_misc:with_exit_handler(E1, fun () -> F(Q) end);
        {error, not_found} ->
            E()
    end.

with(Name, F) ->
    with(Name, F, fun () -> {error, not_found} end).
with_or_die(Name, F) ->
    with(Name, F, fun () -> rabbit_misc:not_found(Name) end).

assert_equivalence(#amqqueue{durable     = Durable,
                             auto_delete = AutoDelete} = Q,
                   Durable, AutoDelete, RequiredArgs, Owner) ->
    assert_args_equivalence(Q, RequiredArgs),
    check_exclusive_access(Q, Owner, strict);
assert_equivalence(#amqqueue{name = QueueName},
                   _Durable, _AutoDelete, _RequiredArgs, _Owner) ->
    rabbit_misc:protocol_error(
      precondition_failed, "parameters for ~s not equivalent",
      [rabbit_misc:rs(QueueName)]).

check_exclusive_access(Q, Owner) -> check_exclusive_access(Q, Owner, lax).

check_exclusive_access(#amqqueue{exclusive_owner = Owner}, Owner, _MatchType) ->
    ok;
check_exclusive_access(#amqqueue{exclusive_owner = none}, _ReaderPid, lax) ->
    ok;
check_exclusive_access(#amqqueue{name = QueueName}, _ReaderPid, _MatchType) ->
    rabbit_misc:protocol_error(
      resource_locked,
      "cannot obtain exclusive access to locked ~s",
      [rabbit_misc:rs(QueueName)]).

with_exclusive_access_or_die(Name, ReaderPid, F) ->
    with_or_die(Name,
                fun (Q) -> check_exclusive_access(Q, ReaderPid), F(Q) end).

assert_args_equivalence(#amqqueue{name = QueueName, arguments = Args},
                        RequiredArgs) ->
    rabbit_misc:assert_args_equivalence(
      Args, RequiredArgs, QueueName,
      [<<"x-expires">>, <<"x-message-ttl">>, <<"x-ha-policy">>]).

check_declare_arguments(QueueName, Args) ->
    [case Fun(rabbit_misc:table_lookup(Args, Key), Args) of
         ok             -> ok;
         {error, Error} -> rabbit_misc:protocol_error(
                             precondition_failed,
                             "invalid arg '~s' for ~s: ~w",
                             [Key, rabbit_misc:rs(QueueName), Error])
     end || {Key, Fun} <-
                [{<<"x-expires">>,     fun check_integer_argument/2},
                 {<<"x-message-ttl">>, fun check_integer_argument/2},
                 {<<"x-ha-policy">>,   fun check_ha_policy_argument/2}]],
    ok.

check_integer_argument(undefined, _Args) ->
    ok;
check_integer_argument({Type, Val}, _Args) when Val > 0 ->
    case lists:member(Type, ?INTEGER_ARG_TYPES) of
        true  -> ok;
        false -> {error, {unacceptable_type, Type}}
    end;
check_integer_argument({_Type, Val}, _Args) ->
    {error, {value_zero_or_less, Val}}.

check_ha_policy_argument(undefined, _Args) ->
    ok;
check_ha_policy_argument({longstr, <<"all">>}, _Args) ->
    ok;
check_ha_policy_argument({longstr, <<"nodes">>}, Args) ->
    case rabbit_misc:table_lookup(Args, <<"x-ha-policy-params">>) of
        undefined ->
            {error, {require, 'x-ha-policy-params'}};
        {array, []} ->
            {error, {require_non_empty_list_of_nodes_for_ha}};
        {array, Ary} ->
            case lists:all(fun ({longstr, _Node}) -> true;
                               (_               ) -> false
                           end, Ary) of
                true  -> ok;
                false -> {error, {require_node_list_as_longstrs_for_ha, Ary}}
            end;
        {Type, _} ->
            {error, {ha_nodes_policy_params_not_array_of_longstr, Type}}
    end;
check_ha_policy_argument({longstr, Policy}, _Args) ->
    {error, {invalid_ha_policy, Policy}};
check_ha_policy_argument({Type, _}, _Args) ->
    {error, {unacceptable_type, Type}}.

list(VHostPath) ->
    mnesia:dirty_match_object(
      rabbit_queue,
      #amqqueue{name = rabbit_misc:r(VHostPath, queue), _ = '_'}).

info_keys() -> rabbit_amqqueue_process:info_keys().

map(VHostPath, F) -> rabbit_misc:filter_exit_map(F, list(VHostPath)).

info(#amqqueue{ pid = QPid }) ->
    delegate_call(QPid, info).

info(#amqqueue{ pid = QPid }, Items) ->
    case delegate_call(QPid, {info, Items}) of
        {ok, Res}      -> Res;
        {error, Error} -> throw(Error)
    end.

info_all(VHostPath) -> map(VHostPath, fun (Q) -> info(Q) end).

info_all(VHostPath, Items) -> map(VHostPath, fun (Q) -> info(Q, Items) end).

consumers(#amqqueue{ pid = QPid }) ->
    delegate_call(QPid, consumers).

consumer_info_keys() -> ?CONSUMER_INFO_KEYS.

consumers_all(VHostPath) ->
    ConsumerInfoKeys=consumer_info_keys(),
    lists:append(
      map(VHostPath,
          fun (Q) ->
              [lists:zip(ConsumerInfoKeys,
                         [Q#amqqueue.name, ChPid, ConsumerTag, AckRequired]) ||
                         {ChPid, ConsumerTag, AckRequired} <- consumers(Q)]
          end)).

stat(#amqqueue{pid = QPid}) ->
    delegate_call(QPid, stat).

emit_stats(#amqqueue{pid = QPid}) ->
    delegate_cast(QPid, emit_stats).

delete_immediately(#amqqueue{ pid = QPid }) ->
    gen_server2:cast(QPid, delete_immediately).

delete(#amqqueue{ pid = QPid }, IfUnused, IfEmpty) ->
    delegate_call(QPid, {delete, IfUnused, IfEmpty}).

purge(#amqqueue{ pid = QPid }) -> delegate_call(QPid, purge).

deliver(QPid, Delivery = #delivery{immediate = true}) ->
    gen_server2:call(QPid, {deliver_immediately, Delivery}, infinity);
deliver(QPid, Delivery = #delivery{mandatory = true}) ->
    gen_server2:call(QPid, {deliver, Delivery}, infinity),
    true;
deliver(QPid, Delivery) ->
    gen_server2:cast(QPid, {deliver, Delivery}),
    true.

requeue(QPid, MsgIds, ChPid) ->
    delegate_call(QPid, {requeue, MsgIds, ChPid}).

ack(QPid, MsgIds, ChPid) ->
    delegate_cast(QPid, {ack, MsgIds, ChPid}).

reject(QPid, MsgIds, Requeue, ChPid) ->
    delegate_cast(QPid, {reject, MsgIds, Requeue, ChPid}).

notify_down_all(QPids, ChPid) ->
    safe_delegate_call_ok(
      fun (QPid) -> gen_server2:call(QPid, {notify_down, ChPid}, infinity) end,
      QPids).

limit_all(QPids, ChPid, LimiterToken) ->
    delegate:invoke_no_result(
      QPids, fun (QPid) ->
                     gen_server2:cast(QPid, {limit, ChPid, LimiterToken})
             end).

basic_get(#amqqueue{pid = QPid}, ChPid, NoAck) ->
    delegate_call(QPid, {basic_get, ChPid, NoAck}).

basic_consume(#amqqueue{pid = QPid}, NoAck, ChPid, LimiterPid,
              ConsumerTag, ExclusiveConsume, OkMsg) ->
    delegate_call(QPid, {basic_consume, NoAck, ChPid,
                         LimiterPid, ConsumerTag, ExclusiveConsume, OkMsg}).

basic_cancel(#amqqueue{pid = QPid}, ChPid, ConsumerTag, OkMsg) ->
    ok = delegate_call(QPid, {basic_cancel, ChPid, ConsumerTag, OkMsg}).

notify_sent(QPid, ChPid) ->
    gen_server2:cast(QPid, {notify_sent, ChPid}).

unblock(QPid, ChPid) ->
    delegate_cast(QPid, {unblock, ChPid}).

flush_all(QPids, ChPid) ->
    delegate:invoke_no_result(
      QPids, fun (QPid) -> gen_server2:cast(QPid, {flush, ChPid}) end).

internal_delete1(QueueName) ->
    ok = mnesia:delete({rabbit_queue, QueueName}),
    ok = mnesia:delete({rabbit_durable_queue, QueueName}),
    %% we want to execute some things, as decided by rabbit_exchange,
    %% after the transaction.
    rabbit_binding:remove_for_destination(QueueName).

internal_delete(QueueName) ->
    rabbit_misc:execute_mnesia_tx_with_tail(
      fun () ->
              case mnesia:wread({rabbit_queue, QueueName}) of
                  []  -> rabbit_misc:const({error, not_found});
                  [_] -> Deletions = internal_delete1(QueueName),
                         rabbit_binding:process_deletions(Deletions)
              end
      end).

run_backing_queue(QPid, Mod, Fun) ->
    gen_server2:cast(QPid, {run_backing_queue, Mod, Fun}).

sync_timeout(QPid) ->
    gen_server2:cast(QPid, sync_timeout).

update_ram_duration(QPid) ->
    gen_server2:cast(QPid, update_ram_duration).

set_ram_duration_target(QPid, Duration) ->
    gen_server2:cast(QPid, {set_ram_duration_target, Duration}).

set_maximum_since_use(QPid, Age) ->
    gen_server2:cast(QPid, {set_maximum_since_use, Age}).

maybe_expire(QPid) ->
    gen_server2:cast(QPid, maybe_expire).

drop_expired(QPid) ->
    gen_server2:cast(QPid, drop_expired).

on_node_down(Node) ->
    rabbit_misc:execute_mnesia_tx_with_tail(
      fun () -> Dels = qlc:e(qlc:q([delete_queue(QueueName) ||
                                       #amqqueue{name = QueueName, pid = Pid,
                                                 slave_pids = []}
                                           <- mnesia:table(rabbit_queue),
                                       node(Pid) == Node])),
                rabbit_binding:process_deletions(
                  lists:foldl(fun rabbit_binding:combine_deletions/2,
                              rabbit_binding:new_deletions(), Dels))
      end).

delete_queue(QueueName) ->
    ok = mnesia:delete({rabbit_queue, QueueName}),
    rabbit_binding:remove_transient_for_destination(QueueName).

pseudo_queue(QueueName, Pid) ->
    #amqqueue{name         = QueueName,
              durable      = false,
              auto_delete  = false,
              arguments    = [],
              pid          = Pid,
              slave_pids   = [],
              mirror_nodes = undefined}.

safe_delegate_call_ok(F, Pids) ->
    case delegate:invoke(Pids, fun (Pid) ->
                                       rabbit_misc:with_exit_handler(
                                         fun () -> ok end,
                                         fun () -> F(Pid) end)
                               end) of
        {_,  []} -> ok;
        {_, Bad} -> {error, Bad}
    end.

delegate_call(Pid, Msg) ->
    delegate:invoke(Pid, fun (P) -> gen_server2:call(P, Msg, infinity) end).

delegate_cast(Pid, Msg) ->
    delegate:invoke_no_result(Pid, fun (P) -> gen_server2:cast(P, Msg) end).
