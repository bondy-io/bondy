
REBAR = rebar3
BONDY_ERL_NODENAME ?= bondy@127.0.0.1
BONDY_ERL_DISTRIBUTED_COOKIE ?= bondy

.PHONY: genvars compile test xref dialyzer

genvars:
	@cp config/prod/legacy_vars.config config/prod/vars.generated

compile-no-deps:
	${REBAR} compile

test: compile
	${REBAR} ct

xref: compile
	${REBAR} xref skip_deps=true

dialyzer: compile
	${REBAR} dialyzer

devrun:
	${REBAR} as dev release

	cp examples/config/security_config.json _build/dev/rel/bondy/etc/security_config.json

	cp examples/config/broker_bridge_config.json _build/dev/rel/bondy/etc/broker_bridge_config.json

	_build/dev/rel/bondy/bin/bondy console

prodrun:
	${REBAR} as prod release
	BONDY_ERL_NODENAME=${BONDY_ERL_NODENAME} BONDY_ERL_DISTRIBUTED_COOKIE=${BONDY_ERL_DISTRIBUTED_COOKIE} _build/prod/rel/bondy/bin/bondy console

node1:
	${REBAR} as node1 release
	_build/node1/rel/bondy/bin/bondy console

node2:
	${REBAR} as node2 release
	_build/node2/rel/bondy/bin/bondy console

node3:
	${REBAR} as node3 release
	_build/node3/rel/bondy/bin/bondy console


