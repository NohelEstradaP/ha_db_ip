FROM postgres:16-bookworm

RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 python3-venv curl \
 && python3 -m venv /opt/patroni \
 && /opt/patroni/bin/pip install --no-cache-dir "patroni[etcd3,psycopg3]==4.0.4" \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

ENV PATH="/opt/patroni/bin:${PATH}"

COPY patroni.yml /etc/patroni/patroni.yml

USER postgres
EXPOSE 5432 8008
ENTRYPOINT ["patroni", "/etc/patroni/patroni.yml"]
