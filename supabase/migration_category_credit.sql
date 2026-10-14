-- =====================================================================
-- সহজ হিসাব — মাইগ্রেশন (১৫ অক্টোবর ২০২৬) — আগে থেকে চালু Supabase প্রজেক্টের জন্য
-- Supabase → SQL Editor → New query → পুরোটা পেস্ট করে RUN চাপুন
-- (একাধিকবার রান করলেও ক্ষতি নেই। নতুন ফাঁকা প্রজেক্টে শুধু schema.sql-ই যথেষ্ট)
--
-- যা ঠিক করে:
--   ১) transactions-এ category কলাম — অ্যাপ প্রতিটা হিসাবে এটা পাঠায়; কলাম না থাকায় কোনো হিসাব সার্ভারে জমা হচ্ছিল না
--   ২) নতুন দুই ধরন: expense_credit (বাকিতে খরচ), income_credit (বাকিতে আয়)
--   ৩) নতুন ইউজারের মেয়াদ: interval 'null' বাগে অ্যাকাউন্ট খোলা আটকে যেত → এখন আজীবন (null)
--   ৪) সাধারণ ইউজার নিজের profiles.email বদলাতে পারবে না (অ্যাডমিন পেজ ও পিন-রিসেট এটা দেখে নাম্বার চেনে)
-- =====================================================================

-- ---------- ১) category কলাম ----------
alter table public.transactions add column if not exists category text;

-- ---------- ২) transaction_type-এর নিয়ম: পুরোনো check (নাম যা-ই হোক) সরিয়ে নতুনটা ----------
do $$
declare c record;
begin
  for c in select conname from pg_constraint
           where conrelid = 'public.transactions'::regclass and contype = 'c'
             and pg_get_constraintdef(oid) ilike '%transaction_type%'
  loop
    execute format('alter table public.transactions drop constraint %I', c.conname);
  end loop;
end $$;
alter table public.transactions add constraint transactions_transaction_type_check
  check (transaction_type in ('income','expense','receivable','payable','receive_due','pay_due',
                              'expense_credit','income_credit',
                              'sale','purchase','transfer','opening_balance'));  -- শেষ ৪টা পুরোনো অ্যাপের ডাটা থাকলে যাতে আটকে না যায়

-- ---------- ৩) নতুন ইউজার অ্যাকাউন্ট খুললে প্রোফাইল (মেয়াদ আজীবন) ----------
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

-- ---------- ৪) সাধারণ ইউজার নিজের মেয়াদ/অ্যাডমিন-অধিকার/email বদলাতে পারবে না ----------
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

-- অ্যাপ যেন নতুন কলাম সাথে সাথে চেনে
notify pgrst, 'reload schema';

-- ---------- যাচাই: নিচের ফলাফলে দুটোই true আসা উচিত ----------
select
  exists (select 1 from information_schema.columns
          where table_schema = 'public' and table_name = 'transactions' and column_name = 'category') as category_column_ok,
  exists (select 1 from pg_constraint
          where conname = 'transactions_transaction_type_check'
            and pg_get_constraintdef(oid) like '%expense_credit%') as credit_types_ok;
