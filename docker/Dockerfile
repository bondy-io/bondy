# run: docker run -it --rm bondy
FROM erlang:19-slim

MAINTAINER Javier Bucar <javier.bucar@leapsight.com>

WORKDIR /opt/app

# Env
ENV NODE_NAME=bondy@127.0.0.1 \
	HTTP_PORT=18080 \
	ADMIN_HTTP_PORT=18081 \
	TCP_PORT=18082

# Ports
EXPOSE 18080 18081 18082

# Copy source code
COPY app.tar.gz /opt/app/

RUN tar xf app.tar.gz && \
  rm app.tar.gz

CMD /opt/app/bin/bondy foreground
