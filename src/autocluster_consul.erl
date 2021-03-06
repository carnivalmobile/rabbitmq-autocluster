%%==============================================================================
%% @author Gavin M. Roy <gavinr@aweber.com>
%% @copyright 2015-2016 AWeber Communications
%% @end
%%==============================================================================
-module(autocluster_consul).

-behavior(autocluster_backend).

%% autocluster_backend methods
-export([nodelist/0,
         register/0,
         unregister/0]).

%% For timer based health checking
-export([init/0,
         send_health_check_pass/0]).

%% Ignore this (is used so we can stub with meck in tests)
-export([build_registration_body/0]).

%% Export all for unit tests
-ifdef(TEST).
-compile(export_all).
-endif.


-rabbit_boot_step({?MODULE,
                   [{description, <<"Autocluster Consul Initialization">>},
                    {mfa,         {autocluster_consul, init, []}},
                    {requires,    notify_cluster}]}).


-include("autocluster.hrl").


%%--------------------------------------------------------------------
%% @doc
%% Kick of the Consul TTL health check pass timer. Have the timer
%% fire at half the expected TTL to ensure the service is never
%% marked as offline by Consul.
%% @end
%%--------------------------------------------------------------------
-spec init() -> ok.
init() ->
  case autocluster_config:get(backend) of
    consul ->
      case autocluster_config:get(consul_svc_ttl) of
        undefined -> ok;
        Interval  ->
          autocluster_log:debug("Starting Consul health check TTL timer"),
          {ok, _} = timer:apply_interval(Interval * 500, ?MODULE,
                                         send_health_check_pass, []),
          ok
      end;
    _ -> ok
  end.


%%--------------------------------------------------------------------
%% @doc
%% Return a list of healthy nodes registered in Consul
%% @end
%%--------------------------------------------------------------------
-spec nodelist() -> {ok, list()}|{error, Reason :: string()}.
nodelist() ->
  case autocluster_httpc:get(autocluster_config:get(consul_scheme),
                             autocluster_config:get(consul_host),
                             autocluster_config:get(consul_port),
                             [v1, health, service,
                              autocluster_config:get(consul_svc)],
                             node_list_qargs()) of
    {ok, Nodes} ->
      Result = extract_nodes(
             filter_nodes(Nodes,
                          autocluster_config:get(consul_include_nodes_with_warnings))),
      {ok, Result};
    {error, _} = Error ->
          Error
  end.


%%--------------------------------------------------------------------
%% @doc
%% Register with Consul as providing rabbitmq service
%% @end
%%--------------------------------------------------------------------
-spec register() -> ok | {error, Reason :: string()}.
register() ->
  case registration_body() of
    {ok, Body} ->
      case autocluster_httpc:post(autocluster_config:get(consul_scheme),
                                  autocluster_config:get(consul_host),
                                  autocluster_config:get(consul_port),
                                  [v1, agent, service, register],
                                  maybe_add_acl([]), Body) of
        {ok, _} -> ok;
        Error   -> Error
      end;
    Error -> Error
  end.


%%--------------------------------------------------------------------
%% @doc
%% Let Consul know that the health check should be passing
%% @end
%%--------------------------------------------------------------------
-spec send_health_check_pass() -> ok.
send_health_check_pass() ->
  Service = string:join(["service", service_id()], ":"),
  case autocluster_httpc:get(autocluster_config:get(consul_scheme),
                             autocluster_config:get(consul_host),
                             autocluster_config:get(consul_port),
                             [v1, agent, check, pass, Service],
                             maybe_add_acl([])) of
    {ok, []} -> ok;
    {error, "500"} ->
          maybe_re_register(wait_nodelist());
    {error, Reason} ->
          autocluster_log:error("Error updating Consul health check: ~p",
                                [Reason]),
      ok
  end.

maybe_re_register({error, Reason}) ->
    autocluster_log:error("Internal error in Consul while updating health check. "
                          "Cannot obtain list of nodes registered in Consul either: ~p",
                          [Reason]);
maybe_re_register({ok, Members}) ->
    case lists:member(node(), Members) of
        true ->
            autocluster_log:error("Internal error in Consul while updating health check",
                                  []);
        false ->
            autocluster_log:error("Internal error in Consul while updating health check, "
                                  "node is not registered. Re-registering", []),
            register()
    end.

wait_nodelist() ->
    wait_nodelist(60).

wait_nodelist(N) ->
    case {nodelist(), N} of
        {Reply, 0} ->
            Reply;
        {{ok, _} = Reply, _} ->
            Reply;
        {{error, _}, _} ->
            timer:sleep(1000),
            wait_nodelist(N - 1)
    end.

