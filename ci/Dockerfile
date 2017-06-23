# run: docker run -it --rm bondy
FROM erlang:19-slim

MAINTAINER Javier Bucar <javier.bucar@leapsight.com>

# Env
ENV NODE_NAME=bondy@127.0.0.1 \
	HTTP_PORT=18080 \
	ADMIN_HTTP_PORT=18081 \
	TCP_PORT=18082

# Ports
EXPOSE 18080 18081 18082

# Copy source code
COPY app.tar.gz /tmp

RUN groupadd -r app -g 1000 && \
	useradd -u 1000 -r -g app -m -d /opt/app -s /bin/bash -c "App user" app && \
	su - app -c "tar xf /tmp/app.tar.gz -C /opt/app" && \
	rm /tmp/app.tar.gz

USER app
VOLUME /opt/app/data
WORKDIR /opt/app
CMD /opt/app/bin/bondy foreground
