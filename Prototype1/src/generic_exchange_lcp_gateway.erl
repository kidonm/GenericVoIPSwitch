-module(generic_exchange_lcp_gateway).

-behaviour(gen_server).

-export([start_link/1, init/1, code_change/3, terminate/2]).
-export([handle_info/2, handle_cast/2, handle_call/3]).

-export([route_lcp/3, transmit_generic/1, remove_lcp_client/1]).

-include("../include/generic_exchange.hrl").

-record(lcp_gateway_state, {
		client_table
	}).

-spec route_lcp({}, inet:ip_address(), inet:port_number()) ->
	ok.

route_lcp(Msg, _IP, _Port) ->
	gen_server:call(?MODULE, {route_lcp_msg, Msg, _IP, _Port}).

-spec transmit_generic(#generic_msg{}) ->
	ok.

transmit_generic(Msg=#generic_msg{}) ->
	gen_server:call(?MODULE, {transmit_generic_msg, Msg}).

-spec remove_lcp_client(pid())->
	ok.

remove_lcp_client(PID) ->
	gen_server:call(?MODULE, {remove_lcp_client, PID}).

start_link(LCPClientEts) ->
 	gen_server:start_link({local, ?MODULE}, ?MODULE, [LCPClientEts], []).

init([LCPETS]) ->
	{ok, 
		#lcp_gateway_state{client_table=LCPETS}
	}.

code_change(_Old, State, _Extra)->
	{ok, State}.

terminate(_Reason, _State) ->
	lager:warning("~p terminated while because ~p", [?MODULE,  _Reason]),
	normal.

-spec handle_call({Action, Msg, inet:ip_address(), inet:port_number()}, term(), term()) ->
	{reply, ok, term()} | {noreply, term()}
	when Action :: route_sip_msg | transmit_generic_msg,
		 Msg :: {} | #generic_msg{}.


handle_call({route_lcp_msg, Msg, IP, Port}, From, 
	State=#lcp_gateway_state{client_table=Table}) ->
	gen_server:reply(From, ok),

	case resolve_lcp_client(IP, Port, Table) of 
		{ok, PID} ->
			case gen_fsm:sync_send_event(PID, Msg) of
				{route, MSG} -> 
					generic_exchange_dialog_router:route_message(MSG);
				do_nothing ->
					do_nothing;
				Error ->
					lager:info("this should never ever happen ~p", [Error])

			end;
		{error, not_found} ->
			{ok, PID} = supervisor:start_child(generic_exchange_lcp_client_sup,
				[IP,Port,"1018"]),
			add_lcp_client(IP, Port, PID, Table),
			case gen_fsm:sync_send_event(PID, Msg) of
				{route, MSG} -> 
					lager:info("message routed", []),
					generic_exchange_dialog_router:route_message(MSG);
				do_nothing ->
					do_nothing;
				Error ->
					io:format("this should never ever happen ~p", [Error])
			end
	end,	

	{noreply, State};

handle_call({transmit_generic_msg, {Msg=#generic_msg{}, IP, Port}}, From,
	State=#lcp_gateway_state{client_table=Table}) ->
	lager:info("received generic message in transmit_generic_msg ~p ~p : ~p", [Msg, IP, Port]),	
	gen_server:reply(From, ok),
	case resolve_lcp_client(IP, Port, Table) of 
		{ok, PID} ->
			case gen_fsm:sync_send_event(PID, Msg) of
				do_nothing ->
					ok;
				Error ->
					lager:info("this should never ever happen ~p", [Error])
			end
	end,
	{noreply, State};

handle_call({remove_lcp_client, PID}, _From, State=#lcp_gateway_state{client_table=Table}) ->
	Result = case remove_lcp_client(PID, Table) of 
		true ->
			ok;
		Error -> 
			{error, couldnt_remove_lcp_client}
	end,
	{reply, Result, State};

handle_call(_Msg, _From, _State) ->
	lager:warning('~p received an invalid synchronous message ~p', [?MODULE, _Msg]),
	{noreply, _State}.


-spec handle_cast(term(), term()) ->
	{noreply, term()}.

handle_cast(_Msg, _State) ->
	lager:warning('?MODULE received an unexpected asynchronous message'),
	{noreply, _State}.

-spec handle_info(term(), term()) ->
	{noreply, term()}.

handle_info(_Msg, _State) ->
	lager:warning('?MODULE received an unexpected message'),
	{noreply, _State}.


% helper functions


resolve_lcp_client(IP, Port, Ets) ->
	case ets:match(Ets, {IP, Port, '$1'}) of
		[[PID]] -> {ok, PID};
		[] -> {error, not_found}
 	end.
 
remove_lcp_client(PID, Ets) ->
	ets:match_delete(Ets, {'_', '_', PID}).

-spec add_lcp_client(inet:ip_address(), inet:network_port(), pid(), ets:table()) ->
	true.

add_lcp_client(IP, Port, PID, ETS) ->
	io:format("adding new client ~p", [PID]),
	ets:insert(ETS, {IP, Port, PID}).
