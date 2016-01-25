PROJECT = ramp
PROJECT_VERSION = 0.1.0
DEPS = ranch cowboy gun msgpack jsx tuplespace cors

dep_tuplespace = git git@git.rand.dev.williamhill.plc:aramallo/tuplespace.git develop
dep_cors = git git@gitlab.williamhill-dev.local:pmorgan/cors.git develop



include erlang.mk

SHELL_OPTS = +P 5000000 \
 +K true \
 -pa ebin \
 -boot start_sasl \
 -config dev.config \
 -s rb \
 -s $(PROJECT) \
 -sname $(PROJECT)

clean-logs::
	@rm log/*

docker-push:
	docker build --pull=true --no-cache=true -t docker.rand.dev.williamhill.plc:5000/epocholith/$(PROJECT):$(PROJECT_VERSION) .
	docker push docker.rand.dev.williamhill.plc:5000/epocholith/$(PROJECT):$(PROJECT_VERSION)