%%--------------------------------------------------------------------
%% @doc
%% Unregister the rabbitmq service for this node from Consul.
%% @end
%%--------------------------------------------------------------------
-spec unregister() -> ok | {error, Reason :: string()}.
unregister() ->
  Service = service_id(),
  case autocluster_httpc:get(autocluster_config:get(consul_scheme),
                             autocluster_config:get(consul_host),
                             autocluster_config:get(consul_port),
                             [v1, agent, service, deregister, Service],
                             maybe_add_acl([])) of
    {ok, _} -> ok;
    Error   -> Error
  end.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% If configured, add the ACL token to the query arguments.
%% @end
%%--------------------------------------------------------------------
-spec maybe_add_acl(QArgs :: list()) -> list().
maybe_add_acl(QArgs) ->
  case autocluster_config:get(consul_acl_token) of
    "undefined" -> QArgs;
    ACL         -> lists:append(QArgs, [{token, ACL}])
  end.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% If nodes with health checks with 'warning' status are accepted, perform
%% the filtering, only selecting those with 'warning' or 'passing' status
%% @end
%%--------------------------------------------------------------------
-spec filter_nodes(ConsulResult :: list(), AllowWarning :: atom()) -> list().
filter_nodes(Nodes, Warn) ->
  case Warn of
    true ->
      lists:filter(fun(Node) ->
                    Checks = maps:get(<<"Checks">>, Node),
                    lists:all(fun(Check) ->
                      lists:member(maps:get(<<"Status">>, Check),
                                   [<<"passing">>, <<"warning">>])
                              end,
                              Checks)
                   end,
                   Nodes);
    false -> Nodes
  end.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Take the list fo data as returned from the call to Consul and
%% return it as a properly formatted list of rabbitmq cluster
%% identifier atoms.
%% @end
%%--------------------------------------------------------------------
-spec extract_nodes(ConsulResult :: list()) -> list().
extract_nodes(Data) -> extract_nodes(Data, []).


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Take the list fo data as returned from the call to Consul and
%% return it as a properly formatted list of rabbitmq cluster
%% identifier atoms.
%% @end
%%--------------------------------------------------------------------
-spec extract_nodes(ConsulResult :: list(), Nodes :: list())
    -> list().
extract_nodes([], Nodes)    -> Nodes;
extract_nodes([H|T], Nodes) ->
  Service = maps:get(<<"Service">>, H),
  Value = maps:get(<<"Address">>, Service),
  NodeName = case autocluster_util:as_string(Value) of
    "" ->
      NodeData = maps:get(<<"Node">>, H),
      Node = maps:get(<<"Node">>, NodeData),
      maybe_add_domain(autocluster_util:node_name(Node));
    Address ->
      autocluster_util:node_name(Address)
  end,
  extract_nodes(T, lists:merge(Nodes, [NodeName])).


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Build the query argument list required to fetch the node list from
%% Consul.
%% @end
%%--------------------------------------------------------------------
-spec node_list_qargs() -> list().
node_list_qargs() ->
  maybe_add_acl(node_list_qargs(autocluster_config:get(cluster_name))).


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Build the query argument list required to fetch the node list from
%% Consul, evaluating the configured cluster name and returning the
%% tag filter if it's set.
%% @end
%%--------------------------------------------------------------------
-spec node_list_qargs(ClusterName :: string()) -> list().
node_list_qargs(Cluster) ->
  ClusterTag = case Cluster of
    "undefined" -> [];
    _           -> [{tag, Cluster}]
  end,
  node_list_qargs(ClusterTag, autocluster_config:get(consul_include_nodes_with_warnings)).


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Build the query argument list required to fetch the node list from
%% Consul. Unless nodes with health checks having 'warning' status are
%% permitted, select only those with 'passing' status. Otherwise return
%% all for further filtering
%% @end
%%--------------------------------------------------------------------
-spec node_list_qargs(Args :: list(), AllowWarn :: atom()) -> list().
node_list_qargs(Value, Warn) ->
    case Warn of
        true  -> Value;
        false -> [passing | Value]
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Build the registration body.
%% @end
%%--------------------------------------------------------------------
-spec registration_body() -> {ok, Body :: binary()} | {error, atom()}.
registration_body() ->
  Payload = autocluster_consul:build_registration_body(),
  registration_body(rabbit_json:try_encode(Payload)).


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Process the result of JSON encoding the request body payload,
%% returning the body as a binary() value or the error returned by
%% the JSON serialization library.
%% @end
%%------------------------------------------------------------------
-spec registration_body(Response :: {ok, Body :: string()} |
                                    {error, Reason :: atom()})
  -> {ok, Body :: binary()} | {error, Reason :: atom()}.
