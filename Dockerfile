FROM docker-registry.prod.williamhill.plc/library/rhel7:7.1

ENV TZ=GMT

ENV app wallet
ENV user u
ENV shell /bin/bash

RUN yum -y update && \
    yum -y install gawk && \
    yum clean all && \
    groupadd -g 501 ${user} && \
    useradd -u 501 -g 501 -s ${shell} ${user} && \
    chage -m 99999 -M 99999 -W 7 ${user} && \
    mkdir -p /app/log /app/db

COPY _rel/${app}/ /app/

RUN chown -Rf ${user} /app

VOLUME /app/db /app/log

USER ${user}

CMD ["/app/bin/ramp", "foreground"]

EXPOSE 8083 22022
