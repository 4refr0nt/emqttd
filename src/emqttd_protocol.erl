%%--------------------------------------------------------------------
%% Copyright (c) 2012-2016 Feng Lee <feng@emqtt.io>.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emqttd_protocol).

-include("emqttd.hrl").

-include("emqttd_protocol.hrl").

-include("emqttd_internal.hrl").

-import(proplists, [get_value/2, get_value/3]).

%% API
-export([init/3, info/1, clientid/1, client/1]).

-export([received/2, handle/2, deliver/3, send/2, timeout/2, shutdown/2]).

-export([process/2]).
 
%% Protocol State
-record(proto_state, {peername, sendfun, connected = false,
                      client_id, client_pid, clean_sess,
                      proto_ver, proto_name, username,
                      will_msg, keepalive,
                      max_clientid_len = ?MAX_CLIENTID_LEN,
                      %% Last packet id of the session
                      packet_id = 1,
                      %% Client’s subscriptions.
                      subscriptions = #{},
                      %% Inflight Queue
                      inflight = [],
                      %% Client’s subscriptions.
                      awaiting_ack = #{},
                      %% Retry interval for redelivering QoS1 messages
                      retry_interval = 30,
                      %% Headers from first HTTP request for websocket client
                      ws_initial_headers,
                      %% Connected at
                      connected_at}).

-type(proto_state() :: #proto_state{}).

-define(INFO_KEYS, [client_id, username, clean_sess, proto_ver, proto_name,
                    keepalive, will_msg, ws_initial_headers, connected_at]).

-define(LOG(Level, Format, Args, State),
            lager:Level([{client, State#proto_state.client_id}], "Client(~s@~s): " ++ Format,
                        [State#proto_state.client_id, esockd_net:format(State#proto_state.peername) | Args])).

%% @doc Init protocol
init(Peername, SendFun, Opts) ->
    MaxLen = get_value(max_clientid_len, Opts, ?MAX_CLIENTID_LEN),
    WsInitialHeaders = get_value(ws_initial_headers, Opts),
    #proto_state{peername           = Peername,
                 sendfun            = SendFun,
                 max_clientid_len   = MaxLen,
                 client_pid         = self(),
                 ws_initial_headers = WsInitialHeaders}.

info(ProtoState) ->
    ?record_to_proplist(proto_state, ProtoState, ?INFO_KEYS).

clientid(#proto_state{client_id = ClientId}) ->
    ClientId.

client(#proto_state{client_id          = ClientId,
                    client_pid         = ClientPid,
                    peername           = Peername,
                    username           = Username,
                    clean_sess         = CleanSess,
                    proto_ver          = ProtoVer,
                    keepalive          = Keepalive,
                    will_msg           = WillMsg,
                    ws_initial_headers = WsInitialHeaders,
                    connected_at       = Time}) ->
    WillTopic = if
                    WillMsg =:= undefined -> undefined;
                    true -> WillMsg#mqtt_message.topic
                end,
    #mqtt_client{client_id          = ClientId,
                 client_pid         = ClientPid,
                 username           = Username,
                 peername           = Peername,
                 clean_sess         = CleanSess,
                 proto_ver          = ProtoVer,
                 keepalive          = Keepalive,
                 will_topic         = WillTopic,
                 ws_initial_headers = WsInitialHeaders,
                 connected_at       = Time}.

%% CONNECT – Client requests a connection to a Server

%% A Client can only send the CONNECT Packet once over a Network Connection.
-spec(received(mqtt_packet(), proto_state()) -> {ok, proto_state()} | {error, any()}).
received(Packet = ?PACKET(?CONNECT), State = #proto_state{connected = false}) ->
    process(Packet, State#proto_state{connected = true});

received(?PACKET(?CONNECT), State = #proto_state{connected = true}) ->
    {error, protocol_bad_connect, State};

%% Received other packets when CONNECT not arrived.
received(_Packet, State = #proto_state{connected = false}) ->
    {error, protocol_not_connected, State};

received(Packet = ?PACKET(_Type), State) ->
    trace(recv, Packet, State),
    case validate_packet(Packet) of
        ok ->
            process(Packet, State);
        {error, Reason} ->
            {error, Reason, State}
    end.

process(Packet = ?CONNECT_PACKET(Var), State0) ->

    #mqtt_packet_connect{proto_ver  = ProtoVer,
                         proto_name = ProtoName,
                         username   = Username,
                         password   = Password,
                         clean_sess = CleanSess,
                         keep_alive = KeepAlive,
                         client_id  = ClientId} = Var,

    State1 = State0#proto_state{proto_ver  = ProtoVer,
                                proto_name = ProtoName,
                                username   = Username,
                                client_id  = ClientId,
                                clean_sess = CleanSess,
                                keepalive  = KeepAlive,
                                will_msg   = willmsg(Var),
                                connected_at = os:timestamp()},

    trace(recv, Packet, State1),

    {ReturnCode1, SessPresent, State3} =
    case validate_connect(Var, State1) of
        ?CONNACK_ACCEPT ->
            case emqttd_access_control:auth(client(State1), Password) of
                ok ->
                    %% Generate clientId if null
                    State2 = maybe_set_clientid(State1),

                    %% Register the client
                    emqttd_cm:reg(client(State2)),

                    %% Start keepalive
                    start_keepalive(KeepAlive),

                    %% ACCEPT
                    {?CONNACK_ACCEPT, false, State2};
                {error, Reason}->
                    ?LOG(error, "Username '~s' login failed for ~p", [Username, Reason], State1),
                    {?CONNACK_CREDENTIALS, false, State1}
            end;
        ReturnCode ->
            {ReturnCode, false, State1}
    end,
    %% Run hooks
    emqttd:run_hooks('client.connected', [ReturnCode1], client(State3)),
    %% Send connack
    send(?CONNACK_PACKET(ReturnCode1, sp(SessPresent)), State3);

process(Packet = ?PUBLISH_PACKET(_Qos, Topic, _PacketId, _Payload), State) ->
    case check_acl(publish, Topic, client(State)) of
        allow ->
            publish(Packet, State);
        deny ->
            ?LOG(error, "Cannot publish to ~s for ACL Deny", [Topic], State)
    end,
    {ok, State};

process(?PUBACK_PACKET(?PUBACK, PktId), State = #proto_state{awaiting_ack = AwaitingAck}) ->
    case maps:find(PktId, AwaitingAck) of
        {ok, TRef} ->
            cancel_timer(TRef),
            acked(PktId, State);
        error ->
            ?LOG(warning, "Cannot find PUBACK: ~p", [PktId], State),
            {ok, State}
    end;

%% Protect from empty topic table
process(?SUBSCRIBE_PACKET(PacketId, []), State) ->
    send(?SUBACK_PACKET(PacketId, []), State);

process(?SUBSCRIBE_PACKET(PacketId, TopicTable), State) ->
    Client = client(State),
    AllowDenies = [check_acl(subscribe, Topic, Client) || {Topic, _Qos} <- TopicTable],
    case lists:member(deny, AllowDenies) of
        true ->
            ?LOG(error, "Cannot SUBSCRIBE ~p for ACL Deny", [TopicTable], State),
            send(?SUBACK_PACKET(PacketId, [16#80 || _ <- TopicTable]), State);
        false ->
            {ok, NewState} = handle({subscribe, TopicTable}, State),
            send(?SUBACK_PACKET(PacketId, [degrade_qos(Qos) || {_, Qos} <- TopicTable]), NewState)
    end;

%% Protect from empty topic list
process(?UNSUBSCRIBE_PACKET(PacketId, []), State) ->
    send(?UNSUBACK_PACKET(PacketId), State);

process(?UNSUBSCRIBE_PACKET(PacketId, Topics), State) ->
    {ok, NewState} = handle({unsubscribe, Topics}, State),
    send(?UNSUBACK_PACKET(PacketId), NewState);

process(?PACKET(?PINGREQ), State) ->
    send(?PACKET(?PINGRESP), State);

process(?PACKET(?DISCONNECT), State) ->
    % Clean willmsg
    {stop, normal, State#proto_state{will_msg = undefined}}.

publish(Packet = ?PUBLISH_PACKET(?QOS_0, _PacketId),
        #proto_state{client_id = ClientId, username = Username}) ->
    emqttd:publish(emqttd_message:from_packet(Username, ClientId, Packet));

publish(Packet = ?PUBLISH_PACKET(?QOS_1, PacketId),
        State = #proto_state{client_id = ClientId, username = Username}) ->
    emqttd:publish(emqttd_message:from_packet(Username, ClientId, Packet)),
    send(?PUBACK_PACKET(?PUBACK, PacketId), State).

%%Let it crash...
%%publish(Packet = ?PUBLISH_PACKET(?QOS_2, _PacketId), State) ->
%%    with_puback(?PUBREC, Packet, State).

handle({subscribe, RawTopicTable}, State = #proto_state{client_id = ClientId,
                                                        username = Username,
                                                        subscriptions = Subscriptions}) ->
    ?LOG(info, "Subscribe ~p", [RawTopicTable], State),
    ParsedTopicTable = lists:map(fun({RawTopic, Qos}) ->
                {Topic, Opts} = emqttd_topic:parse(RawTopic),
                {Topic, [{qos, Qos} | Opts]}
        end, RawTopicTable),
    {ok, TopicTable} = emqttd:run_hooks('client.subscribe', [{ClientId, Username}], ParsedTopicTable),
    Subscriptions1 = lists:foldl(fun({Topic, Opts}, SubMap) ->
                Qos = degrade_qos(proplists:get_value(qos, Opts)),
                case maps:find(Topic, SubMap) of
                    {ok, Qos} ->
                        ?LOG(warning, "duplicated subscribe: ~s, qos = ~w", [Topic, Qos], State),
                        SubMap;
                    {ok, OldQos} ->
                        ?LOG(warning, "duplicated subscribe ~s, old_qos=~w, new_qos=~w", [Topic, OldQos, Qos], State),
                        emqttd:setqos(Topic, ClientId, Qos),
                        maps:put(Topic, Qos, SubMap);
                    error ->
                        emqttd:subscribe(Topic, ClientId, Opts),
                        emqttd:run_hooks('client.subscribed', [{ClientId, Username}], {Topic, Opts}),
                        maps:put(Topic, Qos, SubMap)
                end
        end, Subscriptions, TopicTable),
    {ok, State#proto_state{subscriptions = Subscriptions1}};

handle({unsubscribe, RawTopics}, State = #proto_state{client_id = ClientId,
                                                      username = Username,
                                                      subscriptions = Subscriptions}) ->
    ?LOG(info, "unsubscribe ~p", [RawTopics], State),
    ParsedTopics = [emqttd_topic:parse(Topic) || Topic <- RawTopics],
    {ok, Topics} = emqttd:run_hooks('client.unsubscribe', [{ClientId, Username}], ParsedTopics),
    Subscriptions1 = lists:foldl(fun({Topic, _Opts}, SubMap) ->
                case maps:find(Topic, SubMap) of
                    {ok, _Qos} ->
                        emqttd:unsubscribe(Topic, ClientId),
                        maps:remove(Topic, SubMap);
                    error ->
                        SubMap
                end
        end, Subscriptions, Topics),
    {ok, State#proto_state{subscriptions = Subscriptions1}}.

timeout({awaiting_ack, PacketId}, State = #proto_state{inflight = InflightQ,
                                                       awaiting_ack = AwaitingAck}) ->

    case maps:find(PacketId, AwaitingAck) of
        {ok, _TRef} ->
            case lists:keyfind(PacketId, 1, InflightQ) of
                {_, Msg} ->
                    redeliver(Msg, State);
                false ->
                    ?LOG(error, "AwaitingAck timeout but Cannot find PktId: ~p", [PacketId], State),
                    {ok, State}
                end;
        error ->
            ?LOG(error, "Cannot find AwaitingAck: ~p", [PacketId], State),
            {ok, State}
    end.

%%--------------------------------------------------------------------
%% Deliver Messages
%%--------------------------------------------------------------------

deliver(Topic, Msg = #mqtt_message{qos = Qos}, State = #proto_state{subscriptions = Subscriptions}) ->
    deliver(tune_qos(Topic, Msg#mqtt_message{qos = degrade_qos(Qos)}, Subscriptions), State).

deliver(Msg = #mqtt_message{qos = ?QOS0}, State) ->
    send(Msg, State);

deliver(Msg = #mqtt_message{qos = ?QOS1}, State = #proto_state{inflight = InflightQ,
                                                               packet_id = PktId}) ->
    send(Msg1 = Msg#mqtt_message{pktid = PktId, dup = false}, State),
    await(Msg1, next_packet_id(State#proto_state{inflight = [{PktId, Msg1}|InflightQ]})).

redeliver(Msg = #mqtt_message{qos = ?QOS_1}, State) ->
    send(Msg1 = Msg#mqtt_message{dup = true}, State),
    await(Msg1, State).

%%--------------------------------------------------------------------
%% Awaiting PubAck for Qos1 Message
%%--------------------------------------------------------------------
await(#mqtt_message{pktid = PktId}, State = #proto_state{
        awaiting_ack = Awaiting, retry_interval = Timeout}) ->
    TRef = timer(Timeout, {timeout, awaiting_ack, PktId}),
    Awaiting1 = maps:put(PktId, TRef, Awaiting),
    {ok, State#proto_state{awaiting_ack = Awaiting1}}.

acked(PktId, State = #proto_state{client_id    = ClientId,
                                  username     = Username,
                                  inflight     = InflightQ,
                                  awaiting_ack = Awaiting}) ->
    case lists:keyfind(PktId, 1, InflightQ) of
        {_, Msg} ->
            emqttd:run_hooks('message.acked', [{ClientId, Username}], Msg);
        false ->
            ?LOG(error, "Cannot find acked pktid: ~p", [PktId], State)
    end,
    {ok, State#proto_state{awaiting_ack = maps:remove(PktId, Awaiting),
                           inflight     = lists:keydelete(PktId, 1, InflightQ)}}.

next_packet_id(State = #proto_state{packet_id = 16#ffff}) ->
    State#proto_state{packet_id = 1};

next_packet_id(State = #proto_state{packet_id = Id}) ->
    State#proto_state{packet_id = Id + 1}.

timer(TimeoutSec, TimeoutMsg) ->
    erlang:send_after(timer:seconds(TimeoutSec), self(), TimeoutMsg).

cancel_timer(undefined) -> 
    undefined;
cancel_timer(Ref) -> 
    catch erlang:cancel_timer(Ref).

-spec(send(mqtt_message() | mqtt_packet(), proto_state()) -> {ok, proto_state()}).
send(Msg, State = #proto_state{client_id = ClientId, username = Username})
        when is_record(Msg, mqtt_message) ->
    emqttd:run_hooks('message.delivered', [{ClientId, Username}], Msg),
    send(emqttd_message:to_packet(Msg), State);

send(Packet, State = #proto_state{sendfun = SendFun})
    when is_record(Packet, mqtt_packet) ->
    trace(send, Packet, State),
    emqttd_metrics:sent(Packet),
    SendFun(Packet),
    {ok, State}.

trace(recv, Packet, ProtoState) ->
    ?LOG(info, "RECV ~s", [emqttd_packet:format(Packet)], ProtoState);

trace(send, Packet, ProtoState) ->
    ?LOG(info, "SEND ~s", [emqttd_packet:format(Packet)], ProtoState).

shutdown(_Error, #proto_state{client_id = undefined}) ->
    ignore;

shutdown(conflict, #proto_state{client_id = _ClientId}) ->
    %% let it down
    %% emqttd_cm:unreg(ClientId);
    ignore;

shutdown(Error, State = #proto_state{will_msg = WillMsg}) ->
    ?LOG(info, "Shutdown for ~p", [Error], State),
    Client = client(State),
    send_willmsg(Client, WillMsg),
    emqttd:run_hooks('client.disconnected', [Error], Client),
    %% let it down
    %% emqttd_cm:unreg(ClientId).
    ok.

willmsg(Packet) when is_record(Packet, mqtt_packet_connect) ->
    emqttd_message:from_packet(Packet).

%% Generate a client if if nulll
maybe_set_clientid(State = #proto_state{client_id = NullId})
        when NullId =:= undefined orelse NullId =:= <<>> ->
    {_, NPid, _} = emqttd_guid:new(),
    ClientId = iolist_to_binary(["emqttd_", integer_to_list(NPid)]),
    State#proto_state{client_id = ClientId};

maybe_set_clientid(State) ->
    State.

send_willmsg(_Client, undefined) ->
    ignore;
send_willmsg(#mqtt_client{client_id = ClientId, username = Username}, WillMsg) ->
    emqttd:publish(WillMsg#mqtt_message{from = {ClientId, Username}}).

start_keepalive(0) -> ignore;

start_keepalive(Sec) when Sec > 0 ->
    self() ! {keepalive, start, round(Sec * 1.25)}.

%%--------------------------------------------------------------------
%% Validate Packets
%%--------------------------------------------------------------------

validate_connect(Connect = #mqtt_packet_connect{}, ProtoState) ->
    case validate_protocol(Connect) of
        true -> 
            case validate_clientid(Connect, ProtoState) of
                true -> 
                    ?CONNACK_ACCEPT;
                false -> 
                    ?CONNACK_INVALID_ID
            end;
        false -> 
            ?CONNACK_PROTO_VER
    end.

validate_protocol(#mqtt_packet_connect{proto_ver = Ver, proto_name = Name}) ->
    lists:member({Ver, Name}, ?PROTOCOL_NAMES).

validate_clientid(#mqtt_packet_connect{client_id = ClientId},
                  #proto_state{max_clientid_len = MaxLen})
    when (size(ClientId) >= 1) andalso (size(ClientId) =< MaxLen) ->
    true;

%% Issue#599: Null clientId and clean_sess = false
validate_clientid(#mqtt_packet_connect{client_id  = ClientId,
                                       clean_sess = CleanSess}, _ProtoState)
    when size(ClientId) == 0 andalso (not CleanSess) ->
    false;

%% MQTT3.1.1 allow null clientId.
validate_clientid(#mqtt_packet_connect{proto_ver =?MQTT_PROTO_V311,
                                       client_id = ClientId}, _ProtoState)
    when size(ClientId) =:= 0 ->
    true;

validate_clientid(#mqtt_packet_connect{proto_ver  = ProtoVer,
                                       clean_sess = CleanSess}, ProtoState) ->
    ?LOG(warning, "Invalid clientId. ProtoVer: ~p, CleanSess: ~s",
         [ProtoVer, CleanSess], ProtoState),
    false.

validate_packet(?PUBLISH_PACKET(_Qos, Topic, _PacketId, _Payload)) ->
    case emqttd_topic:validate({name, Topic}) of
        true  -> ok;
        false -> {error, badtopic}
    end;

validate_packet(?SUBSCRIBE_PACKET(_PacketId, TopicTable)) ->
    validate_topics(filter, TopicTable);

validate_packet(?UNSUBSCRIBE_PACKET(_PacketId, Topics)) ->
    validate_topics(filter, Topics);

validate_packet(_Packet) -> 
    ok.

validate_topics(_Type, []) ->
    {error, empty_topics};

validate_topics(Type, TopicTable = [{_Topic, _Qos}|_])
    when Type =:= name orelse Type =:= filter ->
    Valid = fun(Topic, Qos) ->
              emqttd_topic:validate({Type, Topic}) and validate_qos(Qos)
            end,
    case [Topic || {Topic, Qos} <- TopicTable, not Valid(Topic, Qos)] of
        [] -> ok;
        _  -> {error, badtopic}
    end;

validate_topics(Type, Topics = [Topic0|_]) when is_binary(Topic0) ->
    case [Topic || Topic <- Topics, not emqttd_topic:validate({Type, Topic})] of
        [] -> ok;
        _  -> {error, badtopic}
    end.

validate_qos(undefined) ->
    true;
validate_qos(Qos) when ?IS_QOS(Qos) ->
    true;
validate_qos(_) ->
    false.

%% PUBLISH ACL is cached in process dictionary.
check_acl(publish, Topic, Client) ->
    IfCache = emqttd:conf(cache_acl, true),
    case {IfCache, get({acl, publish, Topic})} of
        {true, undefined} ->
            AllowDeny = emqttd_access_control:check_acl(Client, publish, Topic),
            put({acl, publish, Topic}, AllowDeny),
            AllowDeny;
        {true, AllowDeny} ->
            AllowDeny;
        {false, _} ->
            emqttd_access_control:check_acl(Client, publish, Topic)
    end;

check_acl(subscribe, Topic, Client) ->
    emqttd_access_control:check_acl(Client, subscribe, Topic).

sp(true)  -> 1;
sp(false) -> 0.

degrade_qos(?QOS_2) -> ?QOS_1;
degrade_qos(Qos)    -> Qos.

tune_qos(Topic, Msg = #mqtt_message{qos = PubQos}, Subscriptions) ->
    case maps:find(Topic, Subscriptions) of
        {ok, SubQos} when PubQos > SubQos ->
            Msg#mqtt_message{qos = SubQos};
        {ok, _SubQos} ->
            Msg;
        error ->
            Msg
    end.
