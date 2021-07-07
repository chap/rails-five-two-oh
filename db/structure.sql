SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: raw; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA raw;


--
-- Name: plpgsql; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS plpgsql WITH SCHEMA pg_catalog;


--
-- Name: EXTENSION plpgsql; Type: COMMENT; Schema: -; Owner: -
--

-- COMMENT ON EXTENSION plpgsql IS 'PL/pgSQL procedural language';


--
-- Name: hstore; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS hstore WITH SCHEMA public;


--
-- Name: EXTENSION hstore; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION hstore IS 'data type for storing sets of (key, value) pairs';


--
-- Name: pg_stat_statements; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_stat_statements WITH SCHEMA public;


--
-- Name: EXTENSION pg_stat_statements; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pg_stat_statements IS 'track execution statistics of all SQL statements executed';


--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- Name: uuid-ossp; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA public;


--
-- Name: EXTENSION "uuid-ossp"; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION "uuid-ossp" IS 'generate universally unique identifiers (UUIDs)';


--
-- Name: connection; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.connection AS ENUM (
    'regular2G',
    'good2G',
    'regular3G',
    'good3G',
    'emergingMarkets',
    'regular4G',
    'dsl',
    'wifi',
    'slow3G',
    'LTE',
    'cable'
);


--
-- Name: device; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.device AS ENUM (
    'MotorolaMotoG4',
    'iPhone5',
    'iPhone6',
    'iPhone6Plus',
    'iPhone7',
    'iPhone8',
    'Nexus5X',
    'Nexus6P',
    'GalaxyS5',
    'iPad',
    'iPadPro'
);


--
-- Name: standalone_run_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.standalone_run_status AS ENUM (
    'scheduled',
    'running',
    'timeout',
    'completed',
    'errored',
    'processing'
);


