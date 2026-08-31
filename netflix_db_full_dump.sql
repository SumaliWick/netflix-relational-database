--
-- PostgreSQL database dump
--

\restrict l2TIC8wSzKnmQgvHnyDBcrkjMkjxDB9qNq9DlMn6E8WC8HKKqypTE0oEm4fEw7a

-- Dumped from database version 16.13 (Ubuntu 16.13-0ubuntu0.24.04.1)
-- Dumped by pg_dump version 16.13 (Ubuntu 16.13-0ubuntu0.24.04.1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

-- *not* creating schema, since initdb creates it


--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA public IS '';


--
-- Name: fn_accountprofilecount(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_accountprofilecount(p_account_id integer) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_count FROM Profile WHERE AccountID = p_account_id;
    RETURN v_count;
END;
$$;


--
-- Name: fn_isageappropriate(integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_isageappropriate(p_profile_id integer, p_title_id integer) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_profile_level VARCHAR(20);
    v_title_rating  VARCHAR(10);
    v_required_level VARCHAR(20);
    v_rank_map JSONB := '{"Little Kids":1, "Older Kids":2, "Teens":3, "Adults":4}';
BEGIN
    SELECT MaturityLevel INTO v_profile_level FROM Profile WHERE ProfileID = p_profile_id;
    SELECT MaturityRating INTO v_title_rating FROM Title WHERE TitleID = p_title_id;
    v_required_level := fn_MinimumMaturityLevel(v_title_rating);

    RETURN (v_rank_map->>v_profile_level)::INT >= (v_rank_map->>v_required_level)::INT;
END;
$$;


--
-- Name: fn_minimummaturitylevel(character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_minimummaturitylevel(p_rating character varying) RETURNS character varying
    LANGUAGE plpgsql IMMUTABLE
    AS $$
BEGIN
    RETURN CASE p_rating
        WHEN 'TV-Y7' THEN 'Little Kids'
        WHEN 'PG'     THEN 'Older Kids'
        WHEN 'PG-13'  THEN 'Teens'
        WHEN 'TV-14'  THEN 'Teens'
        WHEN 'R'      THEN 'Adults'
        WHEN 'TV-MA'  THEN 'Adults'
        ELSE 'Adults'   -- unrecognized ratings default to the strictest level
    END;
END;
$$;


--
-- Name: fn_titleaverageratingscore(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_titleaverageratingscore(p_title_id integer) RETURNS numeric
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_score NUMERIC;
BEGIN
    SELECT ROUND(AVG(
        CASE ThumbsRating
            WHEN 'Two Thumbs Up' THEN 2
            WHEN 'Thumbs Up'      THEN 1
            WHEN 'Thumbs Down'    THEN -1
        END
    )::numeric, 2)
    INTO v_score
    FROM Rating
    WHERE TitleID = p_title_id;

    RETURN COALESCE(v_score, 0);
END;
$$;


--
-- Name: sp_addprofile(integer, character varying, boolean, character varying); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.sp_addprofile(IN p_account_id integer, IN p_profile_name character varying, IN p_is_kids boolean DEFAULT false, IN p_avatar_icon character varying DEFAULT NULL::character varying)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_maturity   VARCHAR(20);
    v_avatar     VARCHAR(100);
    v_new_count  INTEGER;
BEGIN
    IF fn_AccountProfileCount(p_account_id) >= 5 THEN
        RAISE EXCEPTION 'sp_AddProfile: Account % already has 5 profiles — remove one before adding another', p_account_id;
    END IF;

    v_maturity := CASE WHEN p_is_kids THEN 'Older Kids' ELSE 'Adults' END;
    v_avatar   := COALESCE(p_avatar_icon, 'avatar_default.png');

    INSERT INTO Profile (AccountID, ProfileName, AvatarIcon, IsKidsProfile, MaturityLevel)
    VALUES (p_account_id, p_profile_name, v_avatar, p_is_kids, v_maturity);

    v_new_count := fn_AccountProfileCount(p_account_id);
    RAISE NOTICE 'Added profile "%" to Account % (now % of 5 profiles used)', p_profile_name, p_account_id, v_new_count;
END;
$$;


--
-- Name: sp_recordwatchprogress(integer, integer, integer, integer, character varying); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.sp_recordwatchprogress(IN p_profile_id integer, IN p_title_id integer, IN p_episode_id integer, IN p_progress_minutes integer, IN p_device_type character varying DEFAULT 'Smart TV'::character varying)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_runtime       INTEGER;
    v_pct           NUMERIC(5,2);
    v_completed     BOOLEAN;
    v_existing_id   INTEGER;
BEGIN
    IF p_episode_id IS NULL THEN
        SELECT RuntimeMinutes INTO v_runtime FROM Title WHERE TitleID = p_title_id;
    ELSE
        SELECT RuntimeMinutes INTO v_runtime FROM Episode WHERE EpisodeID = p_episode_id;
    END IF;

    v_pct := LEAST(100, ROUND(p_progress_minutes::numeric / NULLIF(v_runtime, 0) * 100, 2));
    v_completed := v_pct >= 90;

    SELECT WatchID INTO v_existing_id
    FROM WatchHistory
    WHERE ProfileID = p_profile_id AND TitleID = p_title_id
      AND EpisodeID IS NOT DISTINCT FROM p_episode_id
      AND WatchDate::date = CURRENT_DATE
    ORDER BY WatchDate DESC
    LIMIT 1;

    IF v_existing_id IS NOT NULL THEN
        UPDATE WatchHistory
        SET ProgressMinutes = p_progress_minutes,
            PercentComplete = v_pct,
            IsCompleted = v_completed,
            WatchDate = CURRENT_TIMESTAMP,
            DeviceType = p_device_type
        WHERE WatchID = v_existing_id;
        RAISE NOTICE 'Updated existing WatchHistory row % — % percent complete (completed=%)', v_existing_id, v_pct, v_completed;
    ELSE
        INSERT INTO WatchHistory (ProfileID, TitleID, EpisodeID, ProgressMinutes, PercentComplete, DeviceType, IsCompleted)
        VALUES (p_profile_id, p_title_id, p_episode_id, p_progress_minutes, v_pct, p_device_type, v_completed);
        RAISE NOTICE 'Inserted new WatchHistory row — % percent complete (completed=%)', v_pct, v_completed;
    END IF;
END;
$$;


--
-- Name: sp_upgradeplan(integer, character varying); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.sp_upgradeplan(IN p_account_id integer, IN p_new_plan_name character varying)
    LANGUAGE plpgsql
    AS $_$
DECLARE
    v_old_price NUMERIC(6,2);
    v_new_price NUMERIC(6,2);
    v_new_plan_id INTEGER;
BEGIN
    SELECT PlanID, MonthlyPrice INTO v_new_plan_id, v_new_price
    FROM Plan WHERE PlanName = p_new_plan_name;

    IF v_new_plan_id IS NULL THEN
        RAISE EXCEPTION 'sp_UpgradePlan: no plan named "%" exists', p_new_plan_name;
    END IF;

    SELECT pl.MonthlyPrice INTO v_old_price
    FROM Account a JOIN Plan pl ON pl.PlanID = a.PlanID
    WHERE a.AccountID = p_account_id;

    UPDATE Account SET PlanID = v_new_plan_id WHERE AccountID = p_account_id;

    RAISE NOTICE 'Account % moved from $%/mo to $%/mo (%)',
        p_account_id, v_old_price, v_new_price,
        CASE WHEN v_new_price > v_old_price THEN 'upgrade' WHEN v_new_price < v_old_price THEN 'downgrade' ELSE 'lateral move' END;
END;
$_$;


--
-- Name: trgfn_enforcekidsmaturity(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trgfn_enforcekidsmaturity() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NOT fn_IsAgeAppropriate(NEW.ProfileID, NEW.TitleID) THEN
        RAISE EXCEPTION 'ProfileID % is not permitted to watch TitleID % (maturity rating exceeds profile''s allowed level)',
            NEW.ProfileID, NEW.TitleID;
    END IF;
    RETURN NEW;
END;
$$;


--
-- Name: trgfn_limitprofilesperaccount(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trgfn_limitprofilesperaccount() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF fn_AccountProfileCount(NEW.AccountID) >= 5 THEN
        RAISE EXCEPTION 'Account % already has the maximum of 5 profiles', NEW.AccountID;
    END IF;
    RETURN NEW;
END;
$$;


--
-- Name: trgfn_maintainepisodecount(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trgfn_maintainepisodecount() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_season_id INTEGER := COALESCE(NEW.SeasonID, OLD.SeasonID);
BEGIN
    UPDATE Season
    SET EpisodeCount = (SELECT COUNT(*) FROM Episode WHERE SeasonID = v_season_id)
    WHERE SeasonID = v_season_id;
    RETURN NULL;
END;
$$;


--
-- Name: trgfn_seasononlyforseries(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trgfn_seasononlyforseries() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_type VARCHAR(10);
BEGIN
    SELECT TitleType INTO v_type FROM Title WHERE TitleID = NEW.TitleID;
    IF v_type IS DISTINCT FROM 'Series' THEN
        RAISE EXCEPTION 'Cannot add a Season to TitleID % because it is a % , not a Series', NEW.TitleID, v_type;
    END IF;
    RETURN NEW;
END;
$$;


--
-- Name: trgfn_watchhistoryepisodeconsistency(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trgfn_watchhistoryepisodeconsistency() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_type VARCHAR(10);
    v_episode_title_id INTEGER;
BEGIN
    SELECT TitleType INTO v_type FROM Title WHERE TitleID = NEW.TitleID;

    IF v_type = 'Movie' AND NEW.EpisodeID IS NOT NULL THEN
        RAISE EXCEPTION 'TitleID % is a Movie; WatchHistory.EpisodeID must be NULL', NEW.TitleID;
    END IF;

    IF v_type = 'Series' AND NEW.EpisodeID IS NULL THEN
        RAISE EXCEPTION 'TitleID % is a Series; WatchHistory.EpisodeID must be provided', NEW.TitleID;
    END IF;

    IF NEW.EpisodeID IS NOT NULL THEN
        SELECT s.TitleID INTO v_episode_title_id
        FROM Episode e JOIN Season s ON s.SeasonID = e.SeasonID
        WHERE e.EpisodeID = NEW.EpisodeID;

        IF v_episode_title_id IS DISTINCT FROM NEW.TitleID THEN
            RAISE EXCEPTION 'EpisodeID % does not belong to TitleID %', NEW.EpisodeID, NEW.TitleID;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: account; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.account (
    accountid integer NOT NULL,
    email character varying(100) NOT NULL,
    passwordhash character varying(255) NOT NULL,
    country character varying(56) NOT NULL,
    signupdate date DEFAULT CURRENT_DATE NOT NULL,
    paymentmethod character varying(30) NOT NULL,
    accountstatus character varying(20) DEFAULT 'Active'::character varying NOT NULL,
    planid integer NOT NULL,
    CONSTRAINT account_accountstatus_check CHECK (((accountstatus)::text = ANY ((ARRAY['Active'::character varying, 'Suspended'::character varying, 'Cancelled'::character varying])::text[])))
);


--
-- Name: account_accountid_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.account_accountid_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: account_accountid_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.account_accountid_seq OWNED BY public.account.accountid;


--
-- Name: credit; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.credit (
    titleid integer NOT NULL,
    personid integer NOT NULL,
    roletype character varying(20) NOT NULL,
    charactername character varying(100),
    CONSTRAINT chk_character_name CHECK (((((roletype)::text = 'Actor'::text) AND (charactername IS NOT NULL)) OR (((roletype)::text <> 'Actor'::text) AND (charactername IS NULL)))),
    CONSTRAINT credit_roletype_check CHECK (((roletype)::text = ANY ((ARRAY['Actor'::character varying, 'Director'::character varying, 'Writer'::character varying, 'Producer'::character varying])::text[])))
);


--
-- Name: episode; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.episode (
    episodeid integer NOT NULL,
    seasonid integer NOT NULL,
    episodenumber smallint NOT NULL,
    episodetitle character varying(150) NOT NULL,
    runtimeminutes smallint NOT NULL,
    episodereleasedate date NOT NULL,
    CONSTRAINT episode_episodenumber_check CHECK ((episodenumber > 0)),
    CONSTRAINT episode_runtimeminutes_check CHECK ((runtimeminutes > 0))
);


--
-- Name: episode_episodeid_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.episode_episodeid_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: episode_episodeid_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.episode_episodeid_seq OWNED BY public.episode.episodeid;


--
-- Name: genre; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.genre (
    genreid integer NOT NULL,
    genrename character varying(50) NOT NULL,
    genrecategory character varying(50) NOT NULL
);


--
-- Name: genre_genreid_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.genre_genreid_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: genre_genreid_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.genre_genreid_seq OWNED BY public.genre.genreid;


--
-- Name: mylist; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.mylist (
    profileid integer NOT NULL,
    titleid integer NOT NULL,
    dateadded date DEFAULT CURRENT_DATE NOT NULL
);


--
-- Name: person; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.person (
    personid integer NOT NULL,
    fullname character varying(100) NOT NULL,
    dateofbirth date,
    nationality character varying(56),
    biography text
);


--
-- Name: person_personid_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.person_personid_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: person_personid_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.person_personid_seq OWNED BY public.person.personid;


--
-- Name: plan; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.plan (
    planid integer NOT NULL,
    planname character varying(40) NOT NULL,
    monthlyprice numeric(6,2) NOT NULL,
    videoquality character varying(20) NOT NULL,
    maxsimultaneousstreams smallint NOT NULL,
    maxdownloaddevices smallint NOT NULL,
    includesads boolean DEFAULT false NOT NULL,
    CONSTRAINT plan_maxdownloaddevices_check CHECK ((maxdownloaddevices >= 0)),
    CONSTRAINT plan_maxsimultaneousstreams_check CHECK ((maxsimultaneousstreams > 0)),
    CONSTRAINT plan_monthlyprice_check CHECK ((monthlyprice >= (0)::numeric))
);


--
-- Name: plan_planid_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.plan_planid_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: plan_planid_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.plan_planid_seq OWNED BY public.plan.planid;


--
-- Name: profile; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.profile (
    profileid integer NOT NULL,
    accountid integer NOT NULL,
    profilename character varying(50) NOT NULL,
    avataricon character varying(100),
    iskidsprofile boolean DEFAULT false NOT NULL,
    maturitylevel character varying(20) DEFAULT 'Adults'::character varying NOT NULL,
    preferredlanguage character varying(30) DEFAULT 'English'::character varying NOT NULL,
    autoplaynextepisode boolean DEFAULT true NOT NULL,
    CONSTRAINT profile_maturitylevel_check CHECK (((maturitylevel)::text = ANY ((ARRAY['Little Kids'::character varying, 'Older Kids'::character varying, 'Teens'::character varying, 'Adults'::character varying])::text[])))
);


--
-- Name: profile_profileid_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.profile_profileid_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: profile_profileid_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.profile_profileid_seq OWNED BY public.profile.profileid;


--
-- Name: rating; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rating (
    profileid integer NOT NULL,
    titleid integer NOT NULL,
    thumbsrating character varying(20) NOT NULL,
    ratingdate date DEFAULT CURRENT_DATE NOT NULL,
    CONSTRAINT rating_thumbsrating_check CHECK (((thumbsrating)::text = ANY ((ARRAY['Thumbs Down'::character varying, 'Thumbs Up'::character varying, 'Two Thumbs Up'::character varying])::text[])))
);


--
-- Name: season; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.season (
    seasonid integer NOT NULL,
    titleid integer NOT NULL,
    seasonnumber smallint NOT NULL,
    seasonreleaseyear smallint NOT NULL,
    episodecount smallint DEFAULT 0 NOT NULL,
    CONSTRAINT season_episodecount_check CHECK ((episodecount >= 0)),
    CONSTRAINT season_seasonnumber_check CHECK ((seasonnumber > 0))
);


--
-- Name: season_seasonid_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.season_seasonid_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: season_seasonid_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.season_seasonid_seq OWNED BY public.season.seasonid;


--
-- Name: title; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.title (
    titleid integer NOT NULL,
    titlename character varying(150) NOT NULL,
    titletype character varying(10) NOT NULL,
    releaseyear smallint NOT NULL,
    synopsis text,
    maturityrating character varying(10) NOT NULL,
    runtimeminutes smallint,
    originallanguage character varying(30) DEFAULT 'English'::character varying NOT NULL,
    dateadded date DEFAULT CURRENT_DATE NOT NULL,
    isnetflixoriginal boolean DEFAULT false NOT NULL,
    CONSTRAINT chk_movie_runtime CHECK (((((titletype)::text = 'Movie'::text) AND (runtimeminutes IS NOT NULL)) OR ((titletype)::text = 'Series'::text))),
    CONSTRAINT title_releaseyear_check CHECK (((releaseyear >= 1900) AND (releaseyear <= 2100))),
    CONSTRAINT title_runtimeminutes_check CHECK (((runtimeminutes IS NULL) OR (runtimeminutes > 0))),
    CONSTRAINT title_titletype_check CHECK (((titletype)::text = ANY ((ARRAY['Movie'::character varying, 'Series'::character varying])::text[])))
);


--
-- Name: title_titleid_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.title_titleid_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: title_titleid_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.title_titleid_seq OWNED BY public.title.titleid;


--
-- Name: titlegenre; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.titlegenre (
    titleid integer NOT NULL,
    genreid integer NOT NULL
);


--
-- Name: vw_accountbilling; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.vw_accountbilling AS
 SELECT a.accountid,
    a.email,
    a.accountstatus,
    pl.planname,
    pl.monthlyprice,
    pl.videoquality,
    count(pr.profileid) AS profilecount
   FROM ((public.account a
     JOIN public.plan pl ON ((pl.planid = a.planid)))
     LEFT JOIN public.profile pr ON ((pr.accountid = a.accountid)))
  GROUP BY a.accountid, a.email, a.accountstatus, pl.planname, pl.monthlyprice, pl.videoquality;


--
-- Name: watchhistory; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.watchhistory (
    watchid integer NOT NULL,
    profileid integer NOT NULL,
    titleid integer NOT NULL,
    episodeid integer,
    watchdate timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    progressminutes smallint DEFAULT 0 NOT NULL,
    percentcomplete numeric(5,2) DEFAULT 0 NOT NULL,
    devicetype character varying(30) DEFAULT 'Smart TV'::character varying NOT NULL,
    iscompleted boolean DEFAULT false NOT NULL,
    CONSTRAINT watchhistory_percentcomplete_check CHECK (((percentcomplete >= (0)::numeric) AND (percentcomplete <= (100)::numeric))),
    CONSTRAINT watchhistory_progressminutes_check CHECK ((progressminutes >= 0))
);


--
-- Name: vw_continuewatching; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.vw_continuewatching AS
 SELECT DISTINCT ON (wh.profileid, wh.titleid) wh.profileid,
    p.profilename,
    wh.titleid,
    t.titlename,
    t.titletype,
    wh.episodeid,
    e.episodenumber,
    e.episodetitle,
    wh.progressminutes,
    wh.percentcomplete,
    wh.watchdate
   FROM (((public.watchhistory wh
     JOIN public.profile p ON ((p.profileid = wh.profileid)))
     JOIN public.title t ON ((t.titleid = wh.titleid)))
     LEFT JOIN public.episode e ON ((e.episodeid = wh.episodeid)))
  WHERE (wh.iscompleted = false)
  ORDER BY wh.profileid, wh.titleid, wh.watchdate DESC;


--
-- Name: vw_kidssafecatalog; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.vw_kidssafecatalog AS
 SELECT titleid,
    titlename,
    titletype,
    releaseyear,
    maturityrating
   FROM public.title
  WHERE ((maturityrating)::text = ANY ((ARRAY['TV-Y7'::character varying, 'PG'::character varying])::text[]));


--
-- Name: vw_titlecatalog; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.vw_titlecatalog AS
 SELECT t.titleid,
    t.titlename,
    t.titletype,
    t.releaseyear,
    t.maturityrating,
    t.isnetflixoriginal,
    string_agg(DISTINCT (g.genrename)::text, ', '::text ORDER BY (g.genrename)::text) AS genres,
    count(DISTINCT c.personid) FILTER (WHERE ((c.roletype)::text = 'Actor'::text)) AS castsize,
    round(avg(
        CASE r.thumbsrating
            WHEN 'Two Thumbs Up'::text THEN 2
            WHEN 'Thumbs Up'::text THEN 1
            WHEN 'Thumbs Down'::text THEN '-1'::integer
            ELSE NULL::integer
        END), 2) AS avgratingscore,
    count(DISTINCT r.profileid) AS ratingcount
   FROM ((((public.title t
     LEFT JOIN public.titlegenre tg ON ((tg.titleid = t.titleid)))
     LEFT JOIN public.genre g ON ((g.genreid = tg.genreid)))
     LEFT JOIN public.credit c ON ((c.titleid = t.titleid)))
     LEFT JOIN public.rating r ON ((r.titleid = t.titleid)))
  GROUP BY t.titleid, t.titlename, t.titletype, t.releaseyear, t.maturityrating, t.isnetflixoriginal;


--
-- Name: vw_topratedtitles; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.vw_topratedtitles AS
 SELECT t.titleid,
    t.titlename,
    t.titletype,
    count(r.profileid) AS totalratings,
    sum(
        CASE r.thumbsrating
            WHEN 'Two Thumbs Up'::text THEN 2
            WHEN 'Thumbs Up'::text THEN 1
            WHEN 'Thumbs Down'::text THEN '-1'::integer
            ELSE NULL::integer
        END) AS weightedscore,
    round(avg(
        CASE r.thumbsrating
            WHEN 'Two Thumbs Up'::text THEN 2
            WHEN 'Thumbs Up'::text THEN 1
            WHEN 'Thumbs Down'::text THEN '-1'::integer
            ELSE NULL::integer
        END), 2) AS avgscore
   FROM (public.title t
     JOIN public.rating r ON ((r.titleid = t.titleid)))
  GROUP BY t.titleid, t.titlename, t.titletype
  ORDER BY (sum(
        CASE r.thumbsrating
            WHEN 'Two Thumbs Up'::text THEN 2
            WHEN 'Thumbs Up'::text THEN 1
            WHEN 'Thumbs Down'::text THEN '-1'::integer
            ELSE NULL::integer
        END)) DESC;


--
-- Name: watchhistory_watchid_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.watchhistory_watchid_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: watchhistory_watchid_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.watchhistory_watchid_seq OWNED BY public.watchhistory.watchid;


--
-- Name: account accountid; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account ALTER COLUMN accountid SET DEFAULT nextval('public.account_accountid_seq'::regclass);


--
-- Name: episode episodeid; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.episode ALTER COLUMN episodeid SET DEFAULT nextval('public.episode_episodeid_seq'::regclass);


--
-- Name: genre genreid; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.genre ALTER COLUMN genreid SET DEFAULT nextval('public.genre_genreid_seq'::regclass);


--
-- Name: person personid; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.person ALTER COLUMN personid SET DEFAULT nextval('public.person_personid_seq'::regclass);


--
-- Name: plan planid; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plan ALTER COLUMN planid SET DEFAULT nextval('public.plan_planid_seq'::regclass);


--
-- Name: profile profileid; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profile ALTER COLUMN profileid SET DEFAULT nextval('public.profile_profileid_seq'::regclass);


--
-- Name: season seasonid; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.season ALTER COLUMN seasonid SET DEFAULT nextval('public.season_seasonid_seq'::regclass);


--
-- Name: title titleid; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.title ALTER COLUMN titleid SET DEFAULT nextval('public.title_titleid_seq'::regclass);


--
-- Name: watchhistory watchid; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.watchhistory ALTER COLUMN watchid SET DEFAULT nextval('public.watchhistory_watchid_seq'::regclass);


--
-- Data for Name: account; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.account (accountid, email, passwordhash, country, signupdate, paymentmethod, accountstatus, planid) FROM stdin;
1	johnsonjoshua@example.org	586631220c210dc920383e0b33f16b0bed319a612abb68c2f1f822d12a75fb7a	Canada	2023-03-16	Credit Card	Cancelled	9
2	garzaanthony@example.org	358418a37e6ea7e726d8ae8655e1f81632bc9ffb2d756dae3eb22f51015c468b	India	2023-07-07	PayPal	Active	4
3	hoffmanjennifer@example.net	0955d96be0310a3d603e84cca2e887b4116dc837b7e3c71c2607765a216a8f03	Canada	2024-10-16	Debit Card	Active	2
4	lisa02@example.net	23c760a2a63fe3ddbfafc9dfdc23dd46efc18b856351d200d0e84d1212733c41	United States	2024-04-24	Credit Card	Active	8
5	susanrogers@example.org	1452113fe38913414cc44343cc40241620339efa4eef465c3767b2b9bdc3bc77	United States	2024-02-23	Debit Card	Active	18
6	cassandra07@example.net	ac614b00b3d3186e77ba81e15c3c2b8902fe8f5b6b280842db2a3c2079ee83ab	Germany	2023-02-23	PayPal	Active	19
7	arnoldmaria@example.net	7764392e4f8b30c549b46f529966b0f2c0bfd3dccf7606773d10c87561092f4b	Brazil	2026-02-15	Credit Card	Active	14
9	michellejames@example.com	ad5e449e40ef714c5916e24e777676cc642fa9cfe13f6d6e060da4451792fd4e	Australia	2025-02-23	Credit Card	Active	13
10	michael41@example.net	55cda8a3f8b59f6d4826cbeb4ebac601205641af692c259909d20cfcbe4facd8	Canada	2025-02-22	Gift Card Balance	Active	20
11	frankgray@example.net	06b21c08138098ffadc9fcfa075f38a7e9e4372e0d3cb8674dc8a32d352ace05	Brazil	2025-05-09	Credit Card	Cancelled	15
12	megan03@example.org	10ec5a14455d0439147c431f997ad7a4c58d5d7be4e55e994d7d0cc3343c302a	Canada	2025-10-23	Carrier Billing	Active	18
13	clarksherri@example.net	267b88a1460dc7357b9956dca500a2badcdaacaeaac7b1c817d43f7e565cfb0e	Brazil	2023-11-21	Debit Card	Active	19
14	pwilkerson@example.com	f04687a03bf0c0091c961a318ce47002c8184075599a50fcd0e96ddeac8d3226	India	2023-03-21	Credit Card	Active	8
15	julie69@example.com	a9340dc4cd73ee38fd8662c03f6ddd648240c93c6fbe58eac215e15c01f51495	Brazil	2024-01-28	Credit Card	Active	4
16	williamdavis@example.org	ac490cb8c6b4f3a25dee36e24553029663c190369fbaa8a23e77acd6c1e55417	Germany	2026-01-11	Gift Card Balance	Active	12
17	laurahenderson@example.org	338722e96dad3aae7568873eb3b6e1944c3f951dc876e9865a963bee68f43e8c	United Kingdom	2024-03-01	Gift Card Balance	Active	7
18	jrice@example.org	a1b00de5fa3db59956b24b19ea44a0352dc995b1d38c94422f06bac88d993d3b	Brazil	2025-04-27	Credit Card	Suspended	6
19	kayla51@example.com	d95e5209182f0cd4a959c0a71879d0ac7a281c48cd8f1a8b135990a337d64a29	India	2024-05-11	PayPal	Active	13
20	teresa28@example.org	c11bd616399ef7de0e3747893d82ead461de93469f54cd1c6e4459cfe0e75f5d	Brazil	2026-01-24	Debit Card	Active	11
21	ericfarmer@example.net	9c0895e16fd25f9b356ade2fe1e09dbc74b0125ce1897238157bce33605cc5ec	United States	2026-05-23	PayPal	Active	11
22	georgetracy@example.org	e76156a6c893af801ad5d533671bc8e5b5ca89739181fe29f07364db39ee2a0e	Germany	2026-04-18	Gift Card Balance	Active	7
23	john39@example.org	83888943ff47fb29cde5f9aab7645d2c17fd3f8a9aee635d3dfc30c8644010d5	Australia	2022-12-29	PayPal	Cancelled	16
24	spenceamanda@example.org	0e72efc71112c315a5d5671acb9153fa67200f9c628138f57262b69c807860c3	Germany	2023-02-28	Carrier Billing	Active	9
25	josephbrennan@example.com	215e10fcd56d8f84a4647be5e5e5033754a80a52fed17351305f5e0fec344867	United Kingdom	2026-06-08	PayPal	Cancelled	18
8	janetwilliams@example.org	ed6b39b3bb6f6a4a5ae207dc60ffa1c6ffa1456cf4b13836ff7e78191164e3d0	Australia	2025-09-07	Gift Card Balance	Active	14
\.


--
-- Data for Name: credit; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.credit (titleid, personid, roletype, charactername) FROM stdin;
1	28	Director	\N
1	17	Actor	Taylor Porter
1	30	Actor	Jamie Bradley
1	20	Actor	Jordan Richardson
1	13	Actor	Riley Scott
2	37	Director	\N
2	23	Actor	Taylor Garcia
2	40	Actor	Casey Berry
2	19	Actor	Alex Sharp
2	38	Actor	Alex Perez
2	2	Actor	Jamie Hicks
3	15	Director	\N
3	39	Actor	Casey Williams
3	23	Actor	Sam Roy
3	13	Actor	Jordan Sanchez
3	40	Actor	Alex Ruiz
4	29	Director	\N
4	3	Actor	Jordan Reyes
4	38	Actor	Casey Hernandez
4	24	Actor	Morgan Velazquez
4	9	Actor	Taylor Mathews
5	13	Director	\N
5	9	Actor	Casey Tran
5	35	Actor	Sam Sloan
5	24	Actor	Casey Yang
6	19	Director	\N
6	22	Actor	Riley Barnes
6	8	Actor	Taylor Morris
6	30	Actor	Morgan Butler
6	5	Actor	Jordan Cortez
6	10	Actor	Taylor Nelson
7	17	Director	\N
7	35	Actor	Jamie Miller
7	8	Actor	Morgan Watson
8	38	Director	\N
8	25	Actor	Jamie Shaw
8	24	Actor	Alex Winters
8	7	Actor	Morgan White
8	15	Actor	Riley Brock
9	30	Director	\N
9	20	Actor	Jordan Jarvis
9	27	Actor	Sam Finley
10	3	Director	\N
10	20	Actor	Jordan Jones
10	32	Actor	Jordan Marshall
11	35	Director	\N
11	9	Actor	Morgan Campbell
11	25	Actor	Taylor Kirk
11	30	Actor	Sam Murphy
12	7	Director	\N
12	32	Actor	Riley Tran
12	27	Actor	Jamie Smith
12	18	Actor	Jamie Gonzalez
12	3	Actor	Riley Elliott
12	24	Actor	Morgan Torres
13	24	Director	\N
13	35	Actor	Alex Dean
13	23	Actor	Taylor Marshall
14	13	Director	\N
14	8	Actor	Alex Vargas
14	30	Actor	Alex Snyder
14	6	Actor	Morgan Barton
14	14	Actor	Riley Gonzalez
15	37	Director	\N
15	14	Actor	Riley Mccullough
15	5	Actor	Riley Hodges
15	36	Actor	Riley Sanchez
16	10	Director	\N
16	39	Actor	Casey Smith
16	1	Actor	Sam Ortiz
16	18	Actor	Jordan Hall
16	9	Actor	Alex Reed
17	1	Director	\N
17	23	Actor	Morgan Franco
17	16	Actor	Alex Wiley
17	38	Actor	Sam Tapia
18	4	Director	\N
18	9	Actor	Jordan Smith
18	27	Actor	Jamie Sandoval
18	34	Actor	Jamie Sweeney
18	8	Actor	Morgan Acosta
19	29	Director	\N
19	33	Actor	Alex Garcia
19	15	Actor	Casey Moreno
20	2	Director	\N
20	4	Actor	Jamie Allen
20	31	Actor	Jamie Vasquez
20	26	Actor	Jordan Brown
20	28	Actor	Jordan Shea
20	7	Actor	Morgan Dawson
21	5	Director	\N
21	9	Actor	Morgan Davis
21	18	Actor	Taylor Morse
21	40	Actor	Casey Merritt
22	33	Director	\N
22	39	Actor	Taylor Meyer
22	28	Actor	Jamie Haynes
22	7	Actor	Riley Watson
22	8	Actor	Taylor Villegas
22	14	Actor	Morgan Miller
23	26	Director	\N
23	27	Actor	Casey Davis
23	7	Actor	Morgan Anderson
23	21	Actor	Sam Wilkins
23	28	Actor	Jamie Jones
23	37	Actor	Jordan Bradley
24	6	Director	\N
24	28	Actor	Morgan Graham
24	7	Actor	Sam Brandt
25	38	Director	\N
25	36	Actor	Jordan Young
25	22	Actor	Taylor Green
26	28	Director	\N
26	4	Actor	Morgan Edwards
26	19	Actor	Jordan Owen
26	39	Actor	Riley Haynes
26	20	Actor	Sam Moss
27	15	Director	\N
27	7	Actor	Casey Stewart
27	23	Actor	Riley Nelson
27	36	Actor	Taylor Jones
27	24	Actor	Alex Harris
27	8	Actor	Casey Chan
28	12	Director	\N
28	18	Actor	Morgan Richards
28	20	Actor	Morgan Moore
29	12	Director	\N
29	10	Actor	Taylor Martin
29	37	Actor	Jordan Owens
30	2	Director	\N
30	6	Actor	Taylor Russell
30	34	Actor	Taylor Herrera
30	14	Actor	Jamie Oconnell
\.


--
-- Data for Name: episode; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.episode (episodeid, seasonid, episodenumber, episodetitle, runtimeminutes, episodereleasedate) FROM stdin;
1	1	1	Pilot	37	2024-09-25
2	1	2	The Reveal	48	2023-09-08
3	1	3	Turning Point	53	2024-01-25
4	1	4	No Way Back	57	2026-02-07
5	1	5	The Descent	37	2026-07-20
6	1	6	New Beginnings	52	2025-03-04
7	1	7	The Chase	53	2025-02-21
8	1	8	Reckoning	50	2025-09-17
9	1	9	Aftermath	23	2024-11-26
10	1	10	Finale	27	2026-03-06
11	2	1	Pilot	40	2025-02-14
12	2	2	The Reveal	36	2023-11-27
13	2	3	Turning Point	47	2023-10-01
14	2	4	No Way Back	37	2025-12-10
15	2	5	The Descent	41	2024-07-14
16	2	6	New Beginnings	45	2024-06-25
17	3	1	Pilot	52	2025-04-09
18	3	2	The Reveal	57	2024-02-29
19	3	3	Turning Point	55	2025-01-11
20	3	4	No Way Back	44	2025-11-19
21	3	5	The Descent	49	2025-12-15
22	3	6	New Beginnings	57	2025-04-22
23	3	7	The Chase	43	2023-12-31
24	3	8	Reckoning	44	2024-01-01
25	4	1	Pilot	51	2025-12-25
26	4	2	The Reveal	39	2026-02-16
27	4	3	Turning Point	41	2024-10-04
28	4	4	No Way Back	38	2026-02-15
29	4	5	The Descent	36	2023-10-13
30	4	6	New Beginnings	29	2025-10-25
31	4	7	The Chase	34	2025-04-18
32	4	8	Reckoning	42	2026-08-17
33	4	9	Aftermath	29	2023-12-19
34	4	10	Finale	56	2026-02-23
35	5	1	Pilot	33	2025-11-29
36	5	2	The Reveal	34	2024-07-20
37	5	3	Turning Point	35	2026-08-28
38	5	4	No Way Back	52	2025-01-02
39	5	5	The Descent	39	2024-09-14
40	5	6	New Beginnings	55	2026-02-09
41	5	7	The Chase	40	2024-12-22
42	5	8	Reckoning	28	2026-08-22
43	5	9	Aftermath	34	2025-12-26
44	6	1	Pilot	40	2024-05-14
45	6	2	The Reveal	36	2026-02-02
46	6	3	Turning Point	45	2025-06-03
47	6	4	No Way Back	33	2024-09-16
48	6	5	The Descent	41	2025-10-15
49	6	6	New Beginnings	22	2025-07-22
50	7	1	Pilot	56	2024-02-26
51	7	2	The Reveal	30	2024-01-28
52	7	3	Turning Point	39	2024-04-11
53	7	4	No Way Back	24	2024-04-11
54	7	5	The Descent	25	2023-11-02
55	7	6	New Beginnings	57	2024-09-16
56	7	7	The Chase	40	2024-07-02
57	7	8	Reckoning	30	2025-04-10
58	7	9	Aftermath	53	2024-08-17
59	7	10	Finale	28	2025-10-08
60	8	1	Pilot	22	2024-07-11
61	8	2	The Reveal	58	2024-06-17
62	8	3	Turning Point	40	2026-03-26
63	8	4	No Way Back	52	2026-08-13
64	8	5	The Descent	52	2025-09-11
65	8	6	New Beginnings	50	2023-12-11
66	8	7	The Chase	43	2026-07-19
67	8	8	Reckoning	33	2026-01-06
68	9	1	Pilot	25	2026-05-31
69	9	2	The Reveal	38	2026-08-20
70	9	3	Turning Point	52	2026-04-05
71	9	4	No Way Back	29	2024-01-15
72	9	5	The Descent	26	2026-04-04
73	9	6	New Beginnings	47	2024-05-28
74	9	7	The Chase	53	2025-10-16
75	9	8	Reckoning	26	2026-02-22
76	9	9	Aftermath	58	2025-12-10
77	10	1	Pilot	25	2025-09-08
78	10	2	The Reveal	31	2025-02-15
79	10	3	Turning Point	31	2025-05-22
80	10	4	No Way Back	58	2024-06-18
81	10	5	The Descent	41	2024-11-24
82	10	6	New Beginnings	27	2025-01-05
83	10	7	The Chase	37	2025-07-23
84	10	8	Reckoning	29	2026-04-19
85	11	1	Pilot	57	2023-12-09
86	11	2	The Reveal	48	2025-03-16
87	11	3	Turning Point	36	2024-06-28
88	11	4	No Way Back	55	2026-06-20
89	11	5	The Descent	46	2024-10-06
90	11	6	New Beginnings	50	2026-07-05
91	11	7	The Chase	50	2024-08-21
92	12	1	Pilot	41	2023-08-31
93	12	2	The Reveal	49	2025-12-24
94	12	3	Turning Point	41	2025-11-09
95	12	4	No Way Back	58	2025-11-07
96	12	5	The Descent	25	2025-01-12
97	12	6	New Beginnings	28	2025-08-25
98	12	7	The Chase	35	2024-09-24
99	12	8	Reckoning	35	2023-11-06
100	12	9	Aftermath	38	2025-04-05
101	13	1	Pilot	27	2024-04-23
102	13	2	The Reveal	32	2024-12-11
103	13	3	Turning Point	37	2024-04-17
104	13	4	No Way Back	33	2024-06-18
105	13	5	The Descent	57	2026-02-21
106	13	6	New Beginnings	26	2024-09-02
107	13	7	The Chase	32	2025-05-23
108	14	1	Pilot	22	2025-05-10
109	14	2	The Reveal	48	2025-02-10
110	14	3	Turning Point	50	2024-09-08
111	14	4	No Way Back	52	2025-09-15
112	14	5	The Descent	40	2023-10-21
113	14	6	New Beginnings	24	2023-12-16
114	14	7	The Chase	36	2026-01-04
115	14	8	Reckoning	40	2025-01-13
116	15	1	Pilot	40	2024-01-12
117	15	2	The Reveal	51	2026-03-25
118	15	3	Turning Point	26	2024-12-24
119	15	4	No Way Back	36	2023-08-29
120	15	5	The Descent	38	2026-07-14
121	15	6	New Beginnings	34	2024-04-06
122	15	7	The Chase	49	2025-09-21
123	15	8	Reckoning	29	2024-01-20
124	15	9	Aftermath	56	2025-08-10
125	15	10	Finale	36	2024-02-19
126	16	1	Pilot	31	2026-06-16
127	16	2	The Reveal	39	2024-06-24
128	16	3	Turning Point	31	2025-08-15
129	16	4	No Way Back	26	2024-05-29
130	16	5	The Descent	25	2024-10-09
131	16	6	New Beginnings	32	2026-05-15
132	16	7	The Chase	41	2024-02-26
133	16	8	Reckoning	58	2024-11-05
134	16	9	Aftermath	40	2024-07-28
135	16	10	Finale	50	2025-10-03
136	17	1	Pilot	29	2024-05-11
137	17	2	The Reveal	51	2025-08-16
138	17	3	Turning Point	41	2025-10-08
139	17	4	No Way Back	47	2023-08-30
140	17	5	The Descent	39	2025-02-01
141	17	6	New Beginnings	54	2024-01-21
142	17	7	The Chase	56	2024-05-02
143	17	8	Reckoning	53	2025-09-12
144	17	9	Aftermath	50	2023-09-08
145	18	1	Pilot	27	2025-09-29
146	18	2	The Reveal	24	2026-02-09
147	18	3	Turning Point	49	2026-08-16
148	18	4	No Way Back	42	2024-12-03
149	18	5	The Descent	38	2024-01-20
150	18	6	New Beginnings	23	2023-11-14
151	18	7	The Chase	27	2024-10-21
152	18	8	Reckoning	36	2025-11-06
153	18	9	Aftermath	58	2023-12-19
154	18	10	Finale	23	2024-08-06
155	19	1	Pilot	39	2026-04-20
156	19	2	The Reveal	58	2024-01-26
157	19	3	Turning Point	24	2025-12-23
158	19	4	No Way Back	33	2025-12-01
159	19	5	The Descent	52	2024-01-21
160	19	6	New Beginnings	55	2026-08-21
161	19	7	The Chase	50	2024-02-01
162	20	1	Pilot	39	2025-04-01
163	20	2	The Reveal	33	2023-09-07
164	20	3	Turning Point	49	2025-08-10
165	20	4	No Way Back	53	2024-12-23
166	20	5	The Descent	27	2025-10-28
167	20	6	New Beginnings	52	2025-07-17
168	21	1	Pilot	44	2024-02-10
169	21	2	The Reveal	48	2024-11-22
170	21	3	Turning Point	43	2025-09-19
171	21	4	No Way Back	42	2026-03-28
172	21	5	The Descent	28	2023-12-02
173	21	6	New Beginnings	32	2023-12-17
174	21	7	The Chase	43	2025-11-30
175	22	1	Pilot	48	2025-06-05
176	22	2	The Reveal	53	2024-10-22
177	22	3	Turning Point	40	2026-07-19
178	22	4	No Way Back	47	2024-08-07
179	22	5	The Descent	57	2024-01-29
180	22	6	New Beginnings	24	2024-06-27
181	22	7	The Chase	51	2023-11-29
182	22	8	Reckoning	27	2025-04-26
183	22	9	Aftermath	42	2025-06-16
184	23	1	Pilot	38	2025-06-24
185	23	2	The Reveal	42	2025-12-29
186	23	3	Turning Point	29	2025-09-23
187	23	4	No Way Back	47	2026-03-15
188	23	5	The Descent	54	2025-08-19
189	23	6	New Beginnings	22	2024-07-24
190	23	7	The Chase	56	2025-03-18
191	23	8	Reckoning	51	2025-03-09
192	23	9	Aftermath	48	2025-11-25
193	24	1	Pilot	25	2024-07-17
194	24	2	The Reveal	34	2023-10-27
195	24	3	Turning Point	55	2026-05-09
196	24	4	No Way Back	45	2026-07-10
197	24	5	The Descent	53	2025-02-21
198	24	6	New Beginnings	50	2023-12-30
199	24	7	The Chase	25	2025-02-26
200	24	8	Reckoning	35	2025-06-09
201	25	1	Pilot	39	2025-03-30
202	25	2	The Reveal	57	2026-08-04
203	25	3	Turning Point	30	2026-08-14
204	25	4	No Way Back	40	2026-06-17
205	25	5	The Descent	50	2024-01-20
206	25	6	New Beginnings	53	2026-03-29
207	26	1	Pilot	29	2025-05-12
208	26	2	The Reveal	23	2024-10-02
209	26	3	Turning Point	37	2025-09-15
210	26	4	No Way Back	32	2025-12-11
211	26	5	The Descent	41	2026-07-10
212	26	6	New Beginnings	57	2025-12-20
213	26	7	The Chase	22	2023-09-16
214	27	1	Pilot	57	2023-11-11
215	27	2	The Reveal	48	2024-06-11
216	27	3	Turning Point	27	2023-10-11
217	27	4	No Way Back	36	2023-11-03
218	27	5	The Descent	29	2026-01-10
219	27	6	New Beginnings	51	2025-03-06
220	27	7	The Chase	29	2025-07-17
221	27	8	Reckoning	31	2025-02-28
222	27	9	Aftermath	53	2024-11-26
223	28	1	Pilot	40	2025-10-06
224	28	2	The Reveal	54	2023-11-27
225	28	3	Turning Point	39	2025-04-08
226	28	4	No Way Back	48	2025-07-04
227	28	5	The Descent	52	2024-06-28
228	28	6	New Beginnings	52	2024-08-02
229	28	7	The Chase	37	2025-03-11
230	28	8	Reckoning	51	2024-04-07
231	29	1	Pilot	57	2026-01-30
232	29	2	The Reveal	31	2025-04-07
233	29	3	Turning Point	46	2024-10-30
234	29	4	No Way Back	34	2025-07-24
235	29	5	The Descent	54	2026-02-28
236	29	6	New Beginnings	30	2025-09-13
237	29	7	The Chase	26	2023-11-09
238	29	8	Reckoning	39	2025-10-02
239	29	9	Aftermath	48	2025-11-06
240	29	10	Finale	43	2026-03-13
241	30	1	Pilot	54	2023-10-31
242	30	2	The Reveal	39	2023-12-01
243	30	3	Turning Point	22	2024-12-17
244	30	4	No Way Back	40	2025-01-06
245	30	5	The Descent	41	2025-06-26
246	30	6	New Beginnings	53	2024-08-01
247	30	7	The Chase	31	2025-11-18
248	30	8	Reckoning	50	2025-11-17
249	31	1	Pilot	56	2024-01-06
250	31	2	The Reveal	52	2025-10-12
251	31	3	Turning Point	44	2025-10-05
252	31	4	No Way Back	43	2024-02-24
253	31	5	The Descent	57	2026-07-08
254	31	6	New Beginnings	56	2025-03-24
255	31	7	The Chase	46	2026-01-03
256	31	8	Reckoning	51	2025-10-26
257	31	9	Aftermath	42	2024-02-27
258	31	10	Finale	34	2024-01-15
259	32	1	Pilot	37	2026-01-01
260	32	2	The Reveal	58	2024-06-18
261	32	3	Turning Point	46	2026-04-26
262	32	4	No Way Back	36	2025-12-21
263	32	5	The Descent	48	2023-09-30
264	32	6	New Beginnings	24	2026-01-29
265	32	7	The Chase	42	2024-06-22
266	33	1	Pilot	52	2023-11-07
267	33	2	The Reveal	46	2025-10-17
268	33	3	Turning Point	46	2025-05-22
269	33	4	No Way Back	31	2023-11-21
270	33	5	The Descent	53	2025-01-08
271	33	6	New Beginnings	24	2024-09-26
\.


--
-- Data for Name: genre; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.genre (genreid, genrename, genrecategory) FROM stdin;
1	Sci-Fi & Fantasy	Genre
2	Comedy	Genre
3	Drama	Genre
4	Documentary	Format
5	Horror	Genre
6	Romance	Genre
7	Thriller	Genre
8	Anime	Format
9	K-Drama	Format
10	Reality TV	Format
11	Stand-Up Comedy	Format
12	Crime	Genre
13	Kids & Family	Audience
14	Musical	Genre
15	Sports	Genre
16	War Movies	Genre
17	Classic Movies	Era
18	Teen	Audience
19	LGBTQ	Audience
20	Cult Movies	Era
21	Biographical	Genre
22	Action & Adventure	Genre
\.


--
-- Data for Name: mylist; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.mylist (profileid, titleid, dateadded) FROM stdin;
5	19	2026-02-23
38	21	2025-12-07
55	16	2026-06-23
72	23	2025-12-06
1	16	2025-09-06
41	23	2026-06-11
54	13	2026-07-31
21	28	2026-07-16
43	16	2026-01-26
42	8	2026-03-07
12	18	2026-02-14
1	21	2025-11-09
10	25	2026-01-10
47	13	2025-12-31
11	19	2026-02-07
3	23	2025-09-26
44	21	2026-03-31
57	18	2026-05-09
60	4	2026-01-27
66	29	2026-03-04
60	25	2026-06-26
4	16	2025-12-18
58	19	2026-07-12
20	15	2026-07-11
40	8	2026-07-13
45	3	2026-03-21
15	12	2026-04-29
34	9	2026-06-29
69	9	2026-07-15
33	18	2026-01-29
2	22	2025-10-29
1	17	2026-04-04
18	4	2026-03-18
19	8	2026-01-28
16	25	2025-12-31
15	18	2025-09-28
27	20	2025-10-11
7	10	2025-09-30
68	3	2025-10-16
63	15	2026-05-26
42	27	2026-04-13
53	26	2026-05-27
54	14	2025-09-04
26	20	2026-06-16
45	15	2026-08-01
57	11	2026-02-23
64	1	2026-06-01
70	22	2025-11-06
19	10	2026-03-11
50	19	2025-12-06
71	13	2026-02-11
35	27	2026-07-28
52	23	2025-12-27
70	29	2026-06-28
46	25	2026-03-12
37	30	2026-01-17
61	15	2025-11-13
26	21	2026-05-02
32	18	2026-06-19
34	10	2026-08-28
12	17	2025-11-18
13	19	2025-12-04
56	11	2025-12-16
61	26	2026-04-21
17	18	2026-08-18
8	9	2026-03-15
34	19	2026-04-14
33	6	2026-08-24
11	24	2025-12-02
29	27	2025-10-30
64	14	2026-07-11
25	12	2026-07-23
54	7	2026-07-22
4	6	2026-01-20
14	9	2025-09-19
51	3	2026-04-07
58	5	2025-10-02
72	24	2026-05-12
48	23	2026-02-21
62	4	2026-06-25
44	9	2026-06-01
59	26	2026-08-19
10	6	2026-07-18
51	24	2026-05-08
67	10	2025-10-25
25	23	2026-02-27
18	24	2026-07-01
39	23	2026-02-11
9	18	2025-11-03
32	9	2025-10-13
49	16	2025-09-10
31	19	2026-08-18
2	16	2025-12-12
65	23	2026-06-24
43	13	2026-01-28
33	11	2026-02-03
23	25	2025-09-25
6	26	2026-04-26
49	15	2026-04-07
72	10	2026-07-29
52	12	2025-11-22
61	27	2025-11-04
25	19	2026-05-16
22	15	2026-02-18
58	28	2025-10-16
52	22	2026-07-19
3	27	2026-07-02
43	5	2025-10-21
48	9	2026-01-15
44	14	2026-08-06
60	2	2025-12-04
71	2	2025-11-27
69	3	2025-09-07
46	26	2025-10-03
37	2	2026-01-20
15	27	2026-05-30
50	1	2025-10-19
17	7	2026-03-31
71	6	2026-06-30
48	24	2026-01-25
30	26	2026-08-23
46	29	2025-12-10
35	29	2025-11-30
21	12	2026-02-17
35	22	2026-07-27
28	26	2026-06-01
67	6	2025-12-19
19	25	2026-06-23
24	7	2026-07-24
17	15	2026-03-14
67	28	2026-03-01
26	14	2026-04-12
36	5	2025-09-21
56	27	2025-12-08
38	28	2025-12-25
68	21	2026-07-05
51	15	2025-09-11
59	11	2026-02-06
\.


--
-- Data for Name: person; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.person (personid, fullname, dateofbirth, nationality, biography) FROM stdin;
1	Daniel Brown	1991-11-10	Bahamas	Anyone live try most. Whether bag control organization. Identify walk now often always.\nPrice north first end prove fire. How public feel first sell.
2	David Mitchell	1975-03-13	Mayotte	Worker southern more property never use billion there. Break blood network evening painting.\nReach table measure economy traditional. Begin interest everybody. Four capital woman.
3	Amanda Howard	1988-11-07	Papua New Guinea	Sister this image per choice upon. Wish specific thing agent.\nSoon ten specific environment skin blue. Teach develop staff. Glass star the development process huge everything.
4	Deborah Rodriguez	1974-12-29	Saint Lucia	Paper memory history office effort remember. Mind southern rather. Hair attorney professional form finish.\nMedical project for recent never. Inside wait quality total past.
5	Matthew Harvey	1955-11-21	Zambia	Different current agency each little. Lay though offer responsibility.
6	Tiffany Vance	1984-12-19	Saint Helena	Store natural today season listen else. Style everyone sing machine dream. Back experience even floor music catch.
7	Laura Woods	2003-06-14	French Southern Territories	Mrs same son today major event. Ahead from quickly identify close level camera. Move trade option production base investment term consider.
8	Rachael Pearson	1992-11-23	Zambia	Stuff perform draw list boy. Let eight hard paper white.\nWho blue agent find. However resource away real physical big.
9	Madison Poole	1990-04-08	Jordan	Whole establish space Mrs low itself room. Focus early various everything late.
10	Ricky Davis II	1989-05-25	Gambia	List most international second former reflect. Fill discover return firm sea. Course school everybody operation. Others wonder strategy fast guess few remain.
11	Ashley Jones	1978-03-13	Morocco	Charge specific we. Yes budget share paper. Difficult mission late kind team wrong figure perform. Whether between several personal enough ball dream necessary.
12	Michael Bradshaw	1994-10-11	Niue	Interesting name positive training step. Arrive society organization station. Keep light fight I evening. Management ball always it focus economy before.
13	Jennifer Hodges	1952-09-17	Benin	Follow wife identify method write. Left approach million performance material kind appear. Near until just recognize building.
14	Jennifer Villa	1979-02-03	Swaziland	Rise study oil process tend.\nMachine forward several help usually thank wonder. Occur do simply analysis seat. History professional star wonder manager already.
15	Olivia Brennan	1952-09-01	Bangladesh	Range explain dinner bed within set region beyond. Really tough animal someone.\nHear certainly most not society color. Participant him raise marriage.
16	Keith Jennings	1992-05-11	Australia	Strategy total simply discover soon despite couple. Question return process stuff pick. Position final kid often run bed far section. Customer skill theory hand.
17	Michael Chambers	1983-05-24	Swaziland	Push likely people wall. Trip determine as statement travel few. Bring animal also you break doctor.
18	Michael Stephens	2005-06-01	Guinea-Bissau	Every why we station begin deep. Wife anything four writer skin day stop never.
19	Ashley Gordon	2003-08-08	Aruba	Leader who article look husband. Make travel available ball. Chance call person one Republican herself our far.
20	Brent Rodgers	1996-02-12	Moldova	What no prove improve them wait institution trouble. Why outside goal.
21	Kylie Morales	1958-08-08	North Macedonia	Second Democrat information game.\nReturn since nothing be apply. Senior anyone bank kitchen. Magazine kind event sense box involve.
22	Carl Patel	1963-07-18	Monaco	However score job least. Television office of remember. Face if whom commercial way least.\nJoin black job hundred. How financial fund four. Baby plan most create.
23	Rebecca Vargas	1970-05-14	Barbados	Later arm story baby ten talk past. His oil west school American training occur.\nPainting may whatever late specific study. Mean common easy just.
24	Melissa Myers	1983-12-24	Wallis and Futuna	Next poor foreign campaign reflect. Behavior provide meet adult final week game.
25	Amanda Diaz	1990-12-15	Kenya	Sell six doctor dream whole. Tough create question now key show sing. Month whom stage soon catch economic political. Never bill suffer surface expect several.
26	Brad Walker	1968-07-03	Bolivia	Case expert stop receive. Serve light past town. Eight strong nature.
27	Katie Smith	1999-07-26	Aruba	Effect administration small general run pick. Same forward and national spend compare single let. Place specific as simply leader fall analysis.
28	Robert Kim	1973-01-22	Kazakhstan	Wind many marriage under mind song. Bad own state nation fly bag. Fill owner international ready goal.\nPast itself police social arm provide.
29	Tyler Johnson	1961-01-28	Maldives	Brother simple region Democrat partner really your. But table later together knowledge. Specific whose worry property.
30	William Anderson	2000-03-05	Bahrain	Yourself rest moment shoulder statement available. Politics last quite general there sister.
31	Marcus Winters	1969-07-25	Uzbekistan	Stay agreement animal. Enough decision occur peace air threat nation. Lot source rate father authority.\nKeep machine daughter parent. Technology floor write generation human set.
32	Amber Campbell	1984-02-13	Tajikistan	Mr suggest issue think road. Hand hundred now crime network available. Late near stay perhaps particularly campaign benefit.
33	Linda Romero	1979-03-15	Liechtenstein	Little admit former body indicate. Someone rise read ago listen. Officer return on color pick people subject challenge.\nOccur red course. Finish charge real improve simple turn.
34	Maria Steele	1984-10-27	Congo	Newspaper different win father eye. Real major look night various.\nBusiness quality here woman stand. Fact explain research get.
35	Vanessa Moore	1987-03-22	Turkmenistan	Practice sense expert experience arrive shoulder present. Movement rich view tree company. Value already structure small.
36	Denise Lamb	1969-03-05	Saint Martin	Responsibility add front far purpose. Compare task today still middle. Husband believe word local.\nEnd dog send. Few reveal activity president realize artist.
37	Jacqueline Miles DVM	1993-01-25	Spain	Quite other skin moment month. Back nor article natural measure of.\nForeign minute break day. Major together knowledge argue car indeed nor next.
38	Christopher Taylor	1986-08-01	Saint Lucia	Year him thank trade heart radio. Card team budget year hotel camera without. Series without leg.
39	Michael Brennan	1964-05-12	Aruba	Doctor describe tell argue mean eye. Five our pull fly few century produce. Including every news option same.
40	Renee Melendez	1982-02-25	Israel	Care drug data position two suggest begin. Appear help painting always authority. Right next look thank four whatever address view.
\.


--
-- Data for Name: plan; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.plan (planid, planname, monthlyprice, videoquality, maxsimultaneousstreams, maxdownloaddevices, includesads) FROM stdin;
1	Standard with Ads - US	6.99	Full HD (1080p)	2	2	t
2	Standard with Ads - Canada	7.34	Full HD (1080p)	2	2	t
3	Standard with Ads - United Kingdom	5.94	Full HD (1080p)	2	2	t
4	Standard with Ads - India	2.45	Full HD (1080p)	2	2	t
5	Standard with Ads - Brazil	3.84	Full HD (1080p)	2	2	t
6	Standard - US	15.49	Full HD (1080p)	2	2	f
7	Standard - Canada	16.26	Full HD (1080p)	2	2	f
8	Standard - United Kingdom	13.17	Full HD (1080p)	2	2	f
9	Standard - India	5.42	Full HD (1080p)	2	2	f
10	Standard - Brazil	8.52	Full HD (1080p)	2	2	f
11	Premium - US	22.99	4K Ultra HD + HDR	4	6	f
12	Premium - Canada	24.14	4K Ultra HD + HDR	4	6	f
13	Premium - United Kingdom	19.54	4K Ultra HD + HDR	4	6	f
14	Premium - India	8.05	4K Ultra HD + HDR	4	6	f
15	Premium - Brazil	12.64	4K Ultra HD + HDR	4	6	f
16	Mobile - US	3.99	SD (480p)	1	1	f
17	Mobile - Canada	4.19	SD (480p)	1	1	f
18	Mobile - United Kingdom	3.39	SD (480p)	1	1	f
19	Mobile - India	1.40	SD (480p)	1	1	f
20	Mobile - Brazil	2.19	SD (480p)	1	1	f
\.


--
-- Data for Name: profile; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.profile (profileid, accountid, profilename, avataricon, iskidsprofile, maturitylevel, preferredlanguage, autoplaynextepisode) FROM stdin;
1	1	Karina	avatar_10.png	f	Adults	German	f
2	1	Hannah	avatar_3.png	f	Adults	English	t
3	1	Jennifer	avatar_3.png	f	Teens	French	f
4	1	Raymond	avatar_7.png	f	Adults	German	f
5	1	Emily	avatar_9.png	f	Teens	French	t
6	2	Nathaniel	avatar_13.png	f	Adults	English	f
7	2	Rachel	avatar_8.png	f	Teens	French	f
8	2	Shannon	avatar_13.png	f	Teens	German	t
9	2	John	avatar_5.png	f	Teens	Spanish	f
10	2	Caleb	avatar_9.png	f	Teens	German	f
11	3	Andrew	avatar_15.png	t	Older Kids	Portuguese	t
12	3	Angela	avatar_15.png	t	Little Kids	English	f
13	3	Brianna	avatar_13.png	f	Teens	Spanish	f
14	3	Adrian	avatar_3.png	f	Adults	German	f
15	4	Jean	avatar_13.png	f	Teens	French	f
16	4	Brian	avatar_11.png	f	Adults	Hindi	f
17	5	Carlos	avatar_2.png	t	Older Kids	English	t
18	6	Anthony	avatar_2.png	t	Little Kids	Spanish	t
19	6	Mark	avatar_14.png	f	Adults	English	t
20	6	Willie	avatar_8.png	f	Teens	German	t
21	6	Joshua	avatar_15.png	f	Adults	Spanish	f
22	6	Todd	avatar_4.png	f	Teens	English	f
23	7	Amber	avatar_8.png	f	Teens	French	t
24	7	Jennifer	avatar_12.png	t	Older Kids	English	t
25	7	Nicole	avatar_9.png	t	Older Kids	Spanish	f
26	8	Barbara	avatar_4.png	f	Teens	Hindi	t
27	8	John	avatar_9.png	t	Little Kids	English	t
28	9	Thomas	avatar_8.png	f	Teens	Hindi	t
29	9	Richard	avatar_1.png	t	Older Kids	Portuguese	f
30	10	Clinton	avatar_12.png	f	Adults	Spanish	t
31	10	Donna	avatar_1.png	f	Teens	French	f
32	10	Michael	avatar_10.png	t	Older Kids	German	t
33	11	Robert	avatar_2.png	f	Teens	English	t
34	12	Michelle	avatar_15.png	f	Teens	German	t
35	12	Brian	avatar_7.png	f	Adults	Portuguese	t
36	13	Denise	avatar_7.png	t	Little Kids	French	f
37	13	Debbie	avatar_15.png	f	Teens	English	f
38	13	Bruce	avatar_10.png	f	Teens	English	t
39	14	Jessica	avatar_15.png	f	Adults	English	t
40	14	Lauren	avatar_3.png	f	Adults	German	f
41	14	Daniel	avatar_13.png	f	Teens	French	f
42	14	James	avatar_2.png	f	Teens	Portuguese	t
43	14	Amanda	avatar_12.png	f	Teens	Portuguese	f
44	15	Donald	avatar_6.png	t	Little Kids	French	f
45	15	Isaiah	avatar_5.png	f	Teens	English	f
46	15	Steven	avatar_1.png	f	Teens	Portuguese	t
47	15	Nancy	avatar_5.png	f	Teens	French	f
48	15	Charles	avatar_7.png	f	Teens	English	t
49	16	Lindsey	avatar_14.png	f	Adults	German	t
50	16	Melissa	avatar_1.png	f	Adults	Portuguese	t
51	17	Corey	avatar_4.png	t	Little Kids	Portuguese	f
52	17	Denise	avatar_12.png	f	Teens	Spanish	t
53	17	Amber	avatar_13.png	f	Teens	Hindi	t
54	18	Alexis	avatar_6.png	f	Adults	French	t
55	18	Christopher	avatar_13.png	f	Teens	Hindi	t
56	19	Karen	avatar_14.png	t	Older Kids	Portuguese	f
57	19	Joel	avatar_14.png	f	Teens	Spanish	t
58	19	Richard	avatar_7.png	f	Adults	Portuguese	t
59	19	Timothy	avatar_5.png	f	Adults	French	f
60	20	Michelle	avatar_1.png	f	Teens	Portuguese	t
61	20	Rachel	avatar_5.png	f	Teens	English	f
62	20	Franklin	avatar_13.png	f	Adults	Hindi	t
63	20	Aaron	avatar_10.png	f	Teens	Portuguese	t
64	20	Peter	avatar_1.png	f	Teens	Portuguese	f
65	21	Sara	avatar_15.png	f	Adults	German	f
66	22	Kristen	avatar_5.png	f	Adults	French	f
67	23	Justin	avatar_5.png	f	Teens	Spanish	f
68	23	Heather	avatar_7.png	f	Teens	German	f
69	23	Jessica	avatar_14.png	f	Teens	Portuguese	f
70	24	Krista	avatar_10.png	f	Adults	Hindi	f
71	24	Dorothy	avatar_4.png	f	Adults	French	t
72	25	Tommy	avatar_11.png	f	Adults	English	t
74	4	Grandma Rose	avatar_default.png	t	Older Kids	English	t
\.


--
-- Data for Name: rating; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.rating (profileid, titleid, thumbsrating, ratingdate) FROM stdin;
1	14	Two Thumbs Up	2026-06-25
2	4	Thumbs Up	2026-02-28
2	1	Thumbs Down	2026-04-17
2	7	Thumbs Up	2025-10-12
3	15	Thumbs Up	2025-09-08
3	1	Thumbs Down	2026-01-11
3	23	Two Thumbs Up	2026-04-02
4	5	Thumbs Up	2025-10-31
4	16	Thumbs Down	2026-07-12
4	3	Two Thumbs Up	2026-03-30
5	11	Thumbs Up	2026-01-03
6	5	Two Thumbs Up	2025-10-26
6	13	Two Thumbs Up	2026-07-21
7	21	Two Thumbs Up	2026-05-29
8	3	Thumbs Up	2026-05-07
9	20	Two Thumbs Up	2025-12-10
10	12	Thumbs Up	2026-01-16
10	24	Two Thumbs Up	2025-10-26
11	20	Thumbs Up	2026-03-25
11	22	Thumbs Up	2026-08-16
12	5	Two Thumbs Up	2026-07-07
13	24	Two Thumbs Up	2026-04-21
13	13	Thumbs Up	2026-05-03
13	12	Thumbs Down	2025-12-04
14	21	Thumbs Up	2026-01-24
14	3	Two Thumbs Up	2025-09-04
15	20	Two Thumbs Up	2026-06-09
15	10	Thumbs Down	2026-06-04
15	25	Two Thumbs Up	2025-08-31
16	7	Two Thumbs Up	2026-07-27
16	17	Thumbs Up	2026-04-21
17	10	Thumbs Down	2026-04-05
17	21	Two Thumbs Up	2025-08-31
18	16	Thumbs Up	2025-11-28
19	16	Two Thumbs Up	2026-06-18
20	17	Two Thumbs Up	2025-12-17
21	12	Two Thumbs Up	2026-08-16
22	13	Two Thumbs Up	2026-04-20
23	14	Two Thumbs Up	2026-01-30
23	12	Two Thumbs Up	2026-01-12
23	18	Two Thumbs Up	2026-01-02
24	1	Two Thumbs Up	2025-11-28
25	9	Thumbs Up	2026-02-14
26	26	Thumbs Up	2026-05-02
27	21	Thumbs Up	2026-06-25
27	23	Thumbs Up	2026-01-20
28	13	Thumbs Up	2025-10-04
28	3	Two Thumbs Up	2026-03-03
28	21	Thumbs Up	2026-04-27
29	3	Two Thumbs Up	2026-07-02
29	17	Two Thumbs Up	2026-01-11
30	18	Thumbs Up	2026-04-21
31	21	Two Thumbs Up	2026-04-07
31	25	Two Thumbs Up	2025-12-15
31	27	Thumbs Up	2025-10-06
32	24	Thumbs Up	2025-09-20
32	28	Thumbs Up	2026-08-24
33	4	Two Thumbs Up	2026-04-19
33	15	Thumbs Down	2026-07-09
34	24	Thumbs Down	2025-12-01
34	22	Two Thumbs Up	2026-05-15
34	6	Two Thumbs Up	2026-07-20
35	16	Two Thumbs Up	2025-12-15
36	17	Two Thumbs Up	2025-10-21
36	26	Thumbs Up	2026-06-04
36	27	Thumbs Down	2026-07-23
37	24	Thumbs Down	2026-06-18
37	29	Two Thumbs Up	2026-06-17
38	26	Thumbs Up	2026-04-04
38	14	Thumbs Down	2026-04-26
39	19	Thumbs Up	2026-05-04
39	21	Thumbs Up	2026-05-18
39	3	Thumbs Down	2026-04-24
40	6	Two Thumbs Up	2026-08-28
40	12	Two Thumbs Up	2025-11-30
40	9	Two Thumbs Up	2026-01-28
41	8	Two Thumbs Up	2026-01-17
42	2	Two Thumbs Up	2025-09-09
43	8	Thumbs Down	2026-05-14
44	13	Thumbs Up	2026-03-25
44	30	Two Thumbs Up	2025-11-05
45	18	Two Thumbs Up	2026-05-20
46	24	Thumbs Up	2025-11-17
46	21	Thumbs Up	2026-03-11
46	14	Two Thumbs Up	2026-06-11
47	9	Thumbs Down	2026-07-25
47	27	Thumbs Up	2026-04-30
48	22	Thumbs Up	2026-03-01
48	29	Two Thumbs Up	2026-07-03
48	2	Two Thumbs Up	2026-07-01
49	3	Thumbs Up	2026-07-14
49	29	Thumbs Up	2025-11-02
50	11	Thumbs Up	2025-10-02
50	3	Thumbs Down	2025-10-13
51	10	Thumbs Up	2025-11-30
52	24	Thumbs Up	2026-06-19
52	20	Thumbs Up	2026-06-03
53	25	Two Thumbs Up	2025-11-03
53	7	Thumbs Up	2026-05-03
54	5	Thumbs Down	2025-12-28
55	1	Thumbs Up	2025-09-29
55	8	Two Thumbs Up	2026-01-05
56	29	Thumbs Down	2026-05-27
56	1	Two Thumbs Up	2025-12-18
56	11	Two Thumbs Up	2026-06-12
57	10	Thumbs Up	2025-12-27
57	4	Thumbs Up	2025-12-01
57	7	Thumbs Up	2025-12-13
58	5	Two Thumbs Up	2026-07-05
59	2	Two Thumbs Up	2026-02-16
60	14	Thumbs Up	2026-07-11
60	23	Two Thumbs Up	2026-03-29
60	29	Thumbs Down	2026-08-08
61	17	Thumbs Down	2025-09-23
62	3	Thumbs Up	2026-07-19
62	19	Thumbs Up	2026-02-27
63	8	Thumbs Up	2026-07-11
64	30	Thumbs Up	2026-01-14
64	26	Two Thumbs Up	2025-12-15
65	11	Thumbs Up	2025-09-16
65	15	Thumbs Down	2026-07-06
66	5	Two Thumbs Up	2025-10-17
67	4	Thumbs Up	2025-11-09
67	5	Thumbs Up	2026-01-24
67	6	Thumbs Down	2026-03-24
68	25	Thumbs Up	2026-07-25
68	7	Thumbs Up	2026-02-11
69	3	Thumbs Up	2025-12-21
70	10	Two Thumbs Up	2026-05-16
70	27	Thumbs Down	2026-06-09
70	23	Two Thumbs Up	2026-02-22
71	5	Two Thumbs Up	2026-04-15
71	3	Two Thumbs Up	2025-10-31
72	17	Two Thumbs Up	2026-04-17
72	2	Thumbs Up	2025-08-29
\.


--
-- Data for Name: season; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.season (seasonid, titleid, seasonnumber, seasonreleaseyear, episodecount) FROM stdin;
2	16	2	2024	6
3	17	1	2018	8
4	17	2	2019	10
5	17	3	2020	9
6	18	1	2020	6
7	18	2	2021	10
8	18	3	2022	8
9	19	1	2021	9
10	20	1	2021	8
11	21	1	2021	7
12	21	2	2022	9
13	21	3	2023	7
14	22	1	2022	8
15	22	2	2023	10
16	22	3	2024	10
17	23	1	2021	9
18	23	2	2022	10
19	24	1	2020	7
20	24	2	2021	6
21	25	1	2021	7
22	25	2	2022	9
23	26	1	2022	9
24	26	2	2023	8
25	26	3	2024	6
26	27	1	2020	7
27	27	2	2021	9
28	28	1	2020	8
29	29	1	2020	10
30	29	2	2021	8
31	30	1	2018	10
32	30	2	2019	7
33	30	3	2020	6
1	16	1	2023	10
\.


--
-- Data for Name: title; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.title (titleid, titlename, titletype, releaseyear, synopsis, maturityrating, runtimeminutes, originallanguage, dateadded, isnetflixoriginal) FROM stdin;
1	The Shattered Legacy	Movie	2018	Trial have including none determine certainly. Network once result far cultural.	PG	103	English	2024-05-07	t
2	The Forgotten Echo	Movie	2016	Material pressure range either start. Leave run goal cause national contain threat.	TV-14	138	Japanese	2026-08-18	t
3	The Endless Garden	Movie	2022	Almost suggest war property share include successful.	TV-14	116	Spanish	2024-05-08	f
4	The Silent Sanctuary	Movie	2016	Despite lay art.	TV-14	113	Spanish	2025-07-27	f
5	The Endless Empire	Movie	2022	Process administration mother in admit reveal movie. Admit spend purpose south travel.	TV-Y7	156	Spanish	2023-12-24	f
6	The Crimson Detective	Movie	2017	Chance court money spring environment however health.	TV-14	152	Japanese	2024-11-16	f
7	The Secret Sanctuary	Movie	2022	Wrong difficult range summer president. Behavior here need.	R	149	French	2023-10-29	f
8	The Rising Detective	Movie	2017	Bar suddenly population former.	TV-MA	145	French	2026-08-04	t
9	The Broken Bloodline	Movie	2025	Try discover top realize note even under.	PG-13	151	French	2025-09-17	f
10	The Hidden Detective	Movie	2016	Nor allow up fire which onto sell.	TV-MA	121	Spanish	2025-10-18	t
11	The Golden Sanctuary	Movie	2023	Federal nor note support. Forward sense cause write right may window.	TV-Y7	102	Spanish	2023-10-26	t
12	The Endless Signal	Movie	2026	Stuff future shoulder western however. Ahead event yeah make green wait.	PG	93	French	2024-12-14	t
13	The Rising Detective	Movie	2021	Beat peace something require bank child. Science first blood accept.	TV-Y7	111	French	2024-07-31	t
14	The Secret Echo	Movie	2026	Bill beautiful issue news mention. Ago government behavior our.	TV-Y7	158	French	2024-08-18	t
15	The Golden Legacy	Movie	2021	Factor hold be. Toward within occur college herself catch feeling.	TV-14	153	Japanese	2025-02-19	f
16	Restless Harbor	Series	2022	Itself inside machine baby.	PG	\N	Korean	2024-05-30	t
17	Silent Garden	Series	2020	Many pattern leader career according how success here.	TV-MA	\N	French	2026-03-30	f
18	Frozen Detective	Series	2017	Issue statement prepare organization feel owner. Look concern huge five same.	R	\N	Japanese	2025-07-22	t
19	Midnight Echo	Series	2024	For exactly skill half usually. Or nation race nearly well.	TV-MA	\N	English	2025-01-15	t
20	Midnight Signal	Series	2022	Something story attorney summer some pull.	PG	\N	English	2024-01-28	t
21	Golden Harbor	Series	2022	Education child institution help last.	PG-13	\N	Korean	2025-06-14	f
22	Midnight Legacy	Series	2021	Move type thank industry already why. Order trial body eat professor coach partner.	PG-13	\N	English	2025-05-07	t
23	Endless Empire	Series	2015	Whole involve action else member million. Reach determine hear leg quickly real character young.	PG-13	\N	Spanish	2025-02-08	f
24	Secret Voyage	Series	2015	Turn beat story role give gas.	TV-Y7	\N	Spanish	2026-01-04	t
25	Silent Echo	Series	2017	Give best reveal laugh attack and represent. Support possible quality.	PG	\N	Spanish	2024-02-25	t
26	Crimson Echo	Series	2018	Company civil nice when discussion if continue.	TV-14	\N	Korean	2025-07-30	f
27	Last Echo	Series	2024	Ahead pass culture or home relate. Everything region somebody officer son.	TV-MA	\N	English	2025-04-08	f
28	Last Legacy	Series	2016	Culture box provide majority whole finish. Particularly only girl suddenly pay sport.	R	\N	English	2025-10-10	f
29	Distant Voyage	Series	2021	Opportunity public finish draw bring health center home.	TV-14	\N	Spanish	2025-06-12	t
30	Endless Bloodline	Series	2025	Institution main Mr try us community. Majority cell fire late.	PG	\N	English	2023-10-26	f
\.


--
-- Data for Name: titlegenre; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.titlegenre (titleid, genreid) FROM stdin;
14	4
20	14
7	20
23	13
23	22
8	3
11	2
28	18
26	15
30	12
8	21
2	11
28	22
16	1
13	8
10	21
18	14
16	10
21	6
12	3
4	5
17	2
20	19
12	21
20	22
14	21
19	8
2	4
5	21
10	11
27	15
11	16
15	4
9	22
13	10
24	16
25	15
1	17
29	3
18	12
6	16
26	22
22	3
4	1
12	8
5	5
23	20
3	17
17	10
8	13
13	3
16	2
9	18
15	6
25	5
25	8
26	9
11	18
2	15
30	19
7	11
15	15
\.


--
-- Data for Name: watchhistory; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.watchhistory (watchid, profileid, titleid, episodeid, watchdate, progressminutes, percentcomplete, devicetype, iscompleted) FROM stdin;
1	1	5	\N	2026-04-06 14:26:17.800822	150	74.92	Game Console	f
2	1	1	\N	2026-04-24 23:25:39.856512	17	100.00	Smart TV	t
3	1	11	\N	2026-04-17 01:45:13.925289	118	100.00	Tablet	t
4	1	13	\N	2026-03-21 14:10:15.167237	93	100.00	Tablet	t
5	2	11	\N	2026-03-28 11:19:22.624941	139	100.00	Phone	t
6	2	7	\N	2026-07-02 22:08:29.266412	57	9.93	Phone	f
7	3	28	227	2026-07-28 12:51:44.291629	35	100.00	Smart TV	t
8	3	7	\N	2026-07-04 21:33:07.244837	102	100.00	Game Console	t
9	3	24	163	2026-03-07 01:33:21.104166	23	77.56	Tablet	f
10	4	8	\N	2026-07-30 06:38:36.951548	114	82.59	Game Console	f
11	4	11	\N	2026-04-28 12:47:07.840738	34	100.00	Tablet	t
12	5	18	63	2026-03-16 08:26:53.68288	97	100.00	Smart TV	t
13	5	2	\N	2026-04-14 00:12:33.794293	107	100.00	Game Console	t
14	6	5	\N	2026-05-03 15:12:57.492273	48	24.94	Smart TV	f
15	6	17	33	2026-06-01 10:05:30.419691	94	100.00	Phone	t
16	7	3	\N	2026-07-01 07:16:48.661239	49	100.00	Game Console	t
17	7	13	\N	2026-04-16 04:32:50.555846	131	20.94	Tablet	f
18	7	28	230	2026-08-27 12:31:51.839792	87	84.38	Phone	f
19	8	8	\N	2026-03-05 09:02:47.157938	82	100.00	Phone	t
20	8	21	101	2026-05-12 12:19:26.416386	123	100.00	Tablet	t
21	8	6	\N	2026-05-21 05:45:00.442737	28	11.91	Game Console	f
22	9	9	\N	2026-07-14 05:50:04.635144	15	71.50	Tablet	f
23	9	25	174	2026-04-14 07:21:58.987139	126	100.00	Game Console	t
24	9	1	\N	2026-05-23 00:51:47.359015	92	100.00	Smart TV	t
25	9	18	45	2026-07-24 10:20:44.141893	117	100.00	Tablet	t
26	9	25	173	2026-03-25 05:15:09.205631	77	100.00	Tablet	t
27	10	26	203	2026-03-01 21:16:08.426099	90	100.00	Smart TV	t
28	10	9	\N	2026-07-29 06:19:16.812704	43	30.57	Phone	f
29	10	11	\N	2026-08-26 01:00:29.076828	94	100.00	Phone	t
30	10	27	219	2026-03-23 13:29:14.741524	26	100.00	Phone	t
31	10	26	194	2026-07-28 00:58:36.718351	139	65.31	Smart TV	f
32	11	16	12	2026-05-06 15:28:50.510768	59	100.00	Phone	t
33	11	23	142	2026-06-22 17:53:51.900549	40	100.00	Laptop	t
34	11	14	\N	2026-06-25 08:55:18.343399	143	50.69	Game Console	f
35	11	6	\N	2026-06-13 23:44:58.956226	101	60.62	Laptop	f
36	11	14	\N	2026-04-15 22:39:02.288287	47	61.23	Tablet	f
37	12	11	\N	2026-07-26 01:06:51.567538	77	92.26	Tablet	f
38	12	4	\N	2026-03-03 16:23:13.952138	125	100.00	Laptop	t
39	13	25	182	2026-03-11 11:18:37.472066	77	100.00	Tablet	t
40	13	22	113	2026-08-11 10:15:28.733154	40	77.11	Phone	f
41	13	8	\N	2026-05-19 15:20:02.363574	31	54.91	Game Console	f
42	13	20	78	2026-03-23 05:03:38.696381	136	29.55	Laptop	f
43	14	15	\N	2026-08-11 21:34:04.411687	120	100.00	Phone	t
44	14	22	109	2026-07-29 01:52:12.329839	100	100.00	Laptop	t
45	14	2	\N	2026-04-29 05:14:22.603478	12	100.00	Phone	t
46	14	29	241	2026-03-07 11:55:20.338657	78	17.38	Tablet	f
47	14	18	66	2026-05-22 20:16:15.529352	6	100.00	Smart TV	t
48	15	14	\N	2026-03-30 08:45:55.128592	140	100.00	Tablet	t
49	15	5	\N	2026-06-12 10:46:48.73445	36	100.00	Smart TV	t
50	16	13	\N	2026-07-27 16:16:06.283735	132	10.65	Game Console	f
51	16	26	200	2026-05-10 19:10:32.873616	41	100.00	Phone	t
52	16	10	\N	2026-03-05 02:02:18.741431	111	100.00	Laptop	t
53	17	21	87	2026-07-02 09:41:32.863261	134	53.97	Game Console	f
54	17	14	\N	2026-03-31 05:52:13.72701	104	100.00	Phone	t
55	18	21	87	2026-04-07 21:27:05.588367	31	100.00	Game Console	t
56	18	21	89	2026-04-02 20:42:13.158122	144	100.00	Phone	t
57	18	18	65	2026-04-19 18:47:21.200568	127	100.00	Laptop	t
58	18	17	39	2026-08-07 22:42:44.017279	80	46.19	Laptop	f
59	19	30	250	2026-03-06 00:40:23.302997	84	100.00	Game Console	t
60	19	14	\N	2026-06-20 17:10:56.759279	69	100.00	Smart TV	t
61	20	14	\N	2026-04-13 13:32:50.115237	89	82.92	Phone	f
62	20	6	\N	2026-04-22 13:35:39.151901	107	100.00	Tablet	t
63	20	22	118	2026-05-13 21:36:56.03141	132	49.66	Phone	f
64	21	27	220	2026-06-08 05:10:21.46295	51	100.00	Game Console	t
65	21	2	\N	2026-03-10 20:00:34.330764	80	100.00	Phone	t
66	21	12	\N	2026-04-19 18:26:42.222844	118	100.00	Phone	t
67	21	12	\N	2026-03-24 18:03:05.661976	116	36.73	Phone	f
68	22	11	\N	2026-04-05 02:36:46.358609	136	100.00	Laptop	t
69	22	18	63	2026-08-08 04:05:40.555383	37	44.44	Smart TV	f
70	23	21	96	2026-06-03 16:12:35.677222	150	100.00	Smart TV	t
71	23	26	198	2026-06-22 19:53:56.146573	24	38.48	Game Console	f
72	23	6	\N	2026-07-24 02:46:23.475582	76	100.00	Laptop	t
73	24	3	\N	2026-07-22 18:42:00.074462	104	100.00	Game Console	t
74	24	13	\N	2026-08-27 06:57:16.902776	119	100.00	Laptop	t
75	25	23	142	2026-07-20 10:03:29.962064	23	100.00	Tablet	t
76	25	12	\N	2026-05-04 05:58:31.293644	27	100.00	Phone	t
77	25	27	209	2026-06-07 02:08:28.692314	79	100.00	Phone	t
78	25	27	212	2026-05-27 04:01:14.652577	36	50.79	Laptop	f
79	26	8	\N	2026-08-13 06:51:19.303608	146	100.00	Game Console	t
80	26	13	\N	2026-05-30 09:36:55.988959	27	16.68	Smart TV	f
81	26	12	\N	2026-05-09 14:11:18.060251	109	52.31	Game Console	f
82	27	6	\N	2026-04-01 12:34:18.418298	137	45.50	Phone	f
83	27	14	\N	2026-04-26 21:43:43.502086	51	62.58	Laptop	f
84	28	29	232	2026-04-08 16:18:19.792422	82	51.63	Laptop	f
85	28	15	\N	2026-08-10 04:46:17.958037	137	36.14	Phone	f
86	28	20	80	2026-07-19 19:15:47.934138	37	54.58	Phone	f
87	28	17	33	2026-03-10 09:32:58.764671	44	58.26	Laptop	f
88	28	27	217	2026-08-27 16:16:30.27398	12	55.73	Smart TV	f
89	29	28	227	2026-06-04 08:03:34.238711	111	74.03	Game Console	f
90	29	23	153	2026-07-17 16:01:43.415391	82	100.00	Tablet	t
91	30	26	196	2026-08-29 03:38:41.734452	23	100.00	Smart TV	t
92	30	7	\N	2026-08-24 11:23:28.497015	57	100.00	Phone	t
93	30	21	107	2026-03-17 23:31:42.262759	93	100.00	Tablet	t
94	31	24	163	2026-06-27 14:16:24.257981	66	100.00	Tablet	t
95	31	8	\N	2026-04-17 08:24:29.311461	29	100.00	Smart TV	t
96	31	7	\N	2026-07-26 16:36:45.969006	45	42.63	Phone	f
97	32	3	\N	2026-08-14 02:55:43.545557	136	100.00	Tablet	t
98	32	5	\N	2026-03-09 21:47:55.295639	28	100.00	Tablet	t
99	32	19	71	2026-08-28 13:34:02.58631	17	100.00	Smart TV	t
100	32	10	\N	2026-04-08 18:01:12.031961	125	63.88	Phone	f
101	33	22	112	2026-08-01 04:59:26.027251	108	70.48	Phone	f
102	33	1	\N	2026-07-23 05:50:45.249706	54	100.00	Phone	t
103	34	9	\N	2026-05-03 11:06:23.580232	145	100.00	Phone	t
104	34	25	171	2026-07-30 21:05:17.650412	29	100.00	Tablet	t
105	34	6	\N	2026-07-31 23:21:54.730231	98	100.00	Laptop	t
106	34	9	\N	2026-03-31 20:17:45.897436	15	100.00	Smart TV	t
107	35	6	\N	2026-06-15 20:24:42.494484	43	51.74	Game Console	f
108	35	18	54	2026-07-24 20:28:46.964736	105	33.67	Game Console	f
109	36	24	163	2026-07-05 00:49:52.15354	149	100.00	Phone	t
110	36	1	\N	2026-08-13 12:33:47.062546	33	100.00	Tablet	t
111	36	28	223	2026-03-04 20:27:00.93241	72	100.00	Game Console	t
112	36	27	208	2026-07-05 13:41:04.316313	48	100.00	Game Console	t
113	37	11	\N	2026-08-19 15:39:14.516078	33	100.00	Laptop	t
114	37	6	\N	2026-06-10 13:45:31.995607	110	100.00	Laptop	t
115	37	13	\N	2026-06-10 11:34:45.043307	20	47.44	Laptop	f
116	37	24	160	2026-04-03 01:26:44.695999	101	48.05	Phone	f
117	37	23	153	2026-08-27 00:50:00.200392	95	100.00	Phone	t
118	38	4	\N	2026-08-07 14:50:18.893218	81	100.00	Laptop	t
119	38	20	81	2026-05-28 13:04:52.550162	130	67.12	Phone	f
120	38	9	\N	2026-04-25 02:41:33.885389	75	76.59	Phone	f
121	38	11	\N	2026-05-28 05:14:19.946704	106	100.00	Phone	t
122	38	28	225	2026-03-16 04:15:45.282932	78	100.00	Smart TV	t
123	39	26	192	2026-04-11 03:53:38.083419	142	24.26	Phone	f
124	39	27	215	2026-04-08 15:22:48.494444	66	100.00	Laptop	t
125	39	15	\N	2026-06-03 18:59:20.874126	64	100.00	Smart TV	t
126	39	6	\N	2026-02-27 19:53:09.552062	40	14.05	Smart TV	f
127	40	15	\N	2026-08-14 05:43:04.184206	56	47.81	Phone	f
128	40	11	\N	2026-04-05 11:24:09.527151	27	100.00	Game Console	t
129	40	12	\N	2026-03-23 12:29:55.641258	49	89.30	Tablet	f
130	41	16	13	2026-07-08 13:25:22.460498	79	21.77	Smart TV	f
131	41	10	\N	2026-08-14 09:35:34.10746	90	88.56	Phone	f
132	41	11	\N	2026-07-31 19:15:41.39785	131	100.00	Laptop	t
133	42	13	\N	2026-04-27 18:21:58.538121	46	100.00	Tablet	t
134	42	27	212	2026-03-03 16:52:51.413453	91	100.00	Phone	t
135	42	28	226	2026-06-14 18:31:18.133493	108	100.00	Tablet	t
136	42	17	29	2026-08-14 02:46:26.320809	40	21.63	Tablet	f
137	42	4	\N	2026-07-19 00:59:20.058702	103	100.00	Laptop	t
138	43	21	94	2026-08-01 04:53:04.354321	7	100.00	Phone	t
139	43	27	214	2026-08-03 19:02:14.386054	35	100.00	Tablet	t
140	43	7	\N	2026-08-22 00:36:01.219869	84	88.08	Smart TV	f
141	43	20	82	2026-05-06 21:23:55.985223	39	24.72	Tablet	f
142	43	12	\N	2026-08-18 14:58:03.873277	145	38.63	Tablet	f
143	44	26	203	2026-05-10 21:47:25.416327	119	12.37	Game Console	f
144	44	17	35	2026-03-18 03:27:40.842999	145	100.00	Game Console	t
145	44	9	\N	2026-04-23 18:46:05.394129	88	100.00	Game Console	t
146	45	4	\N	2026-03-24 14:36:56.703029	135	48.99	Tablet	f
147	45	23	140	2026-03-28 10:50:04.441429	121	100.00	Game Console	t
148	45	8	\N	2026-08-19 20:37:29.955414	10	32.74	Tablet	f
149	45	1	\N	2026-07-22 05:32:32.238081	16	57.05	Tablet	f
150	45	2	\N	2026-08-22 01:03:11.022724	20	100.00	Smart TV	t
151	46	7	\N	2026-06-26 04:36:47.212187	39	100.00	Tablet	t
152	46	15	\N	2026-03-31 11:58:59.737842	101	100.00	Tablet	t
153	46	11	\N	2026-08-23 12:27:02.977106	94	16.97	Smart TV	f
154	46	9	\N	2026-07-04 07:01:09.832645	37	100.00	Laptop	t
155	46	28	223	2026-08-16 05:40:47.299803	144	46.67	Tablet	f
156	47	19	75	2026-07-21 08:17:37.507465	75	100.00	Laptop	t
157	47	27	210	2026-04-09 10:46:41.143953	112	100.00	Game Console	t
158	47	30	249	2026-06-15 04:46:34.762257	22	100.00	Smart TV	t
159	47	23	137	2026-03-31 17:00:58.509302	16	100.00	Tablet	t
160	47	9	\N	2026-04-24 16:55:29.870111	19	100.00	Laptop	t
161	48	15	\N	2026-07-03 08:50:44.1209	87	33.70	Laptop	f
162	48	3	\N	2026-03-22 22:44:20.072935	110	51.91	Phone	f
163	48	9	\N	2026-07-10 17:31:16.933091	49	84.17	Tablet	f
164	48	16	12	2026-08-19 21:02:21.333205	139	65.42	Phone	f
165	49	5	\N	2026-08-19 20:38:42.934933	142	100.00	Tablet	t
166	49	4	\N	2026-05-10 04:17:38.992579	41	100.00	Tablet	t
167	49	24	161	2026-08-28 04:19:45.523725	39	55.16	Tablet	f
168	49	4	\N	2026-08-22 20:51:39.208303	25	100.00	Tablet	t
169	49	17	34	2026-03-05 14:44:38.047854	73	22.14	Tablet	f
170	50	19	76	2026-06-17 15:38:36.435984	58	100.00	Phone	t
171	50	15	\N	2026-08-14 19:28:53.150518	53	100.00	Smart TV	t
172	51	27	213	2026-08-23 07:08:42.513545	66	100.00	Game Console	t
173	51	5	\N	2026-04-09 00:31:09.015883	141	100.00	Phone	t
174	51	6	\N	2026-06-10 22:16:24.551651	132	100.00	Tablet	t
175	51	12	\N	2026-08-17 16:02:02.725271	86	100.00	Laptop	t
176	51	7	\N	2026-03-25 08:58:38.660707	61	100.00	Laptop	t
177	52	15	\N	2026-07-13 17:51:12.550783	111	100.00	Phone	t
178	52	6	\N	2026-04-12 03:25:42.004714	150	100.00	Laptop	t
179	53	26	194	2026-08-26 00:11:10.951143	130	100.00	Tablet	t
180	53	12	\N	2026-03-30 08:19:09.896795	144	20.23	Tablet	f
181	53	15	\N	2026-08-08 07:01:10.588932	20	100.00	Game Console	t
182	53	14	\N	2026-03-15 21:33:16.084755	17	100.00	Smart TV	t
183	53	14	\N	2026-07-07 02:30:09.034599	43	11.12	Smart TV	f
184	54	21	86	2026-06-24 08:28:06.552329	128	65.01	Tablet	f
185	54	9	\N	2026-08-08 12:51:35.765229	8	100.00	Smart TV	t
186	54	20	81	2026-05-20 05:20:43.57738	115	100.00	Laptop	t
187	55	24	157	2026-04-17 02:38:59.049893	139	100.00	Phone	t
188	55	20	83	2026-04-14 06:00:02.536529	108	100.00	Tablet	t
189	56	19	72	2026-03-12 01:51:56.241433	13	81.31	Smart TV	f
190	56	7	\N	2026-04-15 13:10:36.927169	19	100.00	Smart TV	t
191	56	17	32	2026-03-19 10:08:07.275743	89	63.04	Game Console	f
192	57	30	250	2026-02-27 22:30:14.505216	150	100.00	Tablet	t
193	57	15	\N	2026-05-09 03:28:54.059835	76	100.00	Game Console	t
194	58	14	\N	2026-07-11 09:57:49.215263	58	100.00	Game Console	t
195	58	14	\N	2026-08-23 14:01:23.18622	24	40.85	Phone	f
196	59	25	180	2026-08-08 03:39:15.403807	103	53.65	Laptop	f
197	59	27	209	2026-05-28 16:49:39.91878	93	100.00	Smart TV	t
198	59	4	\N	2026-05-07 19:50:05.29437	106	35.65	Phone	f
199	60	28	230	2026-06-07 08:44:20.45177	96	100.00	Game Console	t
200	60	22	113	2026-03-18 05:11:51.796909	26	64.46	Game Console	f
201	61	27	209	2026-05-26 05:17:06.057687	44	100.00	Tablet	t
202	61	26	188	2026-08-04 09:50:55.839993	32	33.50	Smart TV	f
203	61	5	\N	2026-06-26 12:27:03.946578	74	100.00	Smart TV	t
204	61	3	\N	2026-07-03 02:59:03.666874	147	100.00	Game Console	t
205	62	2	\N	2026-03-29 09:24:19.947702	28	100.00	Game Console	t
206	62	21	97	2026-03-13 03:46:28.024429	110	100.00	Tablet	t
207	62	27	214	2026-08-01 01:44:15.325672	48	100.00	Tablet	t
208	62	5	\N	2026-04-22 12:43:59.613699	131	100.00	Laptop	t
209	62	7	\N	2026-04-26 21:01:29.947478	81	100.00	Tablet	t
210	63	4	\N	2026-08-20 09:37:43.960616	55	49.62	Tablet	f
211	63	5	\N	2026-03-13 05:55:31.153351	106	100.00	Phone	t
212	64	21	99	2026-03-30 18:02:03.785079	39	100.00	Phone	t
213	64	12	\N	2026-05-07 05:34:39.707397	85	100.00	Laptop	t
214	64	21	94	2026-07-11 07:20:16.694785	67	61.96	Phone	f
215	64	14	\N	2026-06-07 13:13:01.701733	149	37.85	Laptop	f
216	64	24	157	2026-08-10 15:06:24.920327	123	54.51	Laptop	f
217	65	29	233	2026-03-16 16:44:06.563979	109	76.61	Tablet	f
218	65	5	\N	2026-06-16 03:01:51.103394	44	100.00	Tablet	t
219	65	17	31	2026-06-19 16:57:01.414168	107	48.13	Game Console	f
220	65	30	271	2026-05-26 19:30:38.818517	14	100.00	Phone	t
221	65	28	224	2026-03-05 08:39:25.397751	68	100.00	Phone	t
222	66	16	13	2026-08-18 17:14:29.065974	115	34.84	Smart TV	f
223	66	5	\N	2026-03-29 19:39:31.882159	137	100.00	Game Console	t
224	66	25	175	2026-08-09 02:26:18.061382	105	100.00	Tablet	t
225	67	1	\N	2026-03-28 09:04:54.836279	80	100.00	Tablet	t
226	67	17	20	2026-03-18 04:26:59.136925	94	70.71	Phone	f
227	67	13	\N	2026-04-06 05:18:06.108112	128	100.00	Phone	t
228	68	12	\N	2026-04-03 09:06:51.066451	81	33.70	Smart TV	f
229	68	17	17	2026-07-04 22:56:53.381539	47	63.32	Laptop	f
230	68	24	157	2026-07-09 11:45:55.514794	114	100.00	Tablet	t
231	68	7	\N	2026-07-10 22:31:42.516491	115	21.77	Tablet	f
232	68	10	\N	2026-04-17 02:52:44.260632	114	45.46	Tablet	f
233	69	19	72	2026-04-20 02:05:53.293956	21	77.79	Game Console	f
234	69	14	\N	2026-04-12 01:28:02.840485	98	100.00	Phone	t
235	70	5	\N	2026-03-08 18:19:08.435877	85	49.05	Game Console	f
236	70	7	\N	2026-06-12 01:31:05.348529	94	100.00	Phone	t
237	70	25	173	2026-07-30 23:51:28.100991	81	68.54	Game Console	f
238	71	21	88	2026-03-27 17:41:22.490867	34	100.00	Laptop	t
239	71	3	\N	2026-05-04 13:29:44.942287	112	100.00	Game Console	t
240	72	22	113	2026-05-16 18:00:40.640099	142	100.00	Laptop	t
241	72	23	145	2026-04-22 11:09:35.692747	85	100.00	Tablet	t
242	72	29	242	2026-06-28 12:51:29.894674	54	48.61	Tablet	f
245	1	8	\N	2026-08-29 05:28:45.686551	140	96.55	Phone	t
\.


--
-- Name: account_accountid_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.account_accountid_seq', 25, true);


--
-- Name: episode_episodeid_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.episode_episodeid_seq', 272, true);


--
-- Name: genre_genreid_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.genre_genreid_seq', 22, true);


--
-- Name: person_personid_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.person_personid_seq', 40, true);


--
-- Name: plan_planid_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.plan_planid_seq', 20, true);


--
-- Name: profile_profileid_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.profile_profileid_seq', 74, true);


--
-- Name: season_seasonid_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.season_seasonid_seq', 34, true);


--
-- Name: title_titleid_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.title_titleid_seq', 30, true);


--
-- Name: watchhistory_watchid_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.watchhistory_watchid_seq', 246, true);


--
-- Name: account account_email_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account
    ADD CONSTRAINT account_email_key UNIQUE (email);


--
-- Name: account account_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account
    ADD CONSTRAINT account_pkey PRIMARY KEY (accountid);


--
-- Name: credit credit_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.credit
    ADD CONSTRAINT credit_pkey PRIMARY KEY (titleid, personid, roletype);


--
-- Name: episode episode_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.episode
    ADD CONSTRAINT episode_pkey PRIMARY KEY (episodeid);


--
-- Name: episode episode_seasonid_episodenumber_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.episode
    ADD CONSTRAINT episode_seasonid_episodenumber_key UNIQUE (seasonid, episodenumber);


--
-- Name: genre genre_genrename_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.genre
    ADD CONSTRAINT genre_genrename_key UNIQUE (genrename);


--
-- Name: genre genre_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.genre
    ADD CONSTRAINT genre_pkey PRIMARY KEY (genreid);


--
-- Name: mylist mylist_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mylist
    ADD CONSTRAINT mylist_pkey PRIMARY KEY (profileid, titleid);


--
-- Name: person person_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.person
    ADD CONSTRAINT person_pkey PRIMARY KEY (personid);


--
-- Name: plan plan_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plan
    ADD CONSTRAINT plan_pkey PRIMARY KEY (planid);


--
-- Name: plan plan_planname_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plan
    ADD CONSTRAINT plan_planname_key UNIQUE (planname);


--
-- Name: profile profile_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profile
    ADD CONSTRAINT profile_pkey PRIMARY KEY (profileid);


--
-- Name: rating rating_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rating
    ADD CONSTRAINT rating_pkey PRIMARY KEY (profileid, titleid);


--
-- Name: season season_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.season
    ADD CONSTRAINT season_pkey PRIMARY KEY (seasonid);


--
-- Name: season season_titleid_seasonnumber_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.season
    ADD CONSTRAINT season_titleid_seasonnumber_key UNIQUE (titleid, seasonnumber);


--
-- Name: title title_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.title
    ADD CONSTRAINT title_pkey PRIMARY KEY (titleid);


--
-- Name: titlegenre titlegenre_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.titlegenre
    ADD CONSTRAINT titlegenre_pkey PRIMARY KEY (titleid, genreid);


--
-- Name: watchhistory watchhistory_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.watchhistory
    ADD CONSTRAINT watchhistory_pkey PRIMARY KEY (watchid);


--
-- Name: idx_credit_person; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_credit_person ON public.credit USING btree (personid);


--
-- Name: idx_episode_season; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_episode_season ON public.episode USING btree (seasonid, episodenumber);


--
-- Name: idx_person_fullname; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_person_fullname ON public.person USING btree (fullname);


--
-- Name: idx_profile_account; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_profile_account ON public.profile USING btree (accountid);


--
-- Name: idx_rating_title; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rating_title ON public.rating USING btree (titleid);


--
-- Name: idx_title_type_rating; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_title_type_rating ON public.title USING btree (titletype, maturityrating);


--
-- Name: idx_watchhistory_profile; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_watchhistory_profile ON public.watchhistory USING btree (profileid, watchdate DESC);


--
-- Name: idx_watchhistory_title; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_watchhistory_title ON public.watchhistory USING btree (titleid);


--
-- Name: watchhistory trg_enforcekidsmaturity; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_enforcekidsmaturity BEFORE INSERT ON public.watchhistory FOR EACH ROW EXECUTE FUNCTION public.trgfn_enforcekidsmaturity();


--
-- Name: profile trg_limitprofilesperaccount; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_limitprofilesperaccount BEFORE INSERT ON public.profile FOR EACH ROW EXECUTE FUNCTION public.trgfn_limitprofilesperaccount();


--
-- Name: episode trg_maintainepisodecount; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_maintainepisodecount AFTER INSERT OR DELETE ON public.episode FOR EACH ROW EXECUTE FUNCTION public.trgfn_maintainepisodecount();


--
-- Name: season trg_seasononlyforseries; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_seasononlyforseries BEFORE INSERT ON public.season FOR EACH ROW EXECUTE FUNCTION public.trgfn_seasononlyforseries();


--
-- Name: watchhistory trg_watchhistoryepisodeconsistency; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_watchhistoryepisodeconsistency BEFORE INSERT OR UPDATE ON public.watchhistory FOR EACH ROW EXECUTE FUNCTION public.trgfn_watchhistoryepisodeconsistency();


--
-- Name: account account_planid_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account
    ADD CONSTRAINT account_planid_fkey FOREIGN KEY (planid) REFERENCES public.plan(planid) ON DELETE RESTRICT;


--
-- Name: credit credit_personid_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.credit
    ADD CONSTRAINT credit_personid_fkey FOREIGN KEY (personid) REFERENCES public.person(personid) ON DELETE CASCADE;


--
-- Name: credit credit_titleid_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.credit
    ADD CONSTRAINT credit_titleid_fkey FOREIGN KEY (titleid) REFERENCES public.title(titleid) ON DELETE CASCADE;


--
-- Name: episode episode_seasonid_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.episode
    ADD CONSTRAINT episode_seasonid_fkey FOREIGN KEY (seasonid) REFERENCES public.season(seasonid) ON DELETE CASCADE;


--
-- Name: mylist mylist_profileid_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mylist
    ADD CONSTRAINT mylist_profileid_fkey FOREIGN KEY (profileid) REFERENCES public.profile(profileid) ON DELETE CASCADE;


--
-- Name: mylist mylist_titleid_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mylist
    ADD CONSTRAINT mylist_titleid_fkey FOREIGN KEY (titleid) REFERENCES public.title(titleid) ON DELETE CASCADE;


--
-- Name: profile profile_accountid_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profile
    ADD CONSTRAINT profile_accountid_fkey FOREIGN KEY (accountid) REFERENCES public.account(accountid) ON DELETE CASCADE;


--
-- Name: rating rating_profileid_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rating
    ADD CONSTRAINT rating_profileid_fkey FOREIGN KEY (profileid) REFERENCES public.profile(profileid) ON DELETE CASCADE;


--
-- Name: rating rating_titleid_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rating
    ADD CONSTRAINT rating_titleid_fkey FOREIGN KEY (titleid) REFERENCES public.title(titleid) ON DELETE CASCADE;


--
-- Name: season season_titleid_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.season
    ADD CONSTRAINT season_titleid_fkey FOREIGN KEY (titleid) REFERENCES public.title(titleid) ON DELETE CASCADE;


--
-- Name: titlegenre titlegenre_genreid_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.titlegenre
    ADD CONSTRAINT titlegenre_genreid_fkey FOREIGN KEY (genreid) REFERENCES public.genre(genreid) ON DELETE CASCADE;


--
-- Name: titlegenre titlegenre_titleid_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.titlegenre
    ADD CONSTRAINT titlegenre_titleid_fkey FOREIGN KEY (titleid) REFERENCES public.title(titleid) ON DELETE CASCADE;


--
-- Name: watchhistory watchhistory_episodeid_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.watchhistory
    ADD CONSTRAINT watchhistory_episodeid_fkey FOREIGN KEY (episodeid) REFERENCES public.episode(episodeid) ON DELETE CASCADE;


--
-- Name: watchhistory watchhistory_profileid_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.watchhistory
    ADD CONSTRAINT watchhistory_profileid_fkey FOREIGN KEY (profileid) REFERENCES public.profile(profileid) ON DELETE CASCADE;


--
-- Name: watchhistory watchhistory_titleid_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.watchhistory
    ADD CONSTRAINT watchhistory_titleid_fkey FOREIGN KEY (titleid) REFERENCES public.title(titleid) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

\unrestrict l2TIC8wSzKnmQgvHnyDBcrkjMkjxDB9qNq9DlMn6E8WC8HKKqypTE0oEm4fEw7a

