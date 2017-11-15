%% @doc
%% Collects Cowboy metrics using
%% <a href="https://github.com/ninenines/cowboy/blob/master/src/cowboy_metrics_h.erl">
%%   metrics stream handler
%% </a>.
%%
%% ==Exported metrics==
%% <ul>
%%   <li>
%%     `cowboy_early_errors_total'<br/>
%%     Type: counter.<br/>
%%     Labels: default - `[]', configured via `early_errors_labels'.<br/>
%%     Total number of Cowboy early errors, i.e. errors that occur before a request is received.
%%   </li>
%%   <li>
%%     `cowboy_protocol_upgrades_total'<br/>
%%     Type: counter.<br/>
%%     Labels: default - `[]', configured via `protocol_upgrades_labels'.<br/>
%%     Total number of protocol upgrades, i.e. when http connection upgraded to websocket connection.
%%   </li>
%%   <li>
%%     `cowboy_requests_total'<br/>
%%     Type: counter.<br/>
%%     Labels: default - `[method, reason, status_class]', configured via `request_labels'.<br/>
%%     Total number of Cowboy requests.
%%   </li>
%%   <li>
%%     `cowboy_spawned_processes_total'<br/>
%%     Type: counter.<br/>
%%     Labels: default - `[method, reason, status_class]', configured via `request_labels'.<br/>
%%     Total number of spawned processes.
%%   </li>
%%   <li>
%%     `cowboy_errors_total'<br/>
%%     Type: counter.<br/>
%%     Labels: default - `[method, reason, error]', configured via `error_labels'.<br/>
%%     Total number of Cowboy request errors.
%%   </li>
%%   <li>
%%     `cowboy_request_duration_seconds'<br/>
%%     Type: histogram.<br/>
%%     Labels: default - `[method, reason, status_class]', configured via `request_labels'.<br/>
%%     Buckets: default - `[0.01, 0.1, 0.25, 0.5, 0.75, 1, 1.5, 2, 4]', configured via `duration_buckets'.<br/>
%%     Cowboy request duration.
%%   </li>
%%   <li>
%%     `cowboy_receive_body_duration_seconds'<br/>
%%     Type: histogram.<br/>
%%     Labels: default - `[method, reason, status_class]', configured via `request_labels'.<br/>
%%     Buckets: default - `[0.01, 0.1, 0.25, 0.5, 0.75, 1, 1.5, 2, 4]', configured via `duration_buckets'.<br/>
%%     Request body receiving duration.
%%   </li>
%% </ul>
%%
%% ==Configuration==
%%
%% Prometheus Cowboy2 instrumenter configured via `cowboy_instrumenter' key of `prometheus'
%% app environment.
%%
%% Default configuration:
%%
%% <pre lang="erlang">
%% {prometheus, [
%%   ...
%%   {cowboy_instrumenter, [{duration_buckets, [0.01, 0.1, 0.25, 0.5, 0.75, 1, 1.5, 2, 4]},
%%                          {early_error_labels,  []},
%%                          {request_labels, [method, reason, status_class]},
%%                          {error_labels, [method, reason, error]}]
%%   ...
%% ]}
%% </pre>
%%
%% ==Labels==
%%
%% Builtin:
%%  - host,
%%  - port,
%%  - method,
%%  - status,
%%  - status_class,
%%  - reason,
%%  - error.
%%
%% ===Custom labels===
%% can be implemented via module exporting label_value/2 function.
%% First argument will be label name, second is Metrics data from
%% <a href="https://github.com/ninenines/cowboy/blob/master/src/cowboy_metrics_h.erl">
%% metrics stream handler
%% </a>.
%% Set this module to `labels_module' configuration option.
%%
%% @end

%% Replaces
%% -module(prometheus_cowboy2_instrumenter).

-module(bondy_cowboy_prometheus).


-export([setup/0]).
-export([observe/1]).
-define(DEFAULT_DURATION_BUCKETS, [0.01, 0.1, 0.25, 0.5, 0.75, 1, 1.5, 2, 4]).
-define(DEFAULT_EARLY_ERROR_LABELS, []).
-define(DEFAULT_PROTOCOL_UPGRADE_LABELS, []).
-define(DEFAULT_REQUEST_LABELS, [method, reason, status_class]).
-define(DEFAULT_ERROR_LABELS, [method, reason, error]).
-define(DEFAULT_CONFIG, [{duration_buckets, ?DEFAULT_DURATION_BUCKETS},
                         {early_error_labels,  ?DEFAULT_EARLY_ERROR_LABELS},
                         {protocol_upgrade_labels, ?DEFAULT_PROTOCOL_UPGRADE_LABELS},
                         {request_labels, ?DEFAULT_REQUEST_LABELS},
                         {error_labels, ?DEFAULT_ERROR_LABELS}]).

%% ===================================================================
%% API
%% ===================================================================

-spec observe(map()) -> ok.
%% @doc
%% <a href="https://github.com/ninenines/cowboy/blob/master/src/cowboy_metrics_h.erl">
%% Metrics stream handler
%% </a> callback.
%% @end
observe(Metrics0=#{ref:=ListenerRef}) ->
  {Host, Port} = ranch:get_addr(ListenerRef),
  dispatch_metrics(Metrics0#{listener_host=>Host,
                             listener_port=>Port}),
  ok.

%% @doc
%% Sets all metrics up. Call this when the app starts.
%% @end
setup() ->
  prometheus_counter:declare([{name, bondy_http_early_errors_total},
                              {labels, early_error_labels()},
                              {help, "Total number of HTTP early errors."}]),
%%   prometheus_counter:declare([{name, cowboy_protocol_upgrades_total},
%%                               {labels, protocol_upgrade_labels()},
%%                               {help, "Total number of protocol upgrades."}]),
  %% each observe call means new request
  prometheus_counter:declare([{name, bondy_http_requests_total},
                              {labels, request_labels()},
                              {help, "Total number of HTTP requests."}]),
  prometheus_counter:declare([{name, bondy_http_spawned_processes_total},
                              {labels, request_labels()},
                              {help, "Total number of spawned HTTP handlers  (processes)."}]),
  prometheus_counter:declare([{name, bondy_http_errors_total},
                              {labels, error_labels()},
                              {help, "Total number of HTTP request errors."}]),
  prometheus_histogram:declare([{name, bondy_http_request_duration_seconds},
                                {labels, request_labels()},
                                {buckets, duration_buckets()},
                                {help, "HTTP request duration."}]),
  prometheus_histogram:declare([{name, bondy_http_receive_body_duration_seconds},
                                {labels, request_labels()},
                                {buckets, duration_buckets()},
                                {help, "Request body receiving duration."}]),

  ok.

%% ===================================================================
%% Private functions
%% ===================================================================

dispatch_metrics(#{early_time_error := _}=Metrics) ->
  prometheus_counter:inc(bondy_http_early_errors_total, early_error_labels(Metrics));
dispatch_metrics(#{reason := switch_protocol}=_Metrics) ->
%%   prometheus_counter:inc(cowboy_protocol_upgrades_total,
%%                          protocol_upgrade_labels(Metrics));
    ok;
dispatch_metrics(#{req_start := ReqStart,
                   req_end := ReqEnd,
                   req_body_start := ReqBodyStart,
                   req_body_end := ReqBodyEnd,
                   reason := Reason,
                   procs := Procs}=Metrics) ->
  RequestLabels = request_labels(Metrics),
  prometheus_counter:inc(bondy_http_requests_total, RequestLabels),
  prometheus_counter:inc(bondy_http_spawned_processes_total, RequestLabels, maps:size(Procs)),
  prometheus_histogram:observe(bondy_http_request_duration_seconds, RequestLabels,
                               ReqEnd - ReqStart),
  case ReqBodyEnd of
    undefined -> ok;
    _ -> prometheus_histogram:observe(bondy_http_receive_body_duration_seconds, RequestLabels,
                                      ReqBodyEnd - ReqBodyStart)
  end,

  case Reason of
    normal ->
      ok;
    switch_protocol ->
      ok;
    stop ->
      ok;
    _ ->
      ErrorLabels = error_labels(Metrics),
      prometheus_counter:inc(bondy_http_errors_total, ErrorLabels)
  end.

early_error_labels(Metrics) ->
  compute_labels(early_error_labels(), Metrics).

%% protocol_upgrade_labels(Metrics) ->
%%   compute_labels(protocol_upgrade_labels(), Metrics).

request_labels(Metrics) ->
  compute_labels(request_labels(), Metrics).

error_labels(Metrics) ->
  compute_labels(error_labels(), Metrics).

compute_labels(Labels, Metrics) ->
  [label_value(Label, Metrics) || Label <- Labels].

label_value(host, #{listener_host:=Host}) ->
  Host;
label_value(port, #{listener_port:=Port}) ->
  Port;
label_value(method, #{req:=Req}) ->
  cowboy_req:method(Req);
label_value(status, #{resp_status:=Status}) ->
  Status;
label_value(status_class, #{resp_status:=Status}) ->
  prometheus_http:status_class(Status);
label_value(reason, #{reason:=Reason}) ->
  case Reason of
    _ when is_atom(Reason) -> Reason;
    {ReasonAtom, _} -> ReasonAtom;
    {ReasonAtom, _, _} -> ReasonAtom
  end;
label_value(error, #{reason:=Reason}) ->
  case Reason of
    _ when is_atom(Reason) -> undefined;
    {_, {Error, _}, _} -> Error;
    {_, Error, _} when is_atom(Error) -> Error;
    _ -> undefined
  end;
label_value(Label, Metrics) ->
  case labels_module() of
    undefined -> undefined;
    Module -> Module:label_value(Label, Metrics)
  end.

config() ->
  application:get_env(prometheus, cowboy_instrumenter, ?DEFAULT_CONFIG).

get_config_value(Key, Default) ->
  proplists:get_value(Key, config(), Default).

duration_buckets() ->
  get_config_value(duration_buckets, ?DEFAULT_DURATION_BUCKETS).

early_error_labels() ->
  get_config_value(early_error_labels, ?DEFAULT_EARLY_ERROR_LABELS).

%% protocol_upgrade_labels() ->
%%   get_config_value(protocol_upgrade_labels, ?DEFAULT_PROTOCOL_UPGRADE_LABELS).

request_labels() ->
  get_config_value(request_labels, ?DEFAULT_REQUEST_LABELS).

error_labels() ->
  get_config_value(error_labels, ?DEFAULT_ERROR_LABELS).

labels_module() ->
  get_config_value(labels_module, undefined).
