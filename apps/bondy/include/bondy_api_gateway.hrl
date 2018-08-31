-define(BONDY_BAD_GATEWAY_ERROR, <<"com.leapsight.bondy.error.bad_gateway">>).
-define(BONDY_API_GATEWAY_INVALID_EXPR_ERROR, <<"com.leapsight.bondy.error.api_gateway.invalid_expression">>).

-define(CORS_HEADERS, #{
    <<"access-control-allow-origin">> => <<"*">>,
    <<"access-control-allow-credentials">> => <<"true">>,
    <<"access-control-allow-methods">> => <<"HEAD,OPTIONS,POST">>,
    <<"access-control-allow-headers">> => <<"origin,x-requested-with,content-type,accept,authorization,accept-language">>,
    <<"access-control-max-age">> => <<"86400">>
}).