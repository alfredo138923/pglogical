/* First test whether a table's replication set can be properly manipulated */

SELECT * FROM pglogical_regress_variables()
\gset

\c :provider_dsn

SELECT pglogical.replicate_ddl_command($$
CREATE SCHEMA "strange.schema-IS";
CREATE TABLE public.test_publicschema(id serial primary key, data text);
CREATE TABLE public.test_nosync(id serial primary key, data text);
CREATE TABLE "strange.schema-IS".test_strangeschema(id serial primary key);
CREATE TABLE "strange.schema-IS".test_diff_repset(id serial primary key, data text DEFAULT '');
$$);

SELECT pg_xlog_wait_remote_apply(pg_current_xlog_location(), 0);

-- create some replication sets
SELECT * FROM pglogical.create_replication_set('repset_test');

-- move tables to replication set that is not subscribed
SELECT * FROM pglogical.replication_set_add_table('repset_test', 'test_publicschema');
SELECT * FROM pglogical.replication_set_add_table('repset_test', 'test_nosync');
SELECT * FROM pglogical.replication_set_add_table('repset_test', '"strange.schema-IS".test_strangeschema');
SELECT * FROM pglogical.replication_set_add_table('repset_test', '"strange.schema-IS".test_diff_repset');
SELECT * FROM pglogical.replication_set_add_all_sequences('repset_test', '{public}');
SELECT * FROM pglogical.replication_set_add_sequence('repset_test', pg_get_serial_sequence('"strange.schema-IS".test_strangeschema', 'id'));
SELECT * FROM pglogical.replication_set_add_sequence('repset_test', pg_get_serial_sequence('"strange.schema-IS".test_diff_repset', 'id'));
SELECT * FROM pglogical.replication_set_add_all_sequences('default', '{public}');
SELECT * FROM pglogical.replication_set_add_sequence('default', pg_get_serial_sequence('"strange.schema-IS".test_strangeschema', 'id'));
SELECT * FROM pglogical.replication_set_add_sequence('default', pg_get_serial_sequence('"strange.schema-IS".test_diff_repset', 'id'));

INSERT INTO public.test_publicschema(data) VALUES('a');
INSERT INTO public.test_publicschema(data) VALUES('b');
INSERT INTO public.test_nosync(data) VALUES('a');
INSERT INTO public.test_nosync(data) VALUES('b');
INSERT INTO "strange.schema-IS".test_strangeschema VALUES(DEFAULT);
INSERT INTO "strange.schema-IS".test_strangeschema VALUES(DEFAuLT);

SELECT pg_xlog_wait_remote_apply(pg_current_xlog_location(), 0);

\c :subscriber_dsn
SELECT * FROM public.test_publicschema;
\c :provider_dsn

-- move tables back to the subscribed replication set
SELECT * FROM pglogical.replication_set_add_table('default', 'test_publicschema', true);
SELECT * FROM pglogical.replication_set_add_table('default', 'test_nosync', false);
SELECT * FROM pglogical.replication_set_add_table('default', '"strange.schema-IS".test_strangeschema', true);


\c :subscriber_dsn
DO $$
-- give it 10 seconds to syncrhonize the tabes
BEGIN
	FOR i IN 1..100 LOOP
		IF (SELECT count(1) FROM pglogical.local_sync_status WHERE sync_status = 'r' AND sync_relname IN ('test_publicschema', 'test_strangeschema')) > 1 THEN
			RETURN;
		END IF;
		PERFORM pg_sleep(0.1);
	END LOOP;
END;
$$;

SELECT sync_kind, sync_subid, sync_nspname, sync_relname, sync_status FROM pglogical.local_sync_status ORDER BY 2,3,4;

\c :provider_dsn
INSERT INTO public.test_publicschema VALUES(3, 'c');
INSERT INTO public.test_publicschema VALUES(4, 'd');
INSERT INTO "strange.schema-IS".test_strangeschema VALUES(3);
INSERT INTO "strange.schema-IS".test_strangeschema VALUES(4);

SELECT pglogical.synchronize_sequence(c.oid)
  FROM pg_class c, pg_namespace n
 WHERE c.relkind = 'S' AND c.relnamespace = n.oid AND n.nspname IN ('public', 'strange.schema-IS');

SELECT pg_xlog_wait_remote_apply(pg_current_xlog_location(), 0);

\c :subscriber_dsn
SELECT * FROM public.test_publicschema;
SELECT * FROM "strange.schema-IS".test_strangeschema;

SELECT * FROM pglogical.alter_subscription_synchronize('test_subscription');

DO $$
-- give it 10 seconds to syncrhonize the tabes
BEGIN
	FOR i IN 1..100 LOOP
		IF EXISTS (SELECT 1 FROM pglogical.local_sync_status WHERE sync_status = 'r' AND sync_relname IN ('test_nosync')) THEN
			RETURN;
		END IF;
		PERFORM pg_sleep(0.1);
	END LOOP;
