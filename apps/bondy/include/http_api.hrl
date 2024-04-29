%% =============================================================================
%%  http_api.hrl -
%%
%%  Copyright (c) 2016-2024 Leapsight. All rights reserved.
%%
%%  Licensed under the Apache License, Version 2.0 (the "License");
%%  you may not use this file except in compliance with the License.
%%  You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%%  Unless required by applicable law or agreed to in writing, software
%%  distributed under the License is distributed on an "AS IS" BASIS,
%%  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%  See the License for the specific language governing permissions and
%%  limitations under the License.
%% =============================================================================



-define(DELETE, <<"DELETE">>).
-define(GET, <<"GET">>).
-define(HEAD, <<"HEAD">>).
-define(OPTIONS, <<"OPTIONS">>).
-define(POST, <<"POST">>).
-define(PUT, <<"PUT">>).


%% =============================================================================
%% SUCCESS
%% =============================================================================

-define(HTTP_OK, 200).
-define(HTTP_CREATED, 201).
-define(HTTP_ACCEPTED, 202).
-define(HTTP_NO_CONTENT, 204).
-define(HTTP_RESET_CONTENT, 205).

%% =============================================================================
%% REDIRECTION
%% =============================================================================

-define(HTTP_TEMP_REDIRECT, 307).
-define(HTTP_PERMANENT_REDIRECT, 308).

%% =============================================================================
%% CLIENT ERROR
%% =============================================================================


%% This response means that server could not understand the request due to
%% invalid syntax.
-define(HTTP_BAD_REQUEST, 400).

%% Although the HTTP standard specifies "unauthorized", semantically this response means "unauthenticated". That is, the client must authenticate itself to get the requested response.
-define(HTTP_UNAUTHORIZED, 401).

%% This response code is reserved for future use. Initial aim for creating this code was using it for digital payment systems however this is not used currently.
-define(HTTP_PAYMENT_REQUIRED, 402).

%% The client does not have access rights to the content, i.e. they are unauthorized, so server is rejecting to give proper response. Unlike 401, the client's identity is known to the server.
-define(HTTP_FORBIDDEN, 403).

%% The server can not find requested resource. In the browser, this means the URL is not recognized. In an API, this can also mean that the endpoint is valid but the resource itself does not exist. Servers may also send this response instead of 403 to hide the existence of a resource from an unauthorized client. This response code is probably the most famous one due to its frequent occurrence on the web.
-define(HTTP_NOT_FOUND, 404).

%% The request method is known by the server but has been disabled and cannot be used. For example, an API may forbid DELETE-ing a resource. The two mandatory methods, GET and HEAD, must never be disabled and should not return this error code.
-define(HTTP_METHOD_NOT_ALLOWED, 405).

%% This response is sent when the web server, after performing server-driven content negotiation, doesn't find any content following the criteria given by the user agent.
-define(HTTP_NOT_ACCEPTABLE, 406).

%% This is similar to 401 but authentication is needed to be done by a proxy.
-define(HTTP_PROXY_AUTHENTICATION_REQUIRED, 407).

%% This response is sent on an idle connection by some servers, even without any previous request by the client. It means that the server would like to shut down this unused connection. This response is used much more since some browsers, like Chrome, Firefox 27+, or IE9, use HTTP pre-connection mechanisms to speed up surfing. Also note that some servers merely shut down the connection without sending this message.
-define(HTTP_REQUEST_TIMEOUT, 408).

%% This response is sent when a request conflicts with the current state of the server.
-define(HTTP_CONFLICT, 409).

%% This response would be sent when the requested content has been permanently deleted from server, with no forwarding address. Clients are expected to remove their caches and links to the resource. The HTTP specification intends this status code to be used for "limited-time, promotional services". APIs should not feel compelled to indicate resources that have been deleted with this status code.
-define(HTTP_GONE, 410).

%% Server rejected the request because the Content-Length header field is not defined and the server requires it.
-define(HTTP_LENGTH_REQUIRED, 411).

%% The client hs indicated preconditions in its headers which the server does not meet.
-define(HTTP_PRECONDITION_FAILED, 412).

%% Request entity is larger than limits defined by server; the server might close the connection or return an Retry-After header field.
-define(HTTP_PAYLOAD_TOO_LARGE, 413).

%% The URI requested by the client is longer than the server is willing to interpret.
-define(HTTP_URI_TOO_LONG, 414).

%% The media format of the requested data is not supported by the server, so the server is rejecting the request.
-define(HTTP_UNSUPPORTED_MEDIA_TYPE, 415).

