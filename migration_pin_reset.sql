-- Supabase SQL Editor-এ একবার রান করুন (পিন-রিসেট অনুরোধের টেবিল)

create table if not exists pin_reset_requests (
  id uuid primary key default gen_random_uuid(),
  phone text not null,
  status text not null default 'pending',      -- pending | done
  created_at timestamptz not null default now(),
  handled_at timestamptz
);

-- একই নাম্বারের একটাই "অপেক্ষমাণ" অনুরোধ থাকবে (বারবার চাপলে ডুপ্লিকেট জমবে না)
create unique index if not exists one_pending_per_phone
  on pin_reset_requests(phone) where status = 'pending';

alter table pin_reset_requests enable row level security;

-- লগইন ছাড়াই (ভুলে-যাওয়া ইউজার) শুধু অনুরোধ পাঠাতে পারবে; কিছু পড়তে পারবে না
drop policy if exists "anyone can request" on pin_reset_requests;
create policy "anyone can request" on pin_reset_requests
  for insert to anon, authenticated
  with check (status = 'pending' and phone ~ '^01[3-9][0-9]{8}$');

-- শুধু অ্যাডমিন দেখতে ও আপডেট করতে পারবে
drop policy if exists "admin reads requests" on pin_reset_requests;
create policy "admin reads requests" on pin_reset_requests
  for select to authenticated
  using (exists (select 1 from profiles p where p.id = auth.uid() and p.is_admin));

drop policy if exists "admin updates requests" on pin_reset_requests;
create policy "admin updates requests" on pin_reset_requests
  for update to authenticated
  using (exists (select 1 from profiles p where p.id = auth.uid() and p.is_admin))
  with check (exists (select 1 from profiles p where p.id = auth.uid() and p.is_admin));
