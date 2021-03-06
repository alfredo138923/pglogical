-- This should be done with pg_regress's --create-role option
-- but it's blocked by bug 37906
SELECT * FROM pglogical_regress_variables()
\gset

\c :provider_dsn
SET client_min_messages = 'warning';
DROP USER IF EXISTS nonsuper;
DROP USER IF EXISTS super;

CREATE USER nonsuper WITH replication;
CREATE USER super SUPERUSER;

\c :subscriber_dsn
SET client_min_messages = 'warning';
DROP USER IF EXISTS nonsuper;
DROP USER IF EXISTS super;

CREATE USER nonsuper WITH replication;
CREATE USER super SUPERUSER;

-- Can't because of bug 37906
--GRANT ALL ON DATABASE regress TO nonsuper;
--GRANT ALL ON DATABASE regress TO nonsuper;

\c :provider_dsn
GRANT ALL ON SCHEMA public TO nonsuper;

CREATE OR REPLACE FUNCTION public.pg_xlog_wait_remote_apply(i_pos pg_lsn, i_pid integer) RETURNS VOID
AS $FUNC$
BEGIN
    WHILE EXISTS(SELECT true FROM pg_stat_get_wal_senders() s WHERE s.flush_location < i_pos AND (i_pid = 0 OR s.pid = i_pid)) LOOP
		PERFORM pg_sleep(0.01);
	END LOOP;
END;$FUNC$ LANGUAGE plpgsql;

\c :subscriber_dsn
GRANT ALL ON SCHEMA public TO nonsuper;

\c :provider_dsn
SET client_min_messages = 'warning';
CREATE EXTENSION IF NOT EXISTS pglogical VERSION '1.0.0';
ALTER EXTENSION pglogical UPDATE;

SELECT * FROM pglogical.create_node(node_name := 'test_provider', dsn := (SELECT provider_dsn FROM pglogical_regress_variables()) || ' user=super');

\c :subscriber_dsn
SET client_min_messages = 'warning';
CREATE EXTENSION IF NOT EXISTS pglogical;

DO $$
BEGIN
	IF (SELECT setting::integer/100 FROM pg_settings WHERE name = 'server_version_num') = 904 THEN
		CREATE EXTENSION IF NOT EXISTS pglogical_origin;
	END IF;
END;$$;

SELECT * FROM pglogical.create_node(node_name := 'test_subscriber', dsn := (SELECT subscriber_dsn FROM pglogical_regress_variables()) || ' user=super');

BEGIN;
SELECT * FROM pglogical.create_subscription(
    subscription_name := 'test_subscription',
    provider_dsn := (SELECT provider_dsn FROM pglogical_regress_variables()) || ' user=super',
	synchronize_structure := true,
	forward_origins := '{}');
/*
 * Remove the function we added in preseed because otherwise the restore of
 * schema will fail. We do this in same transaction as create_subscription()
 * because the subscription process will only start on commit.
 */
DROP FUNCTION IF EXISTS public.pglogical_regress_variables();
COMMIT;

DO $$
BEGIN
	FOR i IN 1..100 LOOP
		IF EXISTS (SELECT 1 FROM pglogical.show_subscription_status() WHERE status = 'replicating') THEN
			RETURN;
		END IF;
		PERFORM pg_sleep(0.1);
	END LOOP;
END;
$$;

SELECT subscription_name, status, provider_node, replication_sets, forward_origins FROM pglogical.show_subscription_status();

DO $$
BEGIN
    FOR i IN 1..300 LOOP
        IF EXISTS (SELECT 1 FROM pglogical.local_sync_status WHERE sync_status = 'r') THEN
            EXIT;
        END IF;
        PERFORM pg_sleep(0.1);
    END LOOP;
END;$$;

SELECT sync_kind, sync_subid, sync_nspname, sync_relname, sync_status FROM pglogical.local_sync_status ORDER BY 2,3,4;

-- Make sure we see the slot and active connection
\c :provider_dsn
SELECT plugin, slot_type, active FROM pg_replication_slots;
SELECT count(*) FROM pg_stat_replication;