--
-- Name: domain_owner_map(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.domain_owner_map(domain text, prefix text DEFAULT ''::text, OUT id bigint, OUT name text, OUT tld text, OUT tld_hash text, OUT prefix text) RETURNS SETOF record
    LANGUAGE sql
    AS $$
    SELECT
      third_party_products.id,
      third_party_products.name,
      domain,
      third_party_domains.tld_hash,
      third_party_domains.prefix
    FROM third_party_domains
    JOIN third_party_products ON third_party_products.id = third_party_domains.third_party_product_id
    WHERE tld_hash = substring(encode(digest(domain, 'sha1'), 'hex'), 1, 16)
    AND (third_party_domains.prefix = '*' OR third_party_domains.prefix = prefix)
    LIMIT 1
  $$;


--
-- Name: extract_domain_owners(text[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.extract_domain_owners(domains text[]) RETURNS TABLE(id bigint, name text, tld text, tld_hash text, prefix text)
    LANGUAGE plpgsql
    AS $$
    DECLARE
      domain TEXT;
    BEGIN
      FOR domain IN SELECT unnest(domains) LOOP
        RETURN QUERY SELECT * FROM domain_owner_map(domain);
      END LOOP;
    END
  $$;


--
-- Name: insert_into_30_day_metrics(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.insert_into_30_day_metrics() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
  BEGIN
    -- NEW.id is the run id
  
    -- Select measurements to be copied into 30_day_metrics table
    INSERT INTO thirty_day_timeseries (name, value, site_id, endpoint_id, run_profile_id, checkpoint_id, timestamp) (
      SELECT
        measurements.name AS measurement_name,
        measurements.value AS measurement_value,
        sites.id AS site_id,
        endpoints.id AS endpoint_id,
        run_profiles.id AS run_profile_id,
        checkpoints.id AS checkpoint_id,
        NEW.created_at AS timestamp
      FROM runs
      JOIN "checkpoints" on "checkpoints"."id" = "runs"."checkpoint_id"
      JOIN "sites" ON "sites"."id" = "checkpoints"."site_id"
      JOIN "endpoints" ON "endpoints"."id" = "runs"."endpoint_id"
      JOIN "run_profiles" ON "run_profiles"."id" = "runs"."run_profile_id"
      JOIN "run_results" ON "run_results"."run_id" = "runs"."id"
      JOIN "measurements" ON "measurements"."run_result_id" = "run_results"."id"
      WHERE runs.id = NEW.id -- the run
    );
    
    RETURN NEW;
  END;
$$;


SET default_tablespace = '';

SET default_with_oids = false;

--
-- Name: queue_classic_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.queue_classic_jobs (
    id bigint NOT NULL,
    q_name text NOT NULL,
    method text NOT NULL,
    args json NOT NULL,
    locked_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now(),
    locked_by integer,
    scheduled_at timestamp with time zone DEFAULT now(),
    CONSTRAINT queue_classic_jobs_method_check CHECK ((length(method) > 0)),
    CONSTRAINT queue_classic_jobs_q_name_check CHECK ((length(q_name) > 0))
);


--
-- Name: lock_head(character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.lock_head(tname character varying) RETURNS SETOF public.queue_classic_jobs
    LANGUAGE plpgsql
    AS $_$
BEGIN
  RETURN QUERY EXECUTE 'SELECT * FROM lock_head($1,10)' USING tname;
END;
$_$;


--
-- Name: lock_head(character varying, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.lock_head(q_name character varying, top_boundary integer) RETURNS SETOF public.queue_classic_jobs
    LANGUAGE plpgsql
    AS $_$
DECLARE
  unlocked bigint;
  relative_top integer;
  job_count integer;
BEGIN
  -- The purpose is to release contention for the first spot in the table.
  -- The select count(*) is going to slow down dequeue performance but allow
  -- for more workers. Would love to see some optimization here...

  EXECUTE 'SELECT count(*) FROM '
    || '(SELECT * FROM queue_classic_jobs '
    || ' WHERE locked_at IS NULL'
    || ' AND q_name = '
    || quote_literal(q_name)
    || ' AND scheduled_at <= '
    || quote_literal(now())
    || ' LIMIT '
    || quote_literal(top_boundary)
    || ') limited'
  INTO job_count;

  SELECT TRUNC(random() * (top_boundary - 1))
  INTO relative_top;

  IF job_count < top_boundary THEN
    relative_top = 0;
  END IF;

  LOOP
    BEGIN
      EXECUTE 'SELECT id FROM queue_classic_jobs '
        || ' WHERE locked_at IS NULL'
        || ' AND q_name = '
        || quote_literal(q_name)
        || ' AND scheduled_at <= '
        || quote_literal(now())
        || ' ORDER BY id ASC'
        || ' LIMIT 1'
        || ' OFFSET ' || quote_literal(relative_top)
        || ' FOR UPDATE NOWAIT'
      INTO unlocked;
      EXIT;
    EXCEPTION
      WHEN lock_not_available THEN
        -- do nothing. loop again and hope we get a lock
    END;
  END LOOP;

  RETURN QUERY EXECUTE 'UPDATE queue_classic_jobs '
    || ' SET locked_at = (CURRENT_TIMESTAMP),'
    || ' locked_by = (select pg_backend_pid())'
    || ' WHERE id = $1'
    || ' AND locked_at is NULL'
    || ' RETURNING *'
  USING unlocked;

  RETURN;
END;
$_$;


--
-- Name: queue_classic_notify(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.queue_classic_notify() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ begin
  perform pg_notify(new.q_name, '');
  return null;
end $$;


--
-- Name: run_insert_into_organisation_test_usage(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.run_insert_into_organisation_test_usage() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
  BEGIN
    INSERT INTO organisation_test_usage (organisation_id, site_id, updated_at, created_at) (
      SELECT
        sites.organisation_id,
        sites.id,
        NEW.updated_at,
        NEW.created_at
      FROM runs
      JOIN "checkpoints" ON "checkpoints"."id" = "runs"."checkpoint_id"
      JOIN "sites" ON "sites"."id" = "checkpoints"."site_id"
      WHERE runs.id = NEW.id
    );

    RETURN NEW;
  END;
$$;


--
-- Name: standalone_run_insert_into_organisation_test_usage(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.standalone_run_insert_into_organisation_test_usage() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
  BEGIN
    INSERT INTO organisation_test_usage (organisation_id, standalone_run_id, updated_at, created_at) (
      SELECT
        organisation_id,
        id,
        updated_at,
        created_at
      FROM standalone_runs
      WHERE id = NEW.id
    );

    RETURN NEW;
  END;
$$;


--
-- Name: agents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agents (
    id integer NOT NULL,
    ipv4_address character varying,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    region_id integer
);


--
-- Name: agents_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.agents_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: agents_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.agents_id_seq OWNED BY public.agents.id;


--
-- Name: ar_internal_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: authem_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.authem_sessions (
    id integer NOT NULL,
    role character varying NOT NULL,
    subject_id integer NOT NULL,
    subject_type character varying NOT NULL,
    token character varying(60) NOT NULL,
    expires_at timestamp without time zone NOT NULL,
    ttl integer NOT NULL,
    created_at timestamp without time zone,
    updated_at timestamp without time zone
);


--
-- Name: authem_sessions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.authem_sessions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: authem_sessions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.authem_sessions_id_seq OWNED BY public.authem_sessions.id;


--
-- Name: authentication_configs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.authentication_configs (
    id integer NOT NULL,
    url character varying(255) NOT NULL,
    form_selector character varying(255) NOT NULL,
    username_selector character varying(255) NOT NULL,
    password_selector character varying(255) NOT NULL,
    username character varying(255) NOT NULL,
    password character varying(255) NOT NULL,
    required boolean DEFAULT false,
    site_id integer,
    created_at timestamp without time zone,
    updated_at timestamp without time zone
);


--
-- Name: authentication_configs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.authentication_configs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: authentication_configs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.authentication_configs_id_seq OWNED BY public.authentication_configs.id;


--
-- Name: billing_infos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.billing_infos (
    id integer NOT NULL,
    organisation_id integer,
    contact_name character varying(255),
    address character varying(255),
    city character varying(255),
    state character varying(255),
    country character varying(255),
    postcode character varying(255),
    invoice_extras text
);


--
-- Name: billing_infos_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.billing_infos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: billing_infos_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.billing_infos_id_seq OWNED BY public.billing_infos.id;


--
-- Name: checkpoints; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.checkpoints (
    id integer NOT NULL,
    site_id integer,
    iid integer,
    created_at timestamp without time zone,
    updated_at timestamp without time zone,
    ref character varying(40),
    client character varying(255),
    status character varying(10)
);


--
-- Name: checkpoints_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.checkpoints_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: checkpoints_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.checkpoints_id_seq OWNED BY public.checkpoints.id;


--
-- Name: collaborations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.collaborations (
    id integer NOT NULL,
    user_id integer,
    site_id integer,
    state character varying(255),
    access_token character varying(255) DEFAULT public.uuid_generate_v4(),
    invitation_email character varying(255),
    created_at timestamp without time zone,
    updated_at timestamp without time zone,
    invitation_name character varying(30)
);


--
-- Name: collaborations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.collaborations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: collaborations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.collaborations_id_seq OWNED BY public.collaborations.id;


--
-- Name: email_deliveries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_deliveries (
    id integer NOT NULL,
    recipient character varying,
    name character varying,
    user_id integer,
    content json,
    content_hash character varying,
    cm_receipt_reference character varying,
    reads integer,
    clicks integer,
    sent_at timestamp without time zone,
    status character varying,
    created_at timestamp without time zone,
    updated_at timestamp without time zone
);


--
-- Name: email_deliveries_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.email_deliveries_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: email_deliveries_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.email_deliveries_id_seq OWNED BY public.email_deliveries.id;


--
-- Name: endpoints; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.endpoints (
    id integer NOT NULL,
    iid integer,
    url text,
    site_id integer,
    canonical boolean DEFAULT false,
    name character varying(255) DEFAULT 'Home'::character varying,
    slug character varying(255),
    deleted_at timestamp without time zone,
    uuid uuid DEFAULT public.uuid_generate_v4() NOT NULL
);


--
-- Name: endpoints_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.endpoints_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: endpoints_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.endpoints_id_seq OWNED BY public.endpoints.id;


--
-- Name: event_subscriptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.event_subscriptions (
    id integer NOT NULL,
    site_id integer,
    membership_id integer
);


--
-- Name: event_subscriptions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.event_subscriptions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: event_subscriptions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.event_subscriptions_id_seq OWNED BY public.event_subscriptions.id;


--
-- Name: events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.events (
    id integer NOT NULL,
    site_id integer,
    checkpoint_id integer,
    event_type character varying(255),
    data json,
    created_at timestamp without time zone,
    updated_at timestamp without time zone,
    user_id integer
);


--
-- Name: events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.events_id_seq OWNED BY public.events.id;


--
-- Name: extracts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.extracts (
    id integer NOT NULL,
    name character varying(255) NOT NULL,
    data json NOT NULL,
    run_result_id integer
);


--
-- Name: extracts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.extracts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: extracts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.extracts_id_seq OWNED BY public.extracts.id;


--
-- Name: friendly_id_slugs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.friendly_id_slugs (
    id integer NOT NULL,
    slug character varying(255) NOT NULL,
    sluggable_id integer NOT NULL,
    sluggable_type character varying(40),
    scope character varying(255),
    created_at timestamp without time zone
);


--
-- Name: friendly_id_slugs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.friendly_id_slugs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: friendly_id_slugs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.friendly_id_slugs_id_seq OWNED BY public.friendly_id_slugs.id;


--
-- Name: invoices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.invoices (
    id integer NOT NULL,
    organisation_id integer,
    stripe_invoice_reference character varying,
    storage_reference character varying,
    delivered_at timestamp without time zone,
    delivered_to character varying,
    created_at timestamp without time zone,
    updated_at timestamp without time zone,
    card_brand character varying,
    card_last4 character varying,
    total_amount integer,
    card_country_code character varying,
    issued_at timestamp without time zone,
    period_start_at timestamp without time zone,
    period_end_at timestamp without time zone,
    status text
);


--
-- Name: invoices_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.invoices_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: invoices_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.invoices_id_seq OWNED BY public.invoices.id;


--
-- Name: measurements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.measurements (
    id integer NOT NULL,
    name character varying(255) NOT NULL,
    value integer NOT NULL,
    unit character varying(255),
    run_result_id integer
);


--
-- Name: measurements_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.measurements_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: measurements_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.measurements_id_seq OWNED BY public.measurements.id;


--
-- Name: memberships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.memberships (
    user_id integer,
    organisation_id integer,
    role character varying(255),
    state character varying(255) DEFAULT 'invited'::character varying,
    access_token character varying(255) DEFAULT public.uuid_generate_v4(),
    invitation_email character varying(255) NOT NULL,
    id integer NOT NULL,
    invitation_name character varying(30)
);


--
-- Name: memberships_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.memberships_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: memberships_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.memberships_id_seq OWNED BY public.memberships.id;


--
-- Name: metric_budgets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.metric_budgets (
    id integer NOT NULL,
    measurement character varying(255),
    value integer,
    site_id integer,
    created_at timestamp without time zone,
    updated_at timestamp without time zone,
    run_profile_id integer,
    endpoint_id integer,
    metric_budget_id integer
);


--
-- Name: metric_budgets_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.metric_budgets_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: metric_budgets_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.metric_budgets_id_seq OWNED BY public.metric_budgets.id;


--
-- Name: notifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notifications (
    id integer NOT NULL,
    site_id integer,
    destination text,
    events text[] DEFAULT '{}'::text[],
    config json
);


--
-- Name: notifications_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.notifications_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: notifications_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.notifications_id_seq OWNED BY public.notifications.id;


--
-- Name: organisation_api_key_activities; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organisation_api_key_activities (
    id bigint NOT NULL,
    organisation_api_key_id bigint,
    client_name character varying NOT NULL,
    client_version character varying NOT NULL,
    request_duration double precision NOT NULL,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: organisation_api_key_activities_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.organisation_api_key_activities_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: organisation_api_key_activities_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.organisation_api_key_activities_id_seq OWNED BY public.organisation_api_key_activities.id;


--
-- Name: organisation_api_keys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organisation_api_keys (
    id bigint NOT NULL,
    description character varying NOT NULL,
    uuid uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    key character varying DEFAULT encode(public.gen_random_bytes(32), 'hex'::text) NOT NULL,
    scopes json,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    organisation_id integer
);


--
-- Name: organisation_api_keys_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.organisation_api_keys_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: organisation_api_keys_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.organisation_api_keys_id_seq OWNED BY public.organisation_api_keys.id;


--
-- Name: organisation_test_usage; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organisation_test_usage (
    id bigint NOT NULL,
    organisation_id bigint,
    site_id bigint,
    standalone_run_id bigint,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT check_reference_is_site_or_standalone CHECK (((site_id IS NOT NULL) OR (standalone_run_id IS NOT NULL)))
);


--
-- Name: organisation_test_usage_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.organisation_test_usage_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: organisation_test_usage_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.organisation_test_usage_id_seq OWNED BY public.organisation_test_usage.id;


--
-- Name: organisations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organisations (
    id integer NOT NULL,
    name character varying(32) NOT NULL,
    slug character varying(255) NOT NULL,
    billing_email character varying(255) NOT NULL,
    user_id integer,
    created_at timestamp without time zone,
    updated_at timestamp without time zone,
    deleted_at timestamp without time zone,
    trial_end_at timestamp without time zone DEFAULT (('now'::text)::date + '14 days'::interval)
);


--
-- Name: organisations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.organisations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: organisations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.organisations_id_seq OWNED BY public.organisations.id;


--
-- Name: preview_images; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.preview_images (
    id integer NOT NULL,
    site_id integer,
    endpoint_id integer,
    url text NOT NULL,
    run_profile_id integer,
    is_mobile boolean
);


--
-- Name: preview_images_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.preview_images_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: preview_images_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.preview_images_id_seq OWNED BY public.preview_images.id;


--
-- Name: queue_classic_jobs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.queue_classic_jobs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: queue_classic_jobs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.queue_classic_jobs_id_seq OWNED BY public.queue_classic_jobs.id;


--
-- Name: regions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.regions (
    id integer NOT NULL,
    identifier character varying,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    private boolean DEFAULT false,
    external_region_id character varying,
    provider character varying,
    location_tag character varying
);


--
-- Name: regions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.regions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: regions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.regions_id_seq OWNED BY public.regions.id;


--
-- Name: run_profile_cookies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.run_profile_cookies (
    id integer NOT NULL,
    name text,
    value text,
    domain text,
    path text DEFAULT '/'::text,
    secure boolean DEFAULT true,
    http_only boolean DEFAULT false,
    run_profile_id integer
);


--
-- Name: run_profile_cookies_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.run_profile_cookies_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: run_profile_cookies_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.run_profile_cookies_id_seq OWNED BY public.run_profile_cookies.id;


--
-- Name: run_profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.run_profiles (
    id integer NOT NULL,
    name text NOT NULL,
    site_id integer,
    bandwidth_title text,
    bandwidth_latency integer,
    bandwidth_download integer,
    bandwidth_upload integer,
    device_title text,
    device_width integer,
    device_height integer,
    device_scalefactor double precision,
    device_user_agent text,
    device_touch boolean,
    device_mobile boolean,
    device_cpu_throttling_rate integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    js_is_disabled boolean DEFAULT false,
    uuid uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    deleted_at timestamp without time zone,
    device_tag character varying,
    bandwidth_tag character varying,
    headers jsonb DEFAULT '[]'::jsonb
);


--
-- Name: run_profiles_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.run_profiles_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: run_profiles_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.run_profiles_id_seq OWNED BY public.run_profiles.id;


--
-- Name: run_results; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.run_results (
    id integer NOT NULL,
    run_id integer,
    name character varying(255),
    context text,
    results text,
    created_at timestamp without time zone,
    updated_at timestamp without time zone,
    error boolean DEFAULT false,
    status character varying(255),
    standalone_run_id bigint,
    CONSTRAINT check_run_result_parent_exists CHECK (((run_id IS NOT NULL) OR (standalone_run_id IS NOT NULL)))
);


--
-- Name: run_results_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.run_results_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: run_results_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.run_results_id_seq OWNED BY public.run_results.id;


--
-- Name: runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.runs (
    id integer NOT NULL,
    created_at timestamp without time zone,
    updated_at timestamp without time zone,
    received_at timestamp without time zone,
    attempts integer DEFAULT 0,
    status character varying(255) DEFAULT 'scheduled'::character varying,
    endpoint_id integer,
    checkpoint_id integer,
    run_profile_id integer
);


--
-- Name: runs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.runs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: runs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.runs_id_seq OWNED BY public.runs.id;


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying(255) NOT NULL
);


--
-- Name: site_api_keys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.site_api_keys (
    id integer NOT NULL,
    access_token character varying(255),
    site_id integer,
    created_at timestamp without time zone,
    updated_at timestamp without time zone
);


--
-- Name: site_api_keys_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.site_api_keys_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: site_api_keys_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.site_api_keys_id_seq OWNED BY public.site_api_keys.id;


--
-- Name: sites; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sites (
    id integer NOT NULL,
    name character varying(255),
    slug character varying(255),
    created_at timestamp without time zone,
    updated_at timestamp without time zone,
    organisation_id integer,
    checkpoints_count integer,
    schedule_anchor integer DEFAULT trunc((random() * (23)::double precision)),
    deleted_at timestamp without time zone,
    disabled_at timestamp without time zone,
    beacon_key uuid DEFAULT public.uuid_generate_v4(),
    primary_region_id integer DEFAULT 4,
    schedule_interval character varying DEFAULT 'daily'::character varying
);


--
-- Name: sites_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sites_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sites_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sites_id_seq OWNED BY public.sites.id;


--
-- Name: standalone_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.standalone_runs (
    id bigint NOT NULL,
    uuid character varying DEFAULT "substring"(((public.uuid_generate_v4())::character varying)::text, 0, 8) NOT NULL,
    url text NOT NULL,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    region_id bigint NOT NULL,
    connection public.connection,
    device public.device,
    status public.standalone_run_status DEFAULT 'scheduled'::public.standalone_run_status,
    share_token character varying DEFAULT "substring"(((public.uuid_generate_v4())::character varying)::text, 0, 8) NOT NULL,
    organisation_id bigint,
    cookies jsonb,
    headers jsonb DEFAULT '[]'::jsonb
);


--
-- Name: standalone_runs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.standalone_runs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: standalone_runs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.standalone_runs_id_seq OWNED BY public.standalone_runs.id;


--
-- Name: subscriptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.subscriptions (
    id integer NOT NULL,
    stripe_customer_reference character varying(255),
    organisation_id integer,
    created_at timestamp without time zone,
    updated_at timestamp without time zone,
    stripe_plan_reference character varying(255),
    status character varying DEFAULT 'trialing'::character varying,
    inclusions jsonb DEFAULT '{"tests_per_month": 1000, "test_profiles_per_site": 1}'::jsonb,
    billing_method character varying DEFAULT 'stripe'::character varying,
    billing_interval character varying,
    stripe_subscription_reference character varying
);


--
-- Name: subscriptions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.subscriptions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: subscriptions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.subscriptions_id_seq OWNED BY public.subscriptions.id;


--
-- Name: third_party_domains; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.third_party_domains (
    id bigint NOT NULL,
    tld_hash character varying(16) NOT NULL,
    prefix character varying,
    third_party_product_id bigint NOT NULL
);


--
-- Name: third_party_domains_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.third_party_domains_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: third_party_domains_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.third_party_domains_id_seq OWNED BY public.third_party_domains.id;


--
-- Name: third_party_products; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.third_party_products (
    id bigint NOT NULL,
    name character varying
);


--
-- Name: third_party_products_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.third_party_products_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: third_party_products_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.third_party_products_id_seq OWNED BY public.third_party_products.id;


--
-- Name: thirty_day_timeseries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.thirty_day_timeseries (
    id bigint NOT NULL,
    name character varying,
    value integer,
    site_id bigint,
    checkpoint_id bigint,
    endpoint_id bigint,
    run_profile_id bigint,
    "timestamp" timestamp without time zone
);


--
-- Name: thirty_day_timeseries_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.thirty_day_timeseries_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: thirty_day_timeseries_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.thirty_day_timeseries_id_seq OWNED BY public.thirty_day_timeseries.id;


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id integer NOT NULL,
    email character varying(255),
    password_digest character varying(255),
    password_reset_token character varying(255),
    name character varying(255),
    staff boolean,
    created_at timestamp without time zone,
    updated_at timestamp without time zone,
    last_seen timestamp without time zone,
    api_key character varying(24)
);


--
-- Name: users_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.users_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: users_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.users_id_seq OWNED BY public.users.id;


--
-- Name: page_view_events; Type: TABLE; Schema: raw; Owner: -
--

CREATE TABLE raw.page_view_events (
    api_key character varying(255),
    uid character varying(64),
    sid character varying(64),
    ip character varying(45),
    traits_name text,
    traits_email text,
    traits_organisation text,
    traits_avatar text,
    geo_country text,
    geo_region text,
    geo_city character varying(75),
    geo_latitude double precision,
    geo_longitude double precision,
    ua_browser_family character varying(64),
    ua_browser_version character varying(64),
    ua_os_family character varying(64),
    ua_os_version character varying(64),
    ua_device character varying(64),
    context_screen_width integer,
    context_screen_height integer,
    context_screen_retina boolean,
    context_page_title character varying(255),
    context_page_url text,
    context_page_url_protocol character varying(6),
    context_page_url_host character varying(255),
    context_page_url_path text,
    context_page_referrer text,
    library_name character varying(30),
    library_version character varying(100),
    "timing_navigationStart" character(13),
    "timing_unloadEventStart" integer,
    "timing_unloadEventEnd" integer,
    "timing_redirectStart" integer,
    "timing_redirectEnd" integer,
    "timing_fetchStart" integer,
    "timing_domainLookupStart" integer,
    "timing_domainLookupEnd" integer,
    "timing_connectStart" integer,
    "timing_connectEnd" integer,
    "timing_secureConnectionStart" integer,
    "timing_requestStart" integer,
    "timing_responseStart" integer,
    "timing_responseEnd" integer,
    "timing_domLoading" integer,
    "timing_domInteractive" integer,
    "timing_domContentLoadedEventStart" integer,
    "timing_domContentLoadedEventEnd" integer,
    "timing_domComplete" integer,
    "timing_loadEventStart" integer,
    "timing_loadEventEnd" integer,
    "timing_firstPaint" integer,
    created_at timestamp without time zone DEFAULT now(),
    context_page_url_search text,
    context_page_referrer_protocol character varying(6),
    context_page_referrer_host character varying(255),
    context_page_referrer_path text,
    context_page_referrer_search text
);


--
-- Name: TABLE page_view_events; Type: COMMENT; Schema: raw; Owner: -
--

COMMENT ON TABLE raw.page_view_events IS '1.0.0';


--
-- Name: agents id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agents ALTER COLUMN id SET DEFAULT nextval('public.agents_id_seq'::regclass);


--
-- Name: authem_sessions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.authem_sessions ALTER COLUMN id SET DEFAULT nextval('public.authem_sessions_id_seq'::regclass);


--
-- Name: authentication_configs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.authentication_configs ALTER COLUMN id SET DEFAULT nextval('public.authentication_configs_id_seq'::regclass);


--
-- Name: billing_infos id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_infos ALTER COLUMN id SET DEFAULT nextval('public.billing_infos_id_seq'::regclass);


--
-- Name: checkpoints id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.checkpoints ALTER COLUMN id SET DEFAULT nextval('public.checkpoints_id_seq'::regclass);


--
-- Name: collaborations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.collaborations ALTER COLUMN id SET DEFAULT nextval('public.collaborations_id_seq'::regclass);


--
-- Name: email_deliveries id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_deliveries ALTER COLUMN id SET DEFAULT nextval('public.email_deliveries_id_seq'::regclass);


--
-- Name: endpoints id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.endpoints ALTER COLUMN id SET DEFAULT nextval('public.endpoints_id_seq'::regclass);


--
-- Name: event_subscriptions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.event_subscriptions ALTER COLUMN id SET DEFAULT nextval('public.event_subscriptions_id_seq'::regclass);


--
-- Name: events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events ALTER COLUMN id SET DEFAULT nextval('public.events_id_seq'::regclass);


--
-- Name: extracts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.extracts ALTER COLUMN id SET DEFAULT nextval('public.extracts_id_seq'::regclass);


--
-- Name: friendly_id_slugs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.friendly_id_slugs ALTER COLUMN id SET DEFAULT nextval('public.friendly_id_slugs_id_seq'::regclass);


--
-- Name: invoices id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoices ALTER COLUMN id SET DEFAULT nextval('public.invoices_id_seq'::regclass);


--
-- Name: measurements id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.measurements ALTER COLUMN id SET DEFAULT nextval('public.measurements_id_seq'::regclass);


--
-- Name: memberships id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memberships ALTER COLUMN id SET DEFAULT nextval('public.memberships_id_seq'::regclass);


--
-- Name: metric_budgets id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.metric_budgets ALTER COLUMN id SET DEFAULT nextval('public.metric_budgets_id_seq'::regclass);


--
-- Name: notifications id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications ALTER COLUMN id SET DEFAULT nextval('public.notifications_id_seq'::regclass);


--
-- Name: organisation_api_key_activities id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organisation_api_key_activities ALTER COLUMN id SET DEFAULT nextval('public.organisation_api_key_activities_id_seq'::regclass);


--
-- Name: organisation_api_keys id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organisation_api_keys ALTER COLUMN id SET DEFAULT nextval('public.organisation_api_keys_id_seq'::regclass);


--
-- Name: organisation_test_usage id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organisation_test_usage ALTER COLUMN id SET DEFAULT nextval('public.organisation_test_usage_id_seq'::regclass);


--
-- Name: organisations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organisations ALTER COLUMN id SET DEFAULT nextval('public.organisations_id_seq'::regclass);


--
-- Name: preview_images id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.preview_images ALTER COLUMN id SET DEFAULT nextval('public.preview_images_id_seq'::regclass);


--
-- Name: queue_classic_jobs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.queue_classic_jobs ALTER COLUMN id SET DEFAULT nextval('public.queue_classic_jobs_id_seq'::regclass);


--
-- Name: regions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.regions ALTER COLUMN id SET DEFAULT nextval('public.regions_id_seq'::regclass);


--
-- Name: run_profile_cookies id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.run_profile_cookies ALTER COLUMN id SET DEFAULT nextval('public.run_profile_cookies_id_seq'::regclass);


--
-- Name: run_profiles id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.run_profiles ALTER COLUMN id SET DEFAULT nextval('public.run_profiles_id_seq'::regclass);


--
-- Name: run_results id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.run_results ALTER COLUMN id SET DEFAULT nextval('public.run_results_id_seq'::regclass);


--
-- Name: runs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.runs ALTER COLUMN id SET DEFAULT nextval('public.runs_id_seq'::regclass);


--
-- Name: site_api_keys id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.site_api_keys ALTER COLUMN id SET DEFAULT nextval('public.site_api_keys_id_seq'::regclass);


--
-- Name: sites id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sites ALTER COLUMN id SET DEFAULT nextval('public.sites_id_seq'::regclass);


--
-- Name: standalone_runs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.standalone_runs ALTER COLUMN id SET DEFAULT nextval('public.standalone_runs_id_seq'::regclass);


--
-- Name: subscriptions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscriptions ALTER COLUMN id SET DEFAULT nextval('public.subscriptions_id_seq'::regclass);


--
-- Name: third_party_domains id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.third_party_domains ALTER COLUMN id SET DEFAULT nextval('public.third_party_domains_id_seq'::regclass);


--
-- Name: third_party_products id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.third_party_products ALTER COLUMN id SET DEFAULT nextval('public.third_party_products_id_seq'::regclass);


--
-- Name: thirty_day_timeseries id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.thirty_day_timeseries ALTER COLUMN id SET DEFAULT nextval('public.thirty_day_timeseries_id_seq'::regclass);


--
-- Name: users id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users ALTER COLUMN id SET DEFAULT nextval('public.users_id_seq'::regclass);


--
-- Name: agents agents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agents
    ADD CONSTRAINT agents_pkey PRIMARY KEY (id);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: authem_sessions authem_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.authem_sessions
    ADD CONSTRAINT authem_sessions_pkey PRIMARY KEY (id);


--
-- Name: authentication_configs authentication_configs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.authentication_configs
    ADD CONSTRAINT authentication_configs_pkey PRIMARY KEY (id);


--
-- Name: billing_infos billing_infos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_infos
    ADD CONSTRAINT billing_infos_pkey PRIMARY KEY (id);


--
-- Name: checkpoints checkpoints_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.checkpoints
    ADD CONSTRAINT checkpoints_pkey PRIMARY KEY (id);


--
-- Name: email_deliveries email_deliveries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_deliveries
    ADD CONSTRAINT email_deliveries_pkey PRIMARY KEY (id);


--
-- Name: endpoints endpoints_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.endpoints
    ADD CONSTRAINT endpoints_pkey PRIMARY KEY (id);


--
-- Name: event_subscriptions event_subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.event_subscriptions
    ADD CONSTRAINT event_subscriptions_pkey PRIMARY KEY (id);


--
-- Name: events events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events
    ADD CONSTRAINT events_pkey PRIMARY KEY (id);


--
-- Name: extracts extracts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.extracts
    ADD CONSTRAINT extracts_pkey PRIMARY KEY (id);


--
-- Name: friendly_id_slugs friendly_id_slugs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.friendly_id_slugs
    ADD CONSTRAINT friendly_id_slugs_pkey PRIMARY KEY (id);


--
-- Name: invoices invoices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoices
    ADD CONSTRAINT invoices_pkey PRIMARY KEY (id);


--
-- Name: measurements measurements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.measurements
    ADD CONSTRAINT measurements_pkey PRIMARY KEY (id);


--
-- Name: collaborations memberships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.collaborations
    ADD CONSTRAINT memberships_pkey PRIMARY KEY (id);


--
-- Name: memberships memberships_pkey1; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT memberships_pkey1 PRIMARY KEY (id);


--
-- Name: metric_budgets metric_budgets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.metric_budgets
    ADD CONSTRAINT metric_budgets_pkey PRIMARY KEY (id);


--
-- Name: notifications notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_pkey PRIMARY KEY (id);


--
-- Name: organisation_api_key_activities organisation_api_key_activities_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organisation_api_key_activities
    ADD CONSTRAINT organisation_api_key_activities_pkey PRIMARY KEY (id);


--
-- Name: organisation_api_keys organisation_api_keys_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organisation_api_keys
    ADD CONSTRAINT organisation_api_keys_pkey PRIMARY KEY (id);


--
-- Name: organisation_test_usage organisation_test_usage_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organisation_test_usage
    ADD CONSTRAINT organisation_test_usage_pkey PRIMARY KEY (id);


--
-- Name: organisations organisations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organisations
    ADD CONSTRAINT organisations_pkey PRIMARY KEY (id);


--
-- Name: preview_images preview_images_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.preview_images
    ADD CONSTRAINT preview_images_pkey PRIMARY KEY (id);


--
-- Name: queue_classic_jobs queue_classic_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.queue_classic_jobs
    ADD CONSTRAINT queue_classic_jobs_pkey PRIMARY KEY (id);


--
-- Name: regions regions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.regions
    ADD CONSTRAINT regions_pkey PRIMARY KEY (id);


--
-- Name: run_profile_cookies run_profile_cookies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.run_profile_cookies
    ADD CONSTRAINT run_profile_cookies_pkey PRIMARY KEY (id);


--
-- Name: run_profiles run_profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.run_profiles
    ADD CONSTRAINT run_profiles_pkey PRIMARY KEY (id);


--
-- Name: run_results run_results_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.run_results
    ADD CONSTRAINT run_results_pkey PRIMARY KEY (id);


--
-- Name: runs runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.runs
    ADD CONSTRAINT runs_pkey PRIMARY KEY (id);


--
-- Name: site_api_keys site_api_keys_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.site_api_keys
    ADD CONSTRAINT site_api_keys_pkey PRIMARY KEY (id);


--
-- Name: sites sites_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sites
    ADD CONSTRAINT sites_pkey PRIMARY KEY (id);


--
-- Name: standalone_runs standalone_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.standalone_runs
    ADD CONSTRAINT standalone_runs_pkey PRIMARY KEY (id);


--
-- Name: subscriptions subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT subscriptions_pkey PRIMARY KEY (id);


--
-- Name: third_party_domains third_party_domains_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.third_party_domains
    ADD CONSTRAINT third_party_domains_pkey PRIMARY KEY (id);


--
-- Name: third_party_products third_party_products_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.third_party_products
    ADD CONSTRAINT third_party_products_pkey PRIMARY KEY (id);


--
-- Name: thirty_day_timeseries thirty_day_timeseries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.thirty_day_timeseries
    ADD CONSTRAINT thirty_day_timeseries_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: fk__authem_sessions_subject_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX fk__authem_sessions_subject_id ON public.authem_sessions USING btree (subject_type, subject_id);


--
-- Name: fk__authentication_configs_site_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX fk__authentication_configs_site_id ON public.authentication_configs USING btree (site_id);


--
-- Name: fk__billing_infos_organisation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX fk__billing_infos_organisation_id ON public.billing_infos USING btree (organisation_id);


--
-- Name: fk__checkpoints_site_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX fk__checkpoints_site_id ON public.checkpoints USING btree (site_id);


--
-- Name: fk__email_deliveries_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX fk__email_deliveries_user_id ON public.email_deliveries USING btree (user_id);


--
-- Name: fk__endpoints_site_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX fk__endpoints_site_id ON public.endpoints USING btree (site_id);


--
-- Name: fk__event_subscriptions_membership_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX fk__event_subscriptions_membership_id ON public.event_subscriptions USING btree (membership_id);


--
-- Name: fk__event_subscriptions_site_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX fk__event_subscriptions_site_id ON public.event_subscriptions USING btree (site_id);


--
-- Name: fk__events_checkpoint_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX fk__events_checkpoint_id ON public.events USING btree (checkpoint_id);


--
-- Name: fk__events_site_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX fk__events_site_id ON public.events USING btree (site_id);


--
-- Name: fk__events_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX fk__events_user_id ON public.events USING btree (user_id);


--
-- Name: fk__extracts_run_result_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX fk__extracts_run_result_id ON public.extracts USING btree (run_result_id);


--
-- Name: fk__invoices_organisation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX fk__invoices_organisation_id ON public.invoices USING btree (organisation_id);


--
-- Name: fk__memberships_organisation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX fk__memberships_organisation_id ON public.memberships USING btree (organisation_id);


--
-- Name: fk__metric_budgets_site_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX fk__metric_budgets_site_id ON public.metric_budgets USING btree (site_id);


--
-- Name: fk__notifications_site_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX fk__notifications_site_id ON public.notifications USING btree (site_id);


--
-- Name: fk__organisations_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX fk__organisations_user_id ON public.organisations USING btree (user_id);


--
-- Name: fk__preview_images_endpoint_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX fk__preview_images_endpoint_id ON public.preview_images USING btree (endpoint_id);


--
-- Name: fk__preview_images_site_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX fk__preview_images_site_id ON public.preview_images USING btree (site_id);


--
-- Name: fk__runs_checkpoint_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX fk__runs_checkpoint_id ON public.runs USING btree (checkpoint_id);


--
-- Name: fk__runs_endpoint_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX fk__runs_endpoint_id ON public.runs USING btree (endpoint_id);


--
-- Name: fk__sites_organisation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX fk__sites_organisation_id ON public.sites USING btree (organisation_id);


--
-- Name: fk__subscriptions_organisation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX fk__subscriptions_organisation_id ON public.subscriptions USING btree (organisation_id);


--
-- Name: idx_org; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_org ON public.organisation_test_usage USING btree (organisation_id);


--
-- Name: idx_orgApiKey_activities; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX "idx_orgApiKey_activities" ON public.organisation_api_key_activities USING btree (organisation_api_key_id);


--
-- Name: idx_qc_on_name_only_unlocked; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_qc_on_name_only_unlocked ON public.queue_classic_jobs USING btree (q_name, id) WHERE (locked_at IS NULL);


--
-- Name: idx_qc_on_scheduled_at_only_unlocked; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_qc_on_scheduled_at_only_unlocked ON public.queue_classic_jobs USING btree (scheduled_at, id) WHERE (locked_at IS NULL);


--
-- Name: index_agents_on_region_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_agents_on_region_id ON public.agents USING btree (region_id);


--
-- Name: index_authem_sessions_on_expires_at_and_token; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_authem_sessions_on_expires_at_and_token ON public.authem_sessions USING btree (expires_at, token);


--
-- Name: index_authem_sessions_subject; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_authem_sessions_subject ON public.authem_sessions USING btree (expires_at, subject_type, subject_id);


--
-- Name: index_endpoints_on_slug_and_site_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_endpoints_on_slug_and_site_id ON public.endpoints USING btree (slug, site_id);


--
-- Name: index_friendly_id_slugs_on_slug_and_sluggable_type_and_scope; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_friendly_id_slugs_on_slug_and_sluggable_type_and_scope ON public.friendly_id_slugs USING btree (slug, sluggable_type, scope);


--
-- Name: index_friendly_id_slugs_on_sluggable_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_friendly_id_slugs_on_sluggable_id ON public.friendly_id_slugs USING btree (sluggable_id);


--
-- Name: index_friendly_id_slugs_on_sluggable_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_friendly_id_slugs_on_sluggable_type ON public.friendly_id_slugs USING btree (sluggable_type);


--
-- Name: index_measurements_on_run_result_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_measurements_on_run_result_id ON public.measurements USING btree (run_result_id);


--
-- Name: index_memberships_on_user_id_and_organisation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_memberships_on_user_id_and_organisation_id ON public.memberships USING btree (user_id, organisation_id);


--
-- Name: index_notifications_on_events; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notifications_on_events ON public.notifications USING btree (events);


--
-- Name: index_organisation_test_usage_on_site_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_organisation_test_usage_on_site_id ON public.organisation_test_usage USING btree (site_id);


--
-- Name: index_organisation_test_usage_on_standalone_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_organisation_test_usage_on_standalone_run_id ON public.organisation_test_usage USING btree (standalone_run_id);


--
-- Name: index_organisations_on_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_organisations_on_slug ON public.organisations USING btree (slug);


--
-- Name: index_run_results_on_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_run_results_on_run_id ON public.run_results USING btree (run_id);


--
-- Name: index_run_results_on_standalone_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_run_results_on_standalone_run_id ON public.run_results USING btree (standalone_run_id);


--
-- Name: index_runs_on_id_and_endpoint_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_runs_on_id_and_endpoint_id ON public.runs USING btree (id, endpoint_id);


--
-- Name: index_runs_on_received_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_runs_on_received_at ON public.runs USING btree (received_at);


--
-- Name: index_runs_on_run_profile_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_runs_on_run_profile_id ON public.runs USING btree (run_profile_id);


--
-- Name: index_runs_on_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_runs_on_status ON public.runs USING btree (status);


--
-- Name: index_sites_on_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_sites_on_slug ON public.sites USING btree (slug);


--
-- Name: index_standalone_runs_on_organisation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_standalone_runs_on_organisation_id ON public.standalone_runs USING btree (organisation_id);


--
-- Name: index_standalone_runs_on_region_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_standalone_runs_on_region_id ON public.standalone_runs USING btree (region_id);


--
-- Name: index_third_party_domains_on_third_party_product_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_third_party_domains_on_third_party_product_id ON public.third_party_domains USING btree (third_party_product_id);


--
-- Name: index_third_party_domains_on_tld_hash_and_prefix; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_third_party_domains_on_tld_hash_and_prefix ON public.third_party_domains USING btree (tld_hash, prefix);


--
-- Name: index_thirty_day_timeseries_on_checkpoint_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_thirty_day_timeseries_on_checkpoint_id ON public.thirty_day_timeseries USING btree (checkpoint_id);


--
-- Name: index_thirty_day_timeseries_on_endpoint_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_thirty_day_timeseries_on_endpoint_id ON public.thirty_day_timeseries USING btree (endpoint_id);


--
-- Name: index_thirty_day_timeseries_on_endpoint_id_and_site_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_thirty_day_timeseries_on_endpoint_id_and_site_id ON public.thirty_day_timeseries USING btree (endpoint_id, site_id);


--
-- Name: index_thirty_day_timeseries_on_run_profile_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_thirty_day_timeseries_on_run_profile_id ON public.thirty_day_timeseries USING btree (run_profile_id);


--
-- Name: index_thirty_day_timeseries_on_site_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_thirty_day_timeseries_on_site_id ON public.thirty_day_timeseries USING btree (site_id);


--
-- Name: unique_schema_migrations; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX unique_schema_migrations ON public.schema_migrations USING btree (version);


--
-- Name: api_key_created_at; Type: INDEX; Schema: raw; Owner: -
--

CREATE INDEX api_key_created_at ON raw.page_view_events USING btree (api_key, created_at);


--
-- Name: queue_classic_jobs queue_classic_notify; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER queue_classic_notify AFTER INSERT ON public.queue_classic_jobs FOR EACH ROW EXECUTE PROCEDURE public.queue_classic_notify();


--
-- Name: runs site_test_usage; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER site_test_usage AFTER UPDATE ON public.runs FOR EACH ROW WHEN (((new.status)::text = 'completed'::text)) EXECUTE PROCEDURE public.run_insert_into_organisation_test_usage();


--
-- Name: standalone_runs standalone_test_usage; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER standalone_test_usage AFTER UPDATE ON public.standalone_runs FOR EACH ROW WHEN ((new.status = 'completed'::public.standalone_run_status)) EXECUTE PROCEDURE public.standalone_run_insert_into_organisation_test_usage();


--
-- Name: runs thirty_day_timeseries_copy; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER thirty_day_timeseries_copy AFTER UPDATE ON public.runs FOR EACH ROW WHEN (((new.status)::text = 'completed'::text)) EXECUTE PROCEDURE public.insert_into_30_day_metrics();


--
-- Name: collaborations collaborations_site_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.collaborations
    ADD CONSTRAINT collaborations_site_id_fk FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE CASCADE;


--
-- Name: collaborations collaborations_user_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.collaborations
    ADD CONSTRAINT collaborations_user_id_fk FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: authentication_configs fk_authentication_configs_site_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.authentication_configs
    ADD CONSTRAINT fk_authentication_configs_site_id FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE CASCADE;


--
-- Name: billing_infos fk_billing_infos_organisation_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_infos
    ADD CONSTRAINT fk_billing_infos_organisation_id FOREIGN KEY (organisation_id) REFERENCES public.organisations(id) ON DELETE CASCADE;


--
-- Name: checkpoints fk_checkpoints_site_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.checkpoints
    ADD CONSTRAINT fk_checkpoints_site_id FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE CASCADE;


--
-- Name: collaborations fk_collaborations_site_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.collaborations
    ADD CONSTRAINT fk_collaborations_site_id FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE CASCADE;


--
-- Name: collaborations fk_collaborations_user_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.collaborations
    ADD CONSTRAINT fk_collaborations_user_id FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: endpoints fk_endpoints_site_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.endpoints
    ADD CONSTRAINT fk_endpoints_site_id FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE CASCADE;


--
-- Name: event_subscriptions fk_event_subscriptions_membership_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.event_subscriptions
    ADD CONSTRAINT fk_event_subscriptions_membership_id FOREIGN KEY (membership_id) REFERENCES public.memberships(id) ON DELETE CASCADE;


--
-- Name: event_subscriptions fk_event_subscriptions_site_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.event_subscriptions
    ADD CONSTRAINT fk_event_subscriptions_site_id FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE CASCADE;


--
-- Name: events fk_events_site_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events
    ADD CONSTRAINT fk_events_site_id FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE CASCADE;


--
-- Name: extracts fk_extracts_run_result_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.extracts
    ADD CONSTRAINT fk_extracts_run_result_id FOREIGN KEY (run_result_id) REFERENCES public.run_results(id) ON DELETE CASCADE;


--
-- Name: invoices fk_invoices_organisation_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoices
    ADD CONSTRAINT fk_invoices_organisation_id FOREIGN KEY (organisation_id) REFERENCES public.organisations(id) ON DELETE CASCADE;


--
-- Name: measurements fk_measurements_run_result_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.measurements
    ADD CONSTRAINT fk_measurements_run_result_id FOREIGN KEY (run_result_id) REFERENCES public.run_results(id) ON DELETE CASCADE;


--
-- Name: memberships fk_memberships_organisation_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT fk_memberships_organisation_id FOREIGN KEY (organisation_id) REFERENCES public.organisations(id) ON DELETE CASCADE;


--
-- Name: metric_budgets fk_metric_budgets_site_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.metric_budgets
    ADD CONSTRAINT fk_metric_budgets_site_id FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE CASCADE;


--
-- Name: notifications fk_notifications_site_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT fk_notifications_site_id FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE CASCADE;


--
-- Name: organisations fk_organisations_user_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organisations
    ADD CONSTRAINT fk_organisations_user_id FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: preview_images fk_preview_images_endpoint_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.preview_images
    ADD CONSTRAINT fk_preview_images_endpoint_id FOREIGN KEY (endpoint_id) REFERENCES public.endpoints(id) ON DELETE CASCADE;


--
-- Name: preview_images fk_preview_images_site_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.preview_images
    ADD CONSTRAINT fk_preview_images_site_id FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE CASCADE;


--
-- Name: standalone_runs fk_rails_08fd317ca0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.standalone_runs
    ADD CONSTRAINT fk_rails_08fd317ca0 FOREIGN KEY (organisation_id) REFERENCES public.organisations(id);


--
-- Name: events fk_rails_0cb5590091; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events
    ADD CONSTRAINT fk_rails_0cb5590091 FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: thirty_day_timeseries fk_rails_22c3f5540d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.thirty_day_timeseries
    ADD CONSTRAINT fk_rails_22c3f5540d FOREIGN KEY (checkpoint_id) REFERENCES public.checkpoints(id) ON DELETE CASCADE;


--
-- Name: thirty_day_timeseries fk_rails_49cea9df80; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.thirty_day_timeseries
    ADD CONSTRAINT fk_rails_49cea9df80 FOREIGN KEY (run_profile_id) REFERENCES public.run_profiles(id) ON DELETE CASCADE;


--
-- Name: metric_budgets fk_rails_50efa12b01; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.metric_budgets
    ADD CONSTRAINT fk_rails_50efa12b01 FOREIGN KEY (metric_budget_id) REFERENCES public.metric_budgets(id) ON DELETE CASCADE;


--
-- Name: organisation_api_key_activities fk_rails_52e0a8f2c9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organisation_api_key_activities
    ADD CONSTRAINT fk_rails_52e0a8f2c9 FOREIGN KEY (organisation_api_key_id) REFERENCES public.organisation_api_keys(id) ON DELETE CASCADE;


--
-- Name: events fk_rails_60354298e7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events
    ADD CONSTRAINT fk_rails_60354298e7 FOREIGN KEY (checkpoint_id) REFERENCES public.checkpoints(id) ON DELETE CASCADE;


--
-- Name: organisation_test_usage fk_rails_662ad59e2e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organisation_test_usage
    ADD CONSTRAINT fk_rails_662ad59e2e FOREIGN KEY (organisation_id) REFERENCES public.organisations(id) ON DELETE CASCADE;


--
-- Name: metric_budgets fk_rails_6cf0a12814; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.metric_budgets
    ADD CONSTRAINT fk_rails_6cf0a12814 FOREIGN KEY (endpoint_id) REFERENCES public.endpoints(id) ON DELETE CASCADE;


--
-- Name: standalone_runs fk_rails_6f39b62e38; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.standalone_runs
    ADD CONSTRAINT fk_rails_6f39b62e38 FOREIGN KEY (region_id) REFERENCES public.regions(id) ON DELETE CASCADE;


--
-- Name: thirty_day_timeseries fk_rails_795a70e225; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.thirty_day_timeseries
    ADD CONSTRAINT fk_rails_795a70e225 FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE CASCADE;


--
-- Name: email_deliveries fk_rails_9263875cd4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_deliveries
    ADD CONSTRAINT fk_rails_9263875cd4 FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: memberships fk_rails_99326fb65d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT fk_rails_99326fb65d FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: run_results fk_rails_a18b489bb0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.run_results
    ADD CONSTRAINT fk_rails_a18b489bb0 FOREIGN KEY (standalone_run_id) REFERENCES public.standalone_runs(id) ON DELETE CASCADE;


--
-- Name: run_profiles fk_rails_c61d26dac6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.run_profiles
    ADD CONSTRAINT fk_rails_c61d26dac6 FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE CASCADE;


--
-- Name: run_profile_cookies fk_rails_cf0de706e9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.run_profile_cookies
    ADD CONSTRAINT fk_rails_cf0de706e9 FOREIGN KEY (run_profile_id) REFERENCES public.run_profiles(id) ON DELETE CASCADE;


--
-- Name: runs fk_rails_d0e68daa50; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.runs
    ADD CONSTRAINT fk_rails_d0e68daa50 FOREIGN KEY (run_profile_id) REFERENCES public.run_profiles(id) ON DELETE CASCADE;


--
-- Name: third_party_domains fk_rails_d6abdd30c5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.third_party_domains
    ADD CONSTRAINT fk_rails_d6abdd30c5 FOREIGN KEY (third_party_product_id) REFERENCES public.third_party_products(id) ON DELETE CASCADE;


--
-- Name: metric_budgets fk_rails_d97b7146db; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.metric_budgets
    ADD CONSTRAINT fk_rails_d97b7146db FOREIGN KEY (run_profile_id) REFERENCES public.run_profiles(id) ON DELETE CASCADE;


--
-- Name: thirty_day_timeseries fk_rails_e1f227e9cd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.thirty_day_timeseries
    ADD CONSTRAINT fk_rails_e1f227e9cd FOREIGN KEY (endpoint_id) REFERENCES public.endpoints(id) ON DELETE CASCADE;


--
-- Name: preview_images fk_rails_e85388ea8b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.preview_images
    ADD CONSTRAINT fk_rails_e85388ea8b FOREIGN KEY (run_profile_id) REFERENCES public.run_profiles(id) ON DELETE CASCADE;


--
-- Name: organisation_api_keys fk_rails_f24d1d429a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organisation_api_keys
    ADD CONSTRAINT fk_rails_f24d1d429a FOREIGN KEY (organisation_id) REFERENCES public.organisations(id) ON DELETE CASCADE;


--
-- Name: run_results fk_run_results_run_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.run_results
    ADD CONSTRAINT fk_run_results_run_id FOREIGN KEY (run_id) REFERENCES public.runs(id) ON DELETE CASCADE;


--
-- Name: runs fk_runs_checkpoint_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.runs
    ADD CONSTRAINT fk_runs_checkpoint_id FOREIGN KEY (checkpoint_id) REFERENCES public.checkpoints(id) ON DELETE CASCADE;


--
-- Name: runs fk_runs_endpoint_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.runs
    ADD CONSTRAINT fk_runs_endpoint_id FOREIGN KEY (endpoint_id) REFERENCES public.endpoints(id) ON DELETE CASCADE;


--
-- Name: site_api_keys fk_site_api_keys_site_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.site_api_keys
    ADD CONSTRAINT fk_site_api_keys_site_id FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE CASCADE;


--
-- Name: sites fk_sites_organisation_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sites
    ADD CONSTRAINT fk_sites_organisation_id FOREIGN KEY (organisation_id) REFERENCES public.organisations(id) ON DELETE CASCADE;


--
-- Name: subscriptions fk_subscriptions_organisation_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT fk_subscriptions_organisation_id FOREIGN KEY (organisation_id) REFERENCES public.organisations(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20130811062517'),
('20130811063449'),
('20131111112429'),
('20131111113350'),
('20131115073056'),
('20131115075207'),
('20131116011615'),
('20131130234909'),
('20131204124047'),
('20131213071412'),
('20131219071238'),
('20131219101114'),
('20140101111608'),
('20140101122724'),
('20140111005041'),
('20140113114423'),
('20140114041048'),
('20140116111703'),
('20140305014123'),
('20140305031318'),
('20140312031704'),
('20140317024248'),
('20140317024249'),
('20140317113745'),
('20140317123418'),
('20140319034805'),
('20140321094352'),
('20140321101615'),
('20140321130519'),
('20140323113544'),
('20140324112033'),
('20140404090357'),
('20140414112958'),
('20140504083035'),
('20140504084444'),
('20140509062719'),
('20140626065418'),
('20140810074919'),
('20140909144119'),
('20140922060434'),
('20140923213755'),
('20140924223328'),
('20140926021210'),
('20141010102156'),
('20141011064929'),
('20141012091927'),
('20141018223015'),
('20141020113631'),
('20141021202837'),
('20141022110420'),
('20141024004707'),
('20141026094015'),
('20141028114110'),
('20141108124215'),
('20141109121606'),
('20141117064203'),
('20141204050217'),
('20141224080121'),
('20150111045102'),
('20150117035823'),
('20150121044252'),
('20150125011945'),
('20150126020338'),
('20150126091901'),
('20150213235104'),
('20150214061312'),
('20150214095157'),
('20150424120604'),
('20150511192518'),
('20150715051625'),
('20150715052925'),
('20150810183455'),
('20150828113023'),
('20150906141103'),
('20150918074313'),
('20151010104519'),
('20151023095804'),
('20151023124236'),
('20151031153036'),
('20151101133825'),
('20151105063308'),
('20151109205019'),
('20151115125341'),
('20151115130337'),
('20151116190002'),
('20160104234033'),
('20160417055539'),
('20160423082955'),
('20160519113408'),
('20160519113409'),
('20160524211445'),
('20160601042257'),
('20160707102657'),
('20160805033040'),
('20160921105411'),
('20170112021227'),
('20170124044141'),
('20170205060755'),
('20170205062500'),
('20170208115826'),
('20170306052746'),
('20170308234611'),
('20170313045958'),
('20170327232744'),
('20170707104705'),
('20170830144233'),
('20170917095358'),
('20170918024554'),
('20171006021347'),
('20171013224444'),
('20171115053331'),
('20171116055131'),
('20171120125904'),
('20171128235834'),
('20171213040805'),
('20171219233755'),
('20171222054709'),
('20171223025441'),
('20171227040513'),
('20171229014642'),
('20180104004432'),
('20180104023257'),
('20180118055215'),
('20180209050057'),
('20180223002055'),
('20180406044038'),
('20180413235606'),
('20180425004746'),
('20180510022023'),
('20180515010331'),
('20180605181001'),
('20180613160624'),
('20180615202208'),
('20180702064424');
