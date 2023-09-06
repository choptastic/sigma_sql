grant all on database sql_bridge_test to sql_bridge_user;
alter default privileges
  in schema public
  grant select, insert, update, delete on tables to sql_bridge_user;

ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, USAGE ON sequences TO sql_bridge_user;

drop table if exists fruit;
create table fruit (
	fruitid serial primary key,
	fruit varchar(50),
	description text,
	quantity integer,
	picture bytea,
	some_float float
);

drop table if exists other;
create table other (
	otherid serial primary key,
	my_time time,
	my_date date,
	my_decimal decimal(6,2),
	my_datetime timestamp
);
