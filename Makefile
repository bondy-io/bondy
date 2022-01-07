
REBAR = rebar3
BONDY_ERL_NODENAME ?= bondy@127.0.0.1
BONDY_ERL_DISTRIBUTED_COOKIE ?= bondy

.PHONY: genvars compile test xref dialyzer tar

genvars:
	@cp config/prod/legacy_vars.config config/prod/vars.generated

compile:
	${REBAR} compile

docs: xref
	${REBAR} ex_doc

test: xref
	${REBAR} as test ct

xref:
	${REBAR} xref skip_deps=true

dialyzer:
	${REBAR} dialyzer

tar:
	rm -rf _build/tar
	${REBAR} as prod tar
	mkdir -p _build/tar
	tar -zxvf _build/prod/rel/*/*.tar.gz -C _build/tar

devrun:
	${REBAR} as dev release
	_build/dev/rel/bondy/bin/bondy console

prodrun:
	${REBAR} as prod release
	ERL_DIST_PORT=27788 BONDY_ERL_NODENAME=${BONDY_ERL_NODENAME} BONDY_ERL_DISTRIBUTED_COOKIE=${BONDY_ERL_DISTRIBUTED_COOKIE} _build/prod/rel/bondy/bin/bondy console

prodtarrun: tar
	ERL_DIST_PORT=27788 BONDY_ERL_NODENAME=${BONDY_ERL_NODENAME} BONDY_ERL_DISTRIBUTED_COOKIE=${BONDY_ERL_DISTRIBUTED_COOKIE} _build/tar/bin/bondy console


node1:
	${REBAR} as node1 release
	ERL_DIST_PORT=27781 _build/node1/rel/bondy/bin/bondy console

node2:
	${REBAR} as node2 release
	ERL_DIST_PORT=27782 _build/node2/rel/bondy/bin/bondy console

node3:
	${REBAR} as node3 release
	ERL_DIST_PORT=27783 _build/node3/rel/bondy/bin/bondy console


edge1:
	${REBAR} as edge1 release
	ERL_DIST_PORT=27784 _build/edge1/rel/bondy/bin/bondy console


run-node1:
	_build/node1/rel/bondy/bin/bondy console

run-node2:
	_build/node2/rel/bondy/bin/bondy console

run-node3:
	_build/node3/rel/bondy/bin/bondy console

run-edge1:
	_build/edge1/rel/bondy/bin/bondy console

# Allows to run bridge release with an example of configuration for bondy notification brigdes
# Are required as env environment variables the following:
# - AWS_REGION
# - AWS_SNS_HOST
# - AWS_ACCESS_KEY_ID
# - AWS_SECRET_ACCESS_KEY
# - MAILGUN_DOMAIN (optional - disabled by default in conf)
# - MAILGUN_APIKEY (optional - disabled by default in conf)
# - MAILGUN_SENDER (optional - disabled by default in conf)
# - SENDGRID_APIKEY
# - SENDGRID_SENDER
bridgerun:
	${REBAR} as bridge release
	_build/bridge/rel/bondy/bin/bondy console