%% The range specified by the Range header field in the request can't be fulfilled; it's possible that the range is outside the size of the target URI's data.
-define(HTTP_REQUESTED_RANGE_NOT_SATISFIABLE, 416).

%% This response code means the expectation indicated by the Expect request header field can't be met by the server.
-define(HTTP_EXPECTATION_FAILED, 417).

%% The request was directed at a server that is not able to produce a response. This can be sent by a server that is not configured to produce responses for the combination of scheme and authority that are included in the request URI.
-define(HTTP_MISDIRECTED_REQUEST, 421).

%% (WEBDAV) The request was well-formed but was unable to be followed due to semantic errors.
-define(HTTP_UNPROCESSABLE_ENTITY , 422).

%% (WebDAV)The resource that is being accessed is locked.
-define(HTTP_LOCKED, 423).

%% (WebDAV) The request failed due to failure of a previous request.
-define(HTTP_FAILED_DEPENDENCY, 424).

%% Indicates that the server is unwilling to risk processing a request that might be replayed.
-define(HTTP_TOO_EARLY, 425).

%% The server refuses to perform the request using the current protocol but might be willing to do so after the client upgrades to a different protocol. The server sends an Upgrade header in a 426 response to indicate the required protocol(s).
-define(HTTP_UPGRADE_REQUIRED, 426).

%% The origin server requires the request to be conditional. Intended to prevent the 'lost update' problem, where a client GETs a resource's state, modifies it, and PUTs it back to the server, when meanwhile a third party has modified the state on the server, leading to a conflict.
-define(HTTP_PRECONDITION_REQUIRED, 428).

%% The user has sent too many requests in a given amount of time ("rate limiting").
-define(HTTP_TOO_MANY_REQUESTS, 429).

%% The server is unwilling to process the request because its header fields are too large. The request MAY be resubmitted after reducing the size of the request header fields.
-define(HTTP_REQUEST_HEADER_FIELDS_TOO_LARGE, 431).

%% The user requests an illegal resource, such as a web page censored by a government.
-define(HTTP_UNAVAILABLE_FOR_LEGAL_REASONS, 451).





%% =============================================================================
%% SERVER ERRORS
%% =============================================================================




%% The server has encountered a situation it doesn't know how to handle.
-define(HTTP_INTERNAL_SERVER_ERROR, 500).

%% The request method is not supported by the server and cannot be handled. The only methods that servers are required to support (and therefore that must not return this code) are GET and HEAD.
-define(HTTP_NOT_IMPLEMENTED, 501).

%% This error response means that the server, while working as a gateway to get a response needed to handle the request, got an invalid response.
-define(HTTP_BAD_GATEWAY, 502).

%% The server is not ready to handle the request. Common causes are a server that is down for maintenance or that is overloaded. Note that together with this response, a user-friendly page explaining the problem should be sent. This responses should be used for temporary conditions and the Retry-After: HTTP header should, if possible, contain the estimated time before the recovery of the service. The webmaster must also take care about the caching-related headers that are sent along with this response, as these temporary condition responses should usually not be cached.
-define(HTTP_SERVICE_UNAVAILABLE, 503).

%% This error response is given when the server is acting as a gateway and cannot get a response in time.
-define(HTTP_GATEWAY_TIMEOUT, 504).

%% The HTTP version used in the request is not supported by the server.
-define(HTTP_VERSION_NOT_SUPPORTED, 505).

%% The server has an internal configuration error: transparent content negotiation for the request results in a circular reference.
-define(HTTP_VARIANT_ALSO_NEGOTIATES, 506).

%% The server has an internal configuration error: the chosen variant resource is configured to engage in transparent content negotiation itself, and is therefore not a proper end point in the negotiation process.
-define(HTTP_INSUFFICIENT_STORAGE, 507).

%% (WebDAV)The server detected an infinite loop while processing the request.
-define(HTTP_LOOP_DETECTED , 508).

%% Further extensions to the request are required for the server to fulfill it.
-define(HTTP_NOT_EXTENDED, 510).

%% The 511 status code indicates that the client needs to authenticate to gain network access.
-define(HTTP_NETWORK_AUTHENTICATION_REQUIRED, 511).



-define(CORS_HEADERS, #{
    <<"access-control-allow-origin">> => <<"*">>,
    <<"access-control-allow-credentials">> => <<"true">>,
    <<"access-control-allow-methods">> => <<"HEAD,OPTIONS,POST">>,
    <<"access-control-allow-headers">> => <<"origin,x-requested-with,content-type,accept,authorization,accept-language">>,
    <<"access-control-max-age">> => <<"86400">>
}).