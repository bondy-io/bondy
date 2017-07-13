# run: docker run -it --rm bondy
FROM debian:jessie-slim

MAINTAINER Javier Bucar <javier.bucar@leapsight.com>

# Env
ENV NODE_NAME=bondy@127.0.0.1

# Ports
EXPOSE 18080 18081 18082 18083 18084 18085

# Copy source code
COPY app.tar.gz /tmp

RUN groupadd -r app -g 1000 && \
	useradd -u 1000 -r -g app -m -d /opt/app -s /bin/bash -c "App user" app && \
	tar xf /tmp/app.tar.gz -C /opt/app && \
	chown -R app:app /opt/app && \
	rm /tmp/app.tar.gz

USER app
VOLUME /opt/app/data
WORKDIR /opt/app
CMD /opt/app/bin/bondy foreground
