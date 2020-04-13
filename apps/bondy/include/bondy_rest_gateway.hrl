-define(BONDY_BAD_GATEWAY_ERROR, <<"bondy.error.bad_gateway">>).
-define(BONDY_REST_GATEWAY_INVALID_EXPR_ERROR, <<"bondy.error.api_gateway.invalid_expression">>).

-define(BONDY_ALREADY_EXISTS_ERROR, <<"bondy.error.already_exists">>).
-define(BONDY_NOT_FOUND_ERROR, <<"bondy.error.not_found">>).

-define(CORS_HEADERS, #{
    <<"access-control-allow-origin">> => <<"*">>,
    <<"access-control-allow-credentials">> => <<"true">>,
    <<"access-control-allow-methods">> => <<"HEAD,OPTIONS,POST">>,
    <<"access-control-allow-headers">> => <<"origin,x-requested-with,content-type,accept,authorization,accept-language">>,
    <<"access-control-max-age">> => <<"86400">>
}).