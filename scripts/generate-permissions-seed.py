#!/usr/bin/env python3
"""Generate supabase/migrations/20261127100013_authorisation_catalogue.sql from docs/PERMISSIONS_MATRIX.md.

  python3 scripts/generate-permissions-seed.py          # (re)write the migration
  python3 scripts/generate-permissions-seed.py --check  # exit 1 if the migration drifted from the matrix (test MTX-01)

Only the INSERT seed blocks depend on the matrix; the DDL header is a template inside this script.
Changing a permission or role mapping = edit the matrix, regenerate, add a NEW migration for already-deployed
databases (never edit an applied migration).
"""
import re, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
MATRIX = ROOT / "docs" / "PERMISSIONS_MATRIX.md"
OUT = ROOT / "supabase" / "migrations" / "20261127100013_authorisation_catalogue.sql"
SCOPE = {"O": "organisation", "C": "campus", "M": "ministry", "D": "department", "T": "team"}
ROLES = ["owner", "admin", "pastor", "worship_director", "department_leader", "team_leader", "production_lead", "member"]
ROLE_DEF = {
    "owner": ("Owner", "Church owner / lead administrator", ["organisation"]),
    "admin": ("Admin", "Church administrator", ["organisation", "campus"]),
    "pastor": ("Pastor", "Senior / worship / campus pastor: oversight and approval", ["organisation", "campus"]),
    "worship_director": ("Worship Director", "Worship or music director", ["organisation", "campus"]),
    "department_leader": ("Department Leader", "Head of a ministry or department", ["ministry", "department"]),
    "team_leader": ("Team Leader", "Leader of a team", ["team"]),
    "production_lead": ("Production Lead", "Technical director / head of sound, lighting or media", ["organisation", "campus", "department", "team"]),
    "member": ("Member", "Every ordinary member (musician, vocalist, operator, volunteer)", ["organisation"]),
}

def parse():
    pm = MATRIX.read_text()
    sec2 = pm[pm.index("## 2. Permission catalogue"):pm.index("### 2.9")]
    perms, cat = [], None
    for line in sec2.splitlines():
        h = re.match(r"^### 2\.\d (.+)$", line)
        if h:
            cat = h.group(1).split(" and ")[0].strip().lower().replace(",", "").replace(" ", "_"); continue
        m = re.match(r"^\| `([a-z_.]+)` \| ([OCMDT ]+) \| (✔?)\s*\| (.+) \|$", line)
        if m:
            perms.append((m.group(1), [SCOPE[x] for x in m.group(2).split()], bool(m.group(3)), m.group(4).replace("'", "''"), cat))
    sec4 = pm[pm.index("## 4. Permission × role matrix"):pm.index("### 4.1")]
    rp = {r: [] for r in ROLES}
    for key, row in re.findall(r"^\| `([a-z_.]+)` \|(.*)\|$", sec4, re.M):
        for role, cell in zip(ROLES, [c.strip() for c in row.split("|")]):
            if cell == "✔": rp[role].append(key)
    return perms, rp

def arr(l): return "'{" + ",".join(l) + "}'"

HEADER = """-- M-013: authorisation catalogue: permissions, roles, role_permissions.
-- The permission and role seed below is GENERATED from docs/PERMISSIONS_MATRIX.md (sections 2 and 4) by
-- scripts/generate-permissions-seed.py and verified by `npm run check:matrix` (test MTX-01).
-- Do not edit the INSERT blocks by hand: change the matrix and regenerate.
set lock_timeout = '10s';
set statement_timeout = '60s';

create table public.permissions (
  key text primary key check (key ~ '^[a-z_]+(\\.[a-z_]+)+$'),
  description text not null,
  category text not null,
  allowed_scopes text[] not null check (cardinality(allowed_scopes) > 0 and allowed_scopes <@ array['organisation','campus','ministry','department','team']),
  is_sensitive boolean not null default false,
  deprecated_at timestamptz
);
alter table public.permissions enable row level security;
alter table public.permissions force row level security;

create table public.roles (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid references public.organisations (id),   -- NULL = global SYSTEM role (read-only to clients)
  system_key text unique,
  name text not null check (char_length(name) between 1 and 100),
  description text check (description is null or char_length(description) <= 500),
  is_system boolean not null,
  assignable_scopes text[] not null check (cardinality(assignable_scopes) > 0 and assignable_scopes <@ array['organisation','campus','ministry','department','team']),
  show_in_directory boolean not null default false,
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (is_system = (organisation_id is null) and is_system = (system_key is not null)),
  unique (organisation_id, id)
);
create unique index roles_custom_name_uq on public.roles (organisation_id, lower(name)) where organisation_id is not null and archived_at is null;
alter table public.roles enable row level security;
alter table public.roles force row level security;
create trigger roles_set_updated_at before update on public.roles for each row execute function private.set_updated_at();

create table public.role_permissions (
  role_id uuid not null references public.roles (id) on delete cascade,
  permission_key text not null references public.permissions (key),
  primary key (role_id, permission_key)
);
create index role_permissions_permission_idx on public.role_permissions (permission_key);
alter table public.role_permissions enable row level security;
alter table public.role_permissions force row level security;

"""

def build():
    perms, rp = parse()
    assert len(perms) == 45, f"expected 45 permissions, found {len(perms)}"
    out = [HEADER, "insert into public.permissions (key, description, category, allowed_scopes, is_sensitive) values\n"]
    out.append(",\n".join(f"  ('{k}', '{d}', '{c}', {arr(s)}, {str(sens).lower()})" for k, s, sens, d, c in perms) + ";\n\n")
    out.append("insert into public.roles (id, system_key, name, description, is_system, assignable_scopes, show_in_directory) values\n")
    rows = []
    for i, r in enumerate(ROLES, 1):
        n, d, sc = ROLE_DEF[r]
        rows.append(f"  ('00000000-0000-4000-8000-{i:012d}', '{r}', '{n}', '{d}', true, {arr(sc)}, {str(r != 'member').lower()})")
    out.append(",\n".join(rows) + ";\n\n")
    out.append("insert into public.role_permissions (role_id, permission_key)\nselect r.id, v.permission_key from (values\n")
    out.append(",\n".join(f"  ('{r}', '{k}')" for r in ROLES for k in rp[r]))
    out.append("\n) as v (system_key, permission_key) join public.roles r on r.system_key = v.system_key;\n")
    return "".join(out)

if __name__ == "__main__":
    text = build()
    if "--check" in sys.argv:
        if OUT.read_text() != text:
            print("DRIFT: migration differs from PERMISSIONS_MATRIX.md. Run: python3 scripts/generate-permissions-seed.py"); sys.exit(1)
        print("ok: permission/role seed matches PERMISSIONS_MATRIX.md"); sys.exit(0)
    OUT.write_text(text); print(f"wrote {OUT.relative_to(ROOT)}")
