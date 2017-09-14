
REBAR = $(shell pwd)/rebar3
.PHONY: deps compile rel test

DIALYZER_APPS = kernel stdlib erts sasl eunit syntax_tools compiler crypto
DEP_DIR="_build/lib"

all: compile

include tools.mk

test: common_test

common_test:
	$(REBAR) ct

compile:
	$(REBAR) compile

rel:
	$(REBAR) release

cleandata:
	rm -fr _build/dev/rel/bondy/data

stage:
	$(REBAR) release -d

dialyzer:
	$(REBAR) dialyzer

shell:
	$(REBAR) shell

gen_nodes:
	-rm -r _build/prod
	-rm -rf _build/node1
	-rm -rf _build/node2
	-rm -rf _build/node3
	$(REBAR) as prod release
	-cp -r _build/prod _build/node1
	-cp -r _build/prod _build/node2
	-cp -r _build/prod _build/node3

node1:
	RELX_REPLACE_OS_VARS=true NODE_NAME=bondy_1@127.0.0.1 HTTP_PORT=18080 ADMIN_HTTP_PORT=18081 TCP_PORT=18082 _build/node1/rel/bondy/bin/bondy console

node2:
	RELX_REPLACE_OS_VARS=true NODE_NAME=bondy_2@127.0.0.1 HTTP_PORT=18083 ADMIN_HTTP_PORT=18084 TCP_PORT=18085 _build/node2/rel/bondy/bin/bondy console

node3:
	RELX_REPLACE_OS_VARS=true NODE_NAME=bondy_3@127.0.0.1 HTTP_PORT=18086 ADMIN_HTTP_PORT=18087 TCP_PORT=18088 _build/node3/rel/bondy/bin/bondy console