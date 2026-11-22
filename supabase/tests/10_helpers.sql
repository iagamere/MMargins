create schema t;
grant usage on schema t to public;
create table t.results (name text, ok boolean, detail text);
grant all on t.results to public;

create function t.login(u uuid) returns void language plpgsql as $$
begin
  reset role;
  perform set_config('request.jwt.claim.sub', u::text, true);
  set local role authenticated;
end $$;
create function t.anon() returns void language plpgsql as $$
begin
  reset role;
  perform set_config('request.jwt.claim.sub', '', true);
  set local role anon;
end $$;
create function t.admin() returns void language plpgsql as $$
begin
  reset role;
  perform set_config('request.jwt.claim.sub', '', true);
end $$;

create function t.ok(n text, cond boolean) returns void language plpgsql as $$
begin
  insert into t.results values (n, coalesce(cond, false), null);
end $$;
create function t.eq(n text, got anyelement, want anyelement) returns void language plpgsql as $$
begin
  insert into t.results values (n, got is not distinct from want, 'got=' || coalesce(got::text, 'null') || ' want=' || coalesce(want::text, 'null'));
end $$;
-- passes when the statement fails (optionally with a message containing `expect`)
create function t.throws(n text, stmt text, expect text default null) returns void language plpgsql as $$
begin
  begin
    execute stmt;
    insert into t.results values (n, false, 'no error raised');
  exception when others then
    insert into t.results values (n, expect is null or sqlerrm ilike '%' || expect || '%', sqlerrm);
  end;
end $$;
