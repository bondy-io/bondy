
REBAR            = rebar3

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

	priv/tools/replace-env-vars -i config/dev/bondy.conf -o _build/dev/rel/bondy/etc/bondy.conf

	_build/dev/rel/bondy/bin/bondy console

prodrun:
	${REBAR} as prod release
	_build/prod/rel/bondy/bin/bondy console

node1:
	${REBAR} as node1 release
	_build/node1/rel/bondy/bin/bondy console

node2:
	${REBAR} as node2 release
	_build/node2/rel/bondy/bin/bondy console

node3:
	${REBAR} as node3 release
	_build/node3/rel/bondy/bin/bondy console


