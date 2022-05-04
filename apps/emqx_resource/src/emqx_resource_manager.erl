%%--------------------------------------------------------------------
%% Copyright (c) 2022 EMQ Technologies Co., Ltd. All Rights Reserved.
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
-module(emqx_resource_manager).
-behaviour(gen_statem).

-include("emqx_resource.hrl").
-include("emqx_resource_utils.hrl").

% API
-export([
    ensure_resource/5,
    create_dry_run/2,
    ets_lookup/1,
    get_metrics/1,
    health_check/1,
    list_all/0,
    list_group/1,
    lookup/1,
    recreate/4,
    remove/1,
    reset_metrics/1,
    restart/2,
    set_resource_status_connecting/1,
    stop/1
]).

% Server
-export([start_link/5]).

% Behaviour
-export([init/1, callback_mode/0, handle_event/4, terminate/3]).

% State record
-record(data, {id, group, mod, config, opts, status, state, error}).

-define(SHORT_HEALTHCHECK_INTERVAL, 1000).
-define(HEALTHCHECK_INTERVAL, 15000).
-define(ETS_TABLE, emqx_resource_manager).
-define(TIME_DIVISOR, 100).
-define(WAIT_FOR_RESOURCE_DELAY, 100).

%%------------------------------------------------------------------------------
%% API
%%------------------------------------------------------------------------------

%% @doc Called from emqx_resource when starting a resource instance.
%%
%% Triggers the emqx_resource_manager_sup supervisor to actually create
%% and link the process itself if not already started.
-spec ensure_resource(
    instance_id(),
    resource_group(),
    resource_type(),
    resource_config(),
    create_opts()
) -> {ok, resource_data()}.
ensure_resource(InstId, Group, ResourceType, Config, Opts) ->
    case lookup(InstId) of
        {ok, _Group, Data} ->
            {ok, Data};
        {error, not_found} ->
            do_start(InstId, Group, ResourceType, Config, Opts),
            {ok, _Group, Data} = lookup(InstId),
            {ok, Data}
    end.

%% @doc Called from `emqx_resource` when doing a dry run for creating a resource instance.
%%
%% Triggers the `emqx_resource_manager_sup` supervisor to actually create
%% and link the process itself if not already started, and then immedately stops.
-spec create_dry_run(resource_type(), resource_config()) ->
    ok | {error, Reason :: term()}.
create_dry_run(ResourceType, Config) ->
    InstId = make_test_id(),
    _ = emqx_resource_manager_sup:start_child(InstId, <<"dry_run">>, ResourceType, Config, #{}),
    case wait_for_resource_ready(InstId, 5000) of
        ok ->
            stop(InstId);
        timeout ->
            {error, timeout}
    end.

%% @doc Called from emqx_resource when recreating a resource which may or may not exist
-spec recreate(instance_id(), resource_type(), resource_config(), create_opts()) ->
    {ok, resource_data()} | {error, not_found} | {error, updating_to_incorrect_resource_type}.
recreate(InstId, ResourceType, NewConfig, Opts) ->
    case lookup(InstId) of
        {ok, Group, #{mod := ResourceType, status := _} = _Data} ->
            _ = remove(InstId, false),
            ensure_resource(InstId, Group, ResourceType, NewConfig, Opts);
        {ok, _, #{mod := Mod}} when Mod =/= ResourceType ->
            {error, updating_to_incorrect_resource_type};
        {error, not_found} ->
            {error, not_found}
    end.

%% @doc Stops a running resource_manager and clears the metrics for the resource
-spec remove(instance_id()) -> ok | {error, Reason :: term()}.
remove(InstId) when is_binary(InstId) ->
    remove(InstId, true).

%% @doc Stops a running resource_manager and optionally clears the metrics for the resource
-spec remove(instance_id(), boolean()) -> ok | {error, Reason :: term()}.
remove(InstId, ClearMetrics) when is_binary(InstId) ->
    safe_call(InstId, {remove, ClearMetrics}).

%% @doc Stops and then starts an instance that was already running
-spec restart(instance_id(), create_opts()) -> ok | {error, Reason :: term()}.
restart(InstId, Opts) when is_binary(InstId) ->
    case lookup(InstId) of
        {ok, Group, #{mod := ResourceType, config := Config} = _Data} ->
            _ = remove(InstId),
            do_start(InstId, Group, ResourceType, Config, Opts);
        Error ->
            Error
    end.

%% @doc Stop the resource manager process
-spec stop(instance_id()) -> ok | {error, Reason :: term()}.
stop(InstId) ->
    case safe_call(InstId, stop) of
        ok ->
            ok;
        {error, not_found} ->
            ok;
        {error, _Reason} = Error ->
            Error
    end.

%% @doc Test helper
-spec set_resource_status_connecting(instance_id()) -> ok.
set_resource_status_connecting(InstId) ->
    safe_call(InstId, set_resource_status_connecting).

%% @doc Lookup the group and data of a resource
-spec lookup(instance_id()) -> {ok, resource_group(), resource_data()} | {error, not_found}.
lookup(InstId) ->
    safe_call(InstId, lookup).

%% @doc Lookup the group and data of a resource
-spec ets_lookup(instance_id()) -> {ok, resource_group(), resource_data()} | {error, not_found}.
ets_lookup(InstId) ->
    case ets:lookup(?ETS_TABLE, InstId) of
        [{_Id, Group, Data}] ->
            {ok, Group, data_record_to_external_map_with_metrics(Data)};
        [] ->
            {error, not_found}
    end.

%% @doc Get the metrics for the specified resource
get_metrics(InstId) ->
    emqx_metrics_worker:get_metrics(resource_metrics, InstId).

%% @doc Reset the metrics for the specified resource
-spec reset_metrics(instance_id()) -> ok.
reset_metrics(InstId) ->
    emqx_metrics_worker:reset_metrics(resource_metrics, InstId).

%% @doc Returns the data for all resorces
-spec list_all() -> [resource_data()] | [].
list_all() ->
    try
        [
            data_record_to_external_map_with_metrics(Data)
         || {_Id, _Group, Data} <- ets:tab2list(?ETS_TABLE)
        ]
    catch
        error:badarg -> []
    end.

%% @doc Returns a list of ids for all the resources in a group
-spec list_group(resource_group()) -> [instance_id()].
list_group(Group) ->
    List = ets:match(?ETS_TABLE, {'$1', Group, '_'}),
    lists:flatten(List).

-spec health_check(instance_id()) -> ok | {error, Reason :: term()}.
health_check(InstId) ->
    safe_call(InstId, health_check).

%% Server start/stop callbacks

%% @doc Function called from the supervisor to actually start the server
start_link(InstId, Group, ResourceType, Config, Opts) ->
    Data = #data{
        id = InstId,
        group = Group,
        mod = ResourceType,
        config = Config,
        opts = Opts,
        status = undefined,
        state = undefined,
        error = undefined
    },
    gen_statem:start_link({local, proc_name(InstId)}, ?MODULE, Data, []).

init(Data) ->
    {ok, connecting, Data}.

terminate(_Reason, _State, Data) ->
    ets:delete(?ETS_TABLE, Data#data.id),
    ok.

%% Behavior callback

callback_mode() -> [handle_event_function, state_enter].

%% Common event Function

% Called during testing to force a specific state
handle_event({call, From}, set_resource_status_connecting, _State, Data) ->
    {next_state, connecting, Data#data{status = connecting}, [{reply, From, ok}]};
% Called when the resource is to be stopped
handle_event({call, From}, stop, _State, #data{status = disconnected} = Data) ->
    {next_state, stopped, Data, [{reply, From, ok}]};
handle_event({call, From}, stop, _State, Data) ->
    Result = do_stop(Data),
    UpdatedData = Data#data{status = disconnected},
    {next_state, stopped, UpdatedData, [{reply, From, Result}]};
% Nothing happens once the stopped state is entered. It is a 'holding' state waiting for external actions.
handle_event(enter, _OldState, stopped, Data) ->
    {next_state, stopped, Data};
% Called when a resource is to be stopped and removed.
handle_event({call, From}, {remove, ClearMetrics}, _State, Data) ->
    handle_remove_event(From, ClearMetrics, Data);
% Called when the state of the resource is being looked up.
handle_event({call, From}, lookup, _State, #data{group = Group} = Data) ->
    Reply = {ok, Group, data_record_to_external_map_with_metrics(Data)},
    {keep_state_and_data, [{reply, From, Reply}]};
% An external health check call. Disconnected usually means an error has happened.
handle_event({call, From}, health_check, disconnected, Data) ->
    Actions = [{reply, From, {error, Data#data.error}}],
    {keep_state_and_data, Actions};
% Resource has been explicitly stopped, so return that as the error reason.
handle_event({call, From}, health_check, stopped, _Data) ->
    Actions = [{reply, From, {error, stopped}}],
    {keep_state_and_data, Actions};
handle_event({call, From}, health_check, _State, Data) ->
    handle_health_check_event(From, Data);
% Connecting state enter
handle_event(enter, connecting, connecting, Data) ->
    handle_connecting_state_enter_event(Data);
handle_event(enter, _OldState, connecting, Data) ->
    Actions = [{state_timeout, 0, health_check}],
    {next_state, connecting, Data, Actions};
% Connecting state health_check timeouts.
% First clause supports desired behavior on initial connection.
handle_event(state_timeout, health_check, connecting, #data{status = disconnected} = Data) ->
    {next_state, disconnected, Data};
handle_event(state_timeout, health_check, connecting, Data) ->
    connecting_health_check(Data);
%% The connected state is entered after a successful start of the callback mod
%% and successful health_checks
handle_event(enter, _OldState, connected, Data) ->
    Actions = [{state_timeout, ?HEALTHCHECK_INTERVAL, health_check}],
    {next_state, connected, Data, Actions};
handle_event(state_timeout, health_check, connected, Data) ->
    perform_connected_health_check(Data);
% Disconnected state entered when a healtcheck has failed.
handle_event(enter, _OldState, disconnected, #data{id = InstId} = Data) ->
    UpdatedData = Data#data{status = disconnected},
    ets:delete(?ETS_TABLE, InstId),
    {next_state, disconnected, UpdatedData}.

%%------------------------------------------------------------------------------
%% internal functions
%%------------------------------------------------------------------------------

handle_connecting_state_enter_event(Data) ->
    Result = emqx_resource:call_start(Data#data.id, Data#data.mod, Data#data.config),
    case Result of
        {ok, ResourceState} ->
            UpdatedData = Data#data{state = ResourceState, status = connecting},
            %% Perform an initial health_check immediately before transitioning into a connected state
            Actions = [{state_timeout, 0, health_check}],
            {next_state, connecting, UpdatedData, Actions};
        {error, Reason} ->
            %% Keep track of the error reason why the connection did not work
            %% so that the Reason can be returned when the verification call is made.
            UpdatedData = Data#data{status = disconnected, error = Reason},
            Actions = [{state_timeout, 0, health_check}],
            {next_state, connecting, UpdatedData, Actions}
    end.

handle_remove_event(From, ClearMetrics, Data) ->
    do_stop(Data),
    ets:delete(?ETS_TABLE, Data#data.id),
    case ClearMetrics of
        true -> ok = emqx_metrics_worker:clear_metrics(resource_metrics, Data#data.id);
        false -> ok
    end,
    {stop_and_reply, normal, [{reply, From, ok}]}.

do_start(InstId, Group, ResourceType, Config, Opts) ->
    % The state machine will make the actual call to the callback/resource module after init
    _ = emqx_resource_manager_sup:start_child(InstId, Group, ResourceType, Config, Opts),
    ok = emqx_metrics_worker:create_metrics(
        resource_metrics,
        InstId,
        [matched, success, failed, exception],
        [matched]
    ),
    wait_for_resource_ready(InstId, maps:get(wait_for_resource_ready, Opts, 5000)),
    ok.

do_stop(Data) ->
    Result = emqx_resource:call_stop(Data#data.id, Data#data.mod, Data#data.state),
    ets:delete(?ETS_TABLE, Data#data.id),
    Result.

proc_name(Id) ->
    Module = atom_to_binary(?MODULE),
    Connector = <<"_">>,
    binary_to_atom(<<Module/binary, Connector/binary, Id/binary>>).

handle_health_check_event(From, Data) ->
    case emqx_resource:call_health_check(Data#data.id, Data#data.mod, Data#data.state) of
        connected ->
            UpdatedData = Data#data{status = connected, error = undefined},
            update_resource(Data#data.id, Data#data.group, UpdatedData),
            Actions = [{reply, From, ok}],
            {next_state, connected, UpdatedData, Actions};
        {connected, NewResourceState} ->
            UpdatedData = Data#data{
                state = NewResourceState, status = connected, error = undefined
            },
            update_resource(Data#data.id, Data#data.group, UpdatedData),
            Actions = [{reply, From, ok}],
            {next_state, connected, UpdatedData, Actions};
        ConnectStatus ->
            logger:error("health check for ~p failed: ~p", [Data#data.id, ConnectStatus]),
            UpdatedData = Data#data{status = connecting, error = ConnectStatus},
            ets:delete(?ETS_TABLE, Data#data.id),
            Actions = [{reply, From, {error, ConnectStatus}}],
            {next_state, connecting, UpdatedData, Actions}
    end.

connecting_health_check(Data) ->
    case emqx_resource:call_health_check(Data#data.id, Data#data.mod, Data#data.state) of
        connected ->
            UpdatedData = Data#data{status = connected, error = undefined},
            update_resource(Data#data.id, Data#data.group, UpdatedData),
            {next_state, connected, UpdatedData};
        {connected, NewResourceState} ->
            UpdatedData = Data#data{
                state = NewResourceState, status = connected, error = undefined
            },
            update_resource(Data#data.id, Data#data.group, UpdatedData),
            {next_state, connected, UpdatedData};
        ConnectStatus ->
            logger:error("health check for ~p failed: ~p", [Data#data.id, ConnectStatus]),
            UpdatedData = Data#data{error = ConnectStatus},
            Actions = [{state_timeout, ?SHORT_HEALTHCHECK_INTERVAL, health_check}],
            {keep_state, UpdatedData, Actions}
    end.

perform_connected_health_check(Data) ->
    case emqx_resource:call_health_check(Data#data.id, Data#data.mod, Data#data.state) of
        connected ->
            Actions = [{state_timeout, ?HEALTHCHECK_INTERVAL, health_check}],
            {keep_state_and_data, Actions};
        {connected, NewResourceState} ->
            UpdatedData = Data#data{
                state = NewResourceState, status = connected, error = undefined
            },
            update_resource(Data#data.id, Data#data.group, UpdatedData),
            Actions = [{state_timeout, ?HEALTHCHECK_INTERVAL, health_check}],
            {keep_state, NewResourceState, Actions};
        ConnectStatus ->
            logger:error("health check for ~p failed: ~p", [Data#data.id, ConnectStatus]),
            UpdatedData = Data#data{error = ConnectStatus},
            ets:delete(?ETS_TABLE, Data#data.id),
            {next_state, connecting, UpdatedData}
    end.

data_record_to_external_map_with_metrics(Data) ->
    #{
        id => Data#data.id,
        mod => Data#data.mod,
        config => Data#data.config,
        status => Data#data.status,
        state => Data#data.state,
        metrics => get_metrics(Data#data.id)
    }.

make_test_id() ->
    RandId = iolist_to_binary(emqx_misc:gen_id(16)),
    <<?TEST_ID_PREFIX, RandId/binary>>.

-spec wait_for_resource_ready(instance_id(), integer()) -> ok | timeout.
wait_for_resource_ready(InstId, WaitTime) ->
    do_wait_for_resource_ready(InstId, WaitTime div ?TIME_DIVISOR).

do_wait_for_resource_ready(_InstId, 0) ->
    timeout;
do_wait_for_resource_ready(InstId, Retry) ->
    case ets_lookup(InstId) of
        {ok, _Group, #{status := connected}} ->
            ok;
        _ ->
            timer:sleep(?WAIT_FOR_RESOURCE_DELAY),
            do_wait_for_resource_ready(InstId, Retry - 1)
    end.

safe_call(InstId, Message) ->
    try
        gen_statem:call(proc_name(InstId), Message)
    catch
        exit:{noproc, _} ->
            {error, not_found}
    end.

update_resource(InstId, Group, Data) ->
    ets:insert(?ETS_TABLE, {InstId, Group, Data}).
