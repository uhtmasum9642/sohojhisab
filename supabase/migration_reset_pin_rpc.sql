-- =====================================================================
-- সহজ হিসাব — মাইগ্রেশন (৩০ অক্টোবর ২০২৬): পিন-রিসেট এখন ডাটাবেজের ভেতরের ফাংশনে
-- Supabase → SQL Editor → New query → পুরোটা পেস্ট করে RUN চাপুন (একাধিকবার রান করলেও ক্ষতি নেই)
--
-- কেন: আগের `reset-pin` Edge Function পুরোনো ধরনের চাবি (SUPABASE_ANON_KEY / SERVICE_ROLE_KEY)
-- চাইত; নতুন চাবির প্রজেক্টে সেটা 401 দিচ্ছিল। এই ফাংশনে কোনো চাবি লাগে না —
-- অ্যাপ সরাসরি `sb.rpc('admin_reset_pin', ...)` ডাকে, আর শুধু অ্যাডমিন চালাতে পারেন।
-- (চাইলে পরে Supabase → Edge Functions থেকে পুরোনো `reset-pin` ফাংশনটা মুছে দিতে পারেন)
-- =====================================================================

create or replace function public.admin_reset_pin(p_user uuid, p_request uuid default null)
returns json
language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_email text;
  v_pin text := (100000 + ('x' || encode(extensions.gen_random_bytes(3), 'hex'))::bit(24)::int % 900000)::text;
begin
  if not public.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  -- শুধু ফোন-নাম্বারের অ্যাকাউন্ট (…@khata.app)
  select email into v_email from auth.users where id = p_user;
  if v_email is null or v_email not like '%@khata.app' then
    raise exception 'not_phone_account' using errcode = '22023';
  end if;

  -- নতুন পিন বসানো; আগের metadata (যেমন full_name) ঠিক রেখে must_change_pin = true
  update auth.users
     set encrypted_password = extensions.crypt(v_pin, extensions.gen_salt('bf')),
         raw_user_meta_data = coalesce(raw_user_meta_data, '{}'::jsonb) || '{"must_change_pin": true}'::jsonb,
         updated_at = now()
   where id = p_user;

  -- এই নাম্বারের অপেক্ষমাণ অনুরোধ "সম্পন্ন"
  update public.pin_reset_requests
     set status = 'done', handled_at = now()
   where status = 'pending' and (id = p_request or phone = split_part(v_email, '@', 1));

  return json_build_object('pin', v_pin, 'phone', split_part(v_email, '@', 1));
end $$;

revoke all on function public.admin_reset_pin(uuid, uuid) from public, anon;
grant execute on function public.admin_reset_pin(uuid, uuid) to authenticated;

-- অ্যাপ যেন নতুন ফাংশন সাথে সাথে চেনে
notify pgrst, 'reload schema';

-- যাচাই: true আসা উচিত
select exists (select 1 from pg_proc where proname = 'admin_reset_pin') as reset_function_ok;