END;
$$;

SELECT sync_kind, sync_subid, sync_nspname, sync_relname, sync_status FROM pglogical.local_sync_status ORDER BY 2,3,4;

SELECT * FROM public.test_nosync;

DELETE FROM public.test_publicschema WHERE id > 1;
SELECT * FROM public.test_publicschema;

SELECT * FROM pglogical.alter_subscription_resynchronize_table('test_subscription', 'test_publicschema');

DO $$
-- give it 10 seconds to syncrhonize the tabes
BEGIN
	FOR i IN 1..100 LOOP
		IF EXISTS (SELECT 1 FROM pglogical.local_sync_status WHERE sync_status = 'r' AND sync_relname IN ('test_publicschema')) THEN
			RETURN;
		END IF;
		PERFORM pg_sleep(0.1);
	END LOOP;
END;
$$;

SELECT sync_kind, sync_subid, sync_nspname, sync_relname, sync_status FROM pglogical.local_sync_status ORDER BY 2,3,4;

SELECT * FROM public.test_publicschema;

\x
SELECT * FROM pglogical.show_subscription_table('test_subscription', 'test_publicschema');
\x

BEGIN;
SELECT * FROM pglogical.alter_subscription_add_replication_set('test_subscription', 'repset_test');
SELECT * FROM pglogical.alter_subscription_remove_replication_set('test_subscription', 'default');
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

\c :provider_dsn
SELECT * FROM pglogical.replication_set_remove_table('repset_test', '"strange.schema-IS".test_strangeschema');

INSERT INTO "strange.schema-IS".test_diff_repset VALUES(1);
INSERT INTO "strange.schema-IS".test_diff_repset VALUES(2);

INSERT INTO "strange.schema-IS".test_strangeschema VALUES(5);
INSERT INTO "strange.schema-IS".test_strangeschema VALUES(6);

SELECT pg_xlog_wait_remote_apply(pg_current_xlog_location(), 0);

\c :subscriber_dsn
SELECT * FROM "strange.schema-IS".test_diff_repset;
SELECT * FROM "strange.schema-IS".test_strangeschema;

\c :provider_dsn

SELECT * FROM pglogical.alter_replication_set('repset_test', replicate_insert := false, replicate_update := false, replicate_delete := false, replicate_truncate := false);

INSERT INTO "strange.schema-IS".test_diff_repset VALUES(3);
INSERT INTO "strange.schema-IS".test_diff_repset VALUES(4);
UPDATE "strange.schema-IS".test_diff_repset SET data = 'data';
DELETE FROM "strange.schema-IS".test_diff_repset WHERE id < 3;
TRUNCATE "strange.schema-IS".test_diff_repset;

SELECT pg_xlog_wait_remote_apply(pg_current_xlog_location(), 0);

\c :subscriber_dsn

SELECT * FROM "strange.schema-IS".test_diff_repset;

\c :provider_dsn

SELECT * FROM pglogical.alter_replication_set('repset_test', replicate_insert := true, replicate_truncate := true);

INSERT INTO "strange.schema-IS".test_diff_repset VALUES(5);
INSERT INTO "strange.schema-IS".test_diff_repset VALUES(6);

SELECT pg_xlog_wait_remote_apply(pg_current_xlog_location(), 0);

\c :subscriber_dsn

SELECT * FROM "strange.schema-IS".test_diff_repset;

\c :provider_dsn

TRUNCATE "strange.schema-IS".test_diff_repset;

SELECT pg_xlog_wait_remote_apply(pg_current_xlog_location(), 0);

\c :subscriber_dsn

SELECT * FROM "strange.schema-IS".test_diff_repset;

SELECT * FROM pglogical.alter_subscription_add_replication_set('test_subscription', 'default');

SELECT N.nspname AS schemaname, C.relname AS tablename, (nextval(C.oid) > 1000) as synced
  FROM pg_class C JOIN pg_namespace N ON (N.oid = C.relnamespace)
 WHERE C.relkind = 'S' AND N.nspname IN ('public', 'strange.schema-IS');

\c :provider_dsn

DO $$
BEGIN
	FOR i IN 1..100 LOOP
		IF EXISTS (SELECT 1 FROM pg_stat_replication) THEN
			RETURN;
		END IF;
		PERFORM pg_sleep(0.1);
	END LOOP;
END;
$$;

\set VERBOSITY terse
SELECT pglogical.replicate_ddl_command($$
	DROP TABLE public.test_publicschema CASCADE;
	DROP TABLE public.test_nosync CASCADE;
	DROP SCHEMA "strange.schema-IS" CASCADE;
$$);
