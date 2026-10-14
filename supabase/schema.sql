-- =====================================================================
-- সহজ হিসাব — সম্পূর্ণ ডাটাবেজ সেটআপ (ফাঁকা Supabase প্রজেক্টের জন্য)
-- Supabase → SQL Editor → New query → পুরোটা পেস্ট করে RUN চাপুন
-- (একাধিকবার রান করলেও ক্ষতি নেই)
-- =====================================================================

-- ---------- ১) টেবিল ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  email text,
  is_admin boolean not null default false,
  access_expires_at timestamptz,          -- null = আজীবন
  last_active_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.app_config (
  id int primary key default 1,
  contact_phone text,
  contact_whatsapp text,                  -- 8801XXXXXXXXX (দেশ-কোডসহ)
  contact_email text,
  payment_instructions text,
  updated_at timestamptz default now(),
  constraint app_config_single_row check (id = 1)
);
insert into public.app_config (id) values (1) on conflict (id) do nothing;

create table if not exists public.accounts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  account_name text not null,
  account_type text not null default 'cash',
  opening_balance numeric(14,2) not null default 0,
  current_balance numeric(14,2) not null default 0,
  is_default boolean not null default false,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.contacts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  contact_name text not null,
  contact_type text not null default 'personal',
  phone text,
  opening_balance numeric(14,2) not null default 0,   -- ধনাত্মক = সে আমাকে দেবে
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.transactions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  transaction_no text not null,
  transaction_date date not null default current_date,
  transaction_type text not null
    check (transaction_type in ('income','expense','receivable','payable','receive_due','pay_due','expense_credit','income_credit')),
  status text not null default 'completed',
  account_id uuid references public.accounts(id) on delete set null,
  contact_id uuid references public.contacts(id) on delete set null,
  total_amount numeric(14,2) not null check (total_amount >= 0),
  paid_amount numeric(14,2) not null default 0,
  due_amount numeric(14,2) not null default 0,
  notes text,
  category text,                            -- খাবার/বাজার/মজুরি... (না বাছলে null)
  created_at timestamptz not null default now(),
  deleted_at timestamptz                   -- মুছলে এটা সেট হয় (ট্র্যাশ); আসলে ডিলিট হয় না
);
create unique index if not exists transactions_user_txno on public.transactions(user_id, transaction_no);
create index if not exists transactions_user_date on public.transactions(user_id, transaction_date desc);
create index if not exists transactions_contact on public.transactions(contact_id);
create index if not exists contacts_user on public.contacts(user_id);

create table if not exists public.pin_reset_requests (
  id uuid primary key default gen_random_uuid(),
  phone text not null,
  status text not null default 'pending',   -- pending | done
  created_at timestamptz not null default now(),
  handled_at timestamptz
);
create unique index if not exists one_pending_per_phone
  on public.pin_reset_requests(phone) where status = 'pending';

-- ---------- ২) অ্যাডমিন চেনার ফাংশন (RLS-এ লুপ এড়াতে SECURITY DEFINER) ----------
create or replace function public.is_admin() returns boolean
language sql security definer stable set search_path = public as $$
  select coalesce((select is_admin from public.profiles where id = auth.uid()), false)
$$;

-- ---------- ৩) নতুন ইউজার অ্যাকাউন্ট খুললে প্রোফাইল নিজে বানানো ----------
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name, email, access_expires_at, last_active_at)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', ''),
    new.email,
    null,            -- ★ আজীবন। ৩০ দিনের ট্রায়াল চাইলে null-এর জায়গায় লিখুন: now() + interval '30 days'
    now()
  )
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- সাধারণ ইউজার নিজের মেয়াদ/অ্যাডমিন-অধিকার/email বদলাতে পারবে না (শুধু অ্যাডমিন বা সার্ভার পারবে)
create or replace function public.protect_profile_fields() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.is_admin() then
    if new.is_admin is distinct from old.is_admin
       or new.access_expires_at is distinct from old.access_expires_at
       or new.email is distinct from old.email
       or new.id is distinct from old.id then
      raise exception 'not allowed';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists protect_profile_fields on public.profiles;
create trigger protect_profile_fields before update on public.profiles
  for each row execute function public.protect_profile_fields();

-- ---------- ৪) নিরাপত্তা-নিয়ম (Row Level Security) ----------
alter table public.profiles            enable row level security;
alter table public.app_config          enable row level security;
alter table public.accounts            enable row level security;
alter table public.contacts            enable row level security;
alter table public.transactions        enable row level security;
alter table public.pin_reset_requests  enable row level security;

-- profiles: নিজেরটা দেখা/আপডেট; অ্যাডমিন সবার
drop policy if exists "profiles read own or admin" on public.profiles;
create policy "profiles read own or admin" on public.profiles for select to authenticated
  using (id = auth.uid() or public.is_admin());
drop policy if exists "profiles update own or admin" on public.profiles;
create policy "profiles update own or admin" on public.profiles for update to authenticated
  using (id = auth.uid() or public.is_admin()) with check (id = auth.uid() or public.is_admin());

-- app_config: যোগাযোগের তথ্য সবাই পড়তে পারবে (মেয়াদ-শেষ স্ক্রিন ও পিন-ভুলে-গেছি স্ক্রিনে লাগে); বদলাবে শুধু অ্যাডমিন
drop policy if exists "config read all" on public.app_config;
create policy "config read all" on public.app_config for select to anon, authenticated using (true);
drop policy if exists "config admin update" on public.app_config;
create policy "config admin update" on public.app_config for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- accounts / contacts / transactions: প্রত্যেকে শুধু নিজের ডাটা (অ্যাডমিনও অন্যের হিসাব দেখতে পারে না)
drop policy if exists "own accounts" on public.accounts;
create policy "own accounts" on public.accounts for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists "own contacts" on public.contacts;
create policy "own contacts" on public.contacts for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists "own transactions" on public.transactions;
create policy "own transactions" on public.transactions for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- পিন-রিসেট অনুরোধ: লগইন ছাড়াই শুধু জমা দেওয়া যাবে; দেখবে/বদলাবে শুধু অ্যাডমিন
drop policy if exists "anyone can request" on public.pin_reset_requests;
create policy "anyone can request" on public.pin_reset_requests for insert to anon, authenticated
  with check (status = 'pending' and phone ~ '^01[3-9][0-9]{8}$');
drop policy if exists "admin reads requests" on public.pin_reset_requests;
create policy "admin reads requests" on public.pin_reset_requests for select to authenticated
  using (public.is_admin());
drop policy if exists "admin updates requests" on public.pin_reset_requests;
create policy "admin updates requests" on public.pin_reset_requests for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- ---------- ৫) প্রথম অ্যাডমিন বানানো (অ্যাপে নিজের নাম্বারে অ্যাকাউন্ট খোলার পর, আলাদা করে রান করুন) ----------
-- update public.profiles set is_admin = true, access_expires_at = null
-- where email = '01XXXXXXXXX@khata.app';      -- ← নিজের নাম্বার বসান, আগের দুটো ড্যাশ (--) মুছে রান করুন
