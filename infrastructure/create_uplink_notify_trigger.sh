#!/bin/bash
kubectl exec -n iot-system statefulset/postgres -- \
  psql -U chirpstack -d chirpstack -c "
    CREATE OR REPLACE FUNCTION notify_new_uplink()
    RETURNS trigger LANGUAGE plpgsql AS \$\$
    BEGIN
      PERFORM pg_notify('new_uplink', row_to_json(NEW)::text);
      RETURN NEW;
    END;
    \$\$;

    DROP TRIGGER IF EXISTS device_uplinks_notify ON device_uplinks;
    CREATE TRIGGER device_uplinks_notify
    AFTER INSERT ON device_uplinks
    FOR EACH ROW EXECUTE FUNCTION notify_new_uplink();
  "