registration_body({ok, Body}) ->
  {ok, rabbit_data_coercion:to_binary(Body)};
registration_body({error, Reason}) ->
  autocluster_log:error("Error serializing the request body: ~p",
    [Reason]),
  {error, Reason}.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Build the registration body.
%% @end
%%--------------------------------------------------------------------
-spec build_registration_body() -> list().
build_registration_body() ->
  Payload1 = registration_body_add_id(),
  Payload2 = registration_body_add_name(Payload1),
  Payload3 = registration_body_maybe_add_address(Payload2),
  Payload4 = registration_body_add_port(Payload3),
  Payload5 = registration_body_maybe_add_check(Payload4),
  registration_body_maybe_add_tag(Payload5).


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Add the service ID to the registration request payload.
%% @end
%%--------------------------------------------------------------------
-spec registration_body_add_id() -> list().
registration_body_add_id() ->
  [{'ID', list_to_atom(service_id())}].


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Add the service name to the registration request payload.
%% @end
%%--------------------------------------------------------------------
-spec registration_body_add_name(Payload :: list()) -> list().
registration_body_add_name(Payload) ->
  Name = list_to_atom(autocluster_config:get(consul_svc)),
  lists:append(Payload, [{'Name', Name}]).


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Check the configuration indicating that the service address should
%% be set, adding the service address to the registration payload if
%% it is set.
%% @end
%%--------------------------------------------------------------------
-spec registration_body_maybe_add_address(Payload :: list())
    -> list().
registration_body_maybe_add_address(Payload) ->
  registration_body_maybe_add_address(Payload, service_address()).


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Evaluate the return from service_address/0 to see if the service
%% address is set, adding it to the registration payload if so.
%% @end
%%--------------------------------------------------------------------
-spec registration_body_maybe_add_address(Payload :: list(), string())
    -> list().
registration_body_maybe_add_address(Payload, "undefined") -> Payload;
registration_body_maybe_add_address(Payload, Address) ->
  lists:append(Payload, [{'Address', list_to_atom(Address)}]).


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Check the configured value for the TTL indicating how often
%% RabbitMQ should let Consul know that it's alive, adding the Consul
%% Check definition if it is set.
%% @end
%%--------------------------------------------------------------------
-spec registration_body_maybe_add_check(Payload :: list()) -> list().
registration_body_maybe_add_check(Payload) ->
  TTL = autocluster_config:get(consul_svc_ttl),
  registration_body_maybe_add_check(Payload, TTL).


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Evaluate the configured value for the TTL indicating how often
%% RabbitMQ should let Consul know that it's alive, adding the Consul
%% Check definition if it is set.
%% @end
%%--------------------------------------------------------------------
-spec registration_body_maybe_add_check(Payload :: list(),
                                        TTL :: integer() | undefined)
    -> list().
registration_body_maybe_add_check(Payload, undefined) ->
    case registration_body_maybe_add_deregister([]) of
        [{'Deregister_critical_service_after', _}]->
            autocluster_log:warning("Can't use Consul Deregister After without " ++
            "using TTL. The parameter CONSUL_DEREGISTER_AFTER will be ignored"),
            Payload;

        _ -> Payload
    end;
registration_body_maybe_add_check(Payload, TTL) ->
    CheckItems = [{'Notes', list_to_atom(?CONSUL_CHECK_NOTES)},
        {'TTL', list_to_atom(service_ttl(TTL))}],
    Check = [{'Check', registration_body_maybe_add_deregister(CheckItems)}],
    lists:append(Payload, Check).



%%--------------------------------------------------------------------
%% @private
%% @doc
%% Add the service port to the registration request payload.
%% @end
%%--------------------------------------------------------------------
-spec registration_body_add_port(Payload :: list()) -> list().
registration_body_add_port(Payload) ->
  lists:append(Payload,
               [{'Port', autocluster_config:get(consul_svc_port)}]).


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Evaluate the configured value for the deregister_critical_service_after.
%% Consul removes the node after the timeout (If it is set)
%% Check definition if it is set.
%%
%% @end
%%--------------------------------------------------------------------

registration_body_maybe_add_deregister(Payload) ->
    Deregister = autocluster_config:get(consul_deregister_after),
    registration_body_maybe_add_deregister(Payload, Deregister).


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Evaluate the configured value for the deregister_critical_service_after.
%% Consul removes the node after the timeout (If it is set)
%% Check definition if it is set.
%% @end
%%--------------------------------------------------------------------

-spec registration_body_maybe_add_deregister(Payload :: list(),
    TTL :: integer() | undefined)
        -> list().
registration_body_maybe_add_deregister(Payload, undefined) -> Payload;
registration_body_maybe_add_deregister(Payload, Deregister_After) ->
    Deregister = {'Deregister_critical_service_after',
        list_to_atom(service_ttl(Deregister_After))},
    Payload ++ [Deregister].
%%--------------------------------------------------------------------
%% @private
%% @doc
%% Check the configured value for the Cluster name, adding it as a
%% tag if set.
%% @end
%%--------------------------------------------------------------------
-spec registration_body_maybe_add_tag(Payload :: list()) -> list().
registration_body_maybe_add_tag(Payload) ->
  Value = autocluster_config:get(cluster_name),
  registration_body_maybe_add_tag(Payload, Value).


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Check the configured value for the Cluster name, adding it as a
%% tag if set.
%% @end
%%--------------------------------------------------------------------
-spec registration_body_maybe_add_tag(Payload :: list(),
                                      ClusterName :: string())
    -> list().
registration_body_maybe_add_tag(Payload, "undefined") -> Payload;
registration_body_maybe_add_tag(Payload, Cluster) ->
  lists:append(Payload, [{'Tags', [list_to_atom(Cluster)]}]).



%%--------------------------------------------------------------------
%% @private
%% @doc
%% Validate CONSUL_SVC_ADDR_NODENAME parameter
%% it can be used if CONSUL_SVC_ADDR_AUTO is true
%% @end
%%--------------------------------------------------------------------

-spec validate_addr_parameters(false | true, false | true) -> false | true.
validate_addr_parameters(false, true) ->
    autocluster_log:warning("The params CONSUL_SVC_ADDR_NODENAME" ++
				" can be used only if CONSUL_SVC_ADDR_AUTO is true." ++
				" CONSUL_SVC_ADDR_NODENAME value will be ignored."),
    false;
validate_addr_parameters(_, _) ->
    true.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Check the multiple ways service address can be configured and
%% return the proper value, if directly set or discovered.
%% @end
%%--------------------------------------------------------------------
-spec service_address() -> string().
service_address() ->
  validate_addr_parameters(autocluster_config:get(consul_svc_addr_auto),
      autocluster_config:get(consul_svc_addr_nodename)),
  service_address(autocluster_config:get(consul_svc_addr),
                  autocluster_config:get(consul_svc_addr_auto),
                  autocluster_config:get(consul_svc_addr_nic),
                  autocluster_config:get(consul_svc_addr_nodename)).


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Evaluate the configuration values for the service address and
%% return the proper value if any of them are configured. If addr_auto
%% is configured, return the hostname. If not, but the address was
%% statically configured, return that. If it was not statically
%% configured, see if the NIC/IP address discovery is configured.
%% @end
%%--------------------------------------------------------------------
-spec service_address(Static :: string(),
                      Auto :: boolean(),
                      AutoNIC :: string(),
                      FromNodename :: boolean()) -> string().
service_address(_, true, "undefined", FromNodename) ->
  autocluster_util:node_hostname(FromNodename);
service_address(Value, false, "undefined", _) ->
  Value;
service_address(_, false, NIC, _) ->
  {ok, Addr} = autocluster_util:nic_ipv4(NIC),
  Addr.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Create the service ID, conditionally checking to see if the service
%% address is set and appending that to the service name if so.
%% @end
%%--------------------------------------------------------------------
-spec service_id() -> string().
service_id() ->
  service_id(autocluster_config:get(consul_svc),
             service_address()).


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Evaluate the value of the service address and either return the
%% name by itself, or the service name and address together.
%% @end
%%--------------------------------------------------------------------
-spec service_id(Name :: string(), Address :: string()) -> string().
service_id(Service, "undefined") -> Service;
service_id(Service, Address) ->
  string:join([Service, Address], ":").


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Return the service ttl int value as a string, appending the unit
%% @end
%%--------------------------------------------------------------------
-spec service_ttl(TTL :: integer()) -> string().
service_ttl(Value) ->
  autocluster_util:as_string(Value) ++ "s".


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Append Consul domain if long names are in use
%% @end
%%--------------------------------------------------------------------
-spec maybe_add_domain(Domain :: atom()) -> atom().
maybe_add_domain(Value) ->
  case autocluster_config:get(consul_use_longname) of
      true ->
          list_to_atom(string:join([atom_to_list(Value),
                                    "node",
                                    autocluster_config:get(consul_domain)],
                                   "."));
      false -> Value
  end.
