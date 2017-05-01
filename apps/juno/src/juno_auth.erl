%% =============================================================================
%% Copyright (C) NGINEO LIMITED 2016. All rights reserved.
%% =============================================================================


-module(juno_auth).
-include("juno.hrl").

-export([authenticate/2]).


% -record(oauth2_credentials, {
%     id                  ::  binary(),
%     consumer_id         ::  binary(),
%     name                ::  binary(),
%     client_id           ::  binary(),
%     client_secret       ::  binary(),
%     redirect_uri        ::  binary(),
%     created_at          ::  binary()
% }).

% -record(oauth2_auth_codes, {
%     id                      ::  binary(),
%     api_id                  ::  binary(),
%     code                    ::  binary(),
%     authenticated_userid    ::  binary(),
%     scope                   ::  binary(),
%     created_at              ::  binary()
% }).

% -record(jwt, {
%     id                      ::  binary(),
%     created_at              ::  binary(),
%     consumer_id             ::  binary(),
%     key                     ::  binary(),
%     secret                  ::  binary(),
%     rsa_public_key          ::  binary(),
%     algorithm               ::  binary() %% HS256 RS256 ES256
% }).


%% =============================================================================
%% API
%% =============================================================================

authenticate(_, _) ->
    error(not_implemented_yet).

