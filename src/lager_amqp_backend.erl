%% Copyright (c) 2011 by Jon Brisbin. All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% Modified by Stephen Gibberd 2019 to support dialyzer, and latest version
%% of lager.

-module(lager_amqp_backend).
-behaviour(gen_event).

-include_lib("amqp_client/include/amqp_client.hrl").

-export([ init/1, handle_call/2, handle_event/2, handle_info/2, terminate/2,
	  code_change/3, test/0
	]).
-import(proplists,[get_value/3]).


-type leveltype() :: debug | info | notice | warning | error | critical | alert | emergency | none.
-type lager_msg() :: lager_msg:lager_msg().

-record(state, { 
		 name :: atom(), 
		 level :: non_neg_integer(), 
		 exchange :: binary(), 
		 params :: #amqp_params_network{} 
	       }).

-spec init([{atom(),term()}]) -> {ok,#state{}}.
init(Params) ->
    Name = get_value(name, Params, ?MODULE),  
    Level = get_value(level, Params, debug),
    Exchange = get_value(exchange, Params, atom_to_binary(?MODULE,latin1)),
  
    AmqpParams = #amqp_params_network {
		    username = get_value(amqp_user, Params, <<"guest">>),
		    password = get_value(amqp_pass, Params, <<"guest">>),
		    virtual_host = get_value(amqp_vhost, Params, <<"/">>),
		    host = get_value(amqp_host, Params, "localhost"),
		    port = get_value(amqp_port, Params, 5672)
		   },
    
    {ok, Channel} = amqp_channel(AmqpParams),
    #'exchange.declare_ok'{} = amqp_channel:call(Channel, #'exchange.declare'{ exchange = Exchange, type = <<"topic">> }),
    
    {ok, #state{ name = Name, level = Level, exchange = Exchange,
		 params = AmqpParams }}.

-spec handle_call(term(),#state{}) -> {ok, ok | leveltype(), #state{}}.
handle_call({set_loglevel, Level}, #state{ name = _Name } = State) ->
    {ok, ok, State#state{ level=lager_util:level_to_num(Level) }};
handle_call(get_loglevel, #state{ level = Level } = State) ->
    {ok, Level, State};
handle_call(_Request, State) ->
    {ok, ok, State}.

-spec handle_event({log,lager_msg()} 
		   | {log,[{atom(),atom()}],non_neg_integer(), {calendar:date(),calendar:time()},string()} 
		   | {log,non_neg_integer(),{calendar:date(),calendar:time()},string()}
		  ,#state{}) -> {ok,#state{}}.
%%% latest version of lager
handle_event({log, Msg}, #state{ level = L,name=Name } = State) ->
    case lager_util:is_loggable(Msg,L,Name) of
	true ->
	    log(lager_msg:severity(Msg),lager_msg:datetime(Msg), 
		lager_msg:message(Msg),State);
	false ->
	    nothing
    end,
    {ok,State};

%%% For older versions of lager
handle_event({log, Dest, Level, {Date, Time}, Message}, #state{ name = Name, level = L} = State) when Level > L ->
    case lists:member({lager_amqp_backend, Name}, Dest) of
	true ->
	    {ok, log(Level, Date, Time, Message, State)};
	false ->
	    {ok, State}
    end;
handle_event({log, Level, {Date, Time}, Message}, #state{ level = L } = State) when Level =< L->
    {ok, log(Level, Date, Time, Message, State)};
handle_event(_Event, State) ->
    {ok, State}.

handle_info(_Info, State) ->
    {ok, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

-spec log(leveltype(), {string(),string()}, string(), #state{}) -> #state{}.
log(Level, {Date,Time}, Message, State) ->
    log(Level, Date, Time, Message, State).

-spec log(leveltype(), string(), string(), string(), #state{}) -> #state{}.
log(Level, Date, Time, Message, #state{params = AmqpParams } = State) ->
  case amqp_channel(AmqpParams) of
    {ok, Channel} ->
      send(State, Level, [Date, " ", Time, " ", Message], Channel);
    _ ->
      State
  end.

-spec send(#state{}, leveltype(), string(),any()) -> #state{}.
send(#state{ name = Name, exchange = Exchange } = State, Level, Message, Channel) ->
    RkPrefix = atom_to_binary(Level,latin1),
    BinName = atom_to_binary(Name,latin1),
    RoutingKey = <<RkPrefix/binary,".",BinName/binary>>,
    Publish = #'basic.publish'{ exchange = Exchange, routing_key = RoutingKey },
    Props = #'P_basic'{ content_type = <<"text/plain">> },
    Body = list_to_binary(lists:flatten(Message)),
    Msg = #amqp_msg{ payload = Body, props = Props },
    
    %% io:format("message: ~p~n", [Msg]),
    amqp_channel:cast(Channel, Publish, Msg),
    
    State.

-spec amqp_channel(#amqp_params_network{}) -> term().
amqp_channel(AmqpParams) ->
    case maybe_new_pid({AmqpParams, connection},
		       fun() -> amqp_connection:start(AmqpParams) end) of
	{ok, Client} ->
	    maybe_new_pid({AmqpParams, channel},
			  fun() -> amqp_connection:open_channel(Client) end);
	Error ->
	    Error
    end.

-spec maybe_new_pid({#amqp_params_network{},connection | channel}, fun()) -> term().
maybe_new_pid(Group, StartFun) ->
    case pg2:get_closest_pid(Group) of
	{error, {no_such_group, _}} ->
	    pg2:create(Group),
	    maybe_new_pid(Group, StartFun);
	{error, {no_process, _}} ->
	    case StartFun() of
		{ok, Pid} ->
		    pg2:join(Group, Pid),
		    {ok, Pid};
		Error ->
		    Error
	    end;
	Pid ->
	    {ok, Pid}
    end.

test() ->
    application:load(lager),
    application:set_env(lager, handlers, [{lager_console_backend, debug}, {lager_amqp_backend, []}]),
    application:set_env(lager, error_logger_redirect, false),
    application:ensure_all_started(lager),
    lager:log(info, self(), "Test INFO message"),
    lager:log(debug, self(), "Test DEBUG message"),
    lager:log(error, self(), "Test ERROR message").
    
  
