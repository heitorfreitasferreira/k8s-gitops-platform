--
-- PostgreSQL database dump
--

\restrict CyKuikWMbm2fxg3iPq1D4JAqQ5POPqWrbhoYH7BmiWzwMbekaCMHKnjhqUCYelg

-- Dumped from database version 16.15
-- Dumped by pg_dump version 16.15

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

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: todo; Type: TABLE; Schema: public; Owner: todolist
--

CREATE TABLE public.todo (
    id integer NOT NULL,
    task character varying(200) NOT NULL,
    done boolean
);


ALTER TABLE public.todo OWNER TO todolist;

--
-- Name: todo_id_seq; Type: SEQUENCE; Schema: public; Owner: todolist
--

CREATE SEQUENCE public.todo_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.todo_id_seq OWNER TO todolist;

--
-- Name: todo_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: todolist
--

ALTER SEQUENCE public.todo_id_seq OWNED BY public.todo.id;


--
-- Name: todo id; Type: DEFAULT; Schema: public; Owner: todolist
--

ALTER TABLE ONLY public.todo ALTER COLUMN id SET DEFAULT nextval('public.todo_id_seq'::regclass);


--
-- Data for Name: todo; Type: TABLE DATA; Schema: public; Owner: todolist
--

COPY public.todo (id, task, done) FROM stdin;
\.


--
-- Name: todo_id_seq; Type: SEQUENCE SET; Schema: public; Owner: todolist
--

SELECT pg_catalog.setval('public.todo_id_seq', 1, false);


--
-- Name: todo todo_pkey; Type: CONSTRAINT; Schema: public; Owner: todolist
--

ALTER TABLE ONLY public.todo
    ADD CONSTRAINT todo_pkey PRIMARY KEY (id);


--
-- PostgreSQL database dump complete
--

\unrestrict CyKuikWMbm2fxg3iPq1D4JAqQ5POPqWrbhoYH7BmiWzwMbekaCMHKnjhqUCYelg

