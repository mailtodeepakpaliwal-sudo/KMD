-- Make an existing login (created in Authentication → Users) the school admin.
-- Put your email in place of the example, then run in the SQL Editor.
insert into vppsone.staff_profiles (user_id, display_name, short_name, role, is_active)
select u.id, 'Principal', 'Principal', 'admin', true
from auth.users u where lower(u.email) = lower('principal@example.com')
on conflict (user_id) do update set role = 'admin', is_active = true;
