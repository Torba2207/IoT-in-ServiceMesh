#!/bin/bash
kubectl exec -n iot-system statefulset/postgres -- \
  psql -U chirpstack -d chirpstack -c "
    CREATE TABLE IF NOT EXISTS device_uplinks (
      id          BIGSERIAL PRIMARY KEY,
      device_eui  TEXT NOT NULL,
      device_name TEXT,
      received_at TIMESTAMPTZ NOT NULL,
      f_port      SMALLINT,
      payload     JSONB
    );
  "