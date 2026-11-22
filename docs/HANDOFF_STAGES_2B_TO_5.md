# Margins — ملف تسليم للمحادثة التالية (المراحل 2ب → 5)

> أرسل هذا الملف + `margins_updated.zip` (+ ملف المواصفات الأصلي `Margins_Accounts_Libraries_Claude_Prompt.md` إن وُجد) لمحادثة جديدة، وقل لها: «اقرأ هذا الملف ثم المشروع، وأكمل من المرحلة 2ب». اللغة مع المستخدم: العربية. المستخدم لا يعدّل الكود يدويًا: يريد **ملف zip جاهزًا** في كل مرة.

## 1. المشروع
**Margins**: قارئ EPUB/PDF. React 18 + TypeScript + Vite + Capacitor 8، تخزين محلي IndexedDB، Zustand، ثلاث لغات (ar/fr/en) مع RTL، مزامنة Google Drive، وبناء APK عبر GitHub Actions. القراءة والمزامنة تعمل بلا حساب أونلاين، ولا يجوز كسر ذلك.

الميزة الجارية: **حسابات ومكتبات مشتركة** على Supabase (بدون SDK: `fetch` مباشر إلى GoTrue وPostgREST)، بتسجيل دخول **Google فقط**.

## 2. ما أُنجز
| المرحلة | الحالة |
|---|---|
| ألوان أبيض/أسود (فحمي/ثلجي) + `mono` افتراضي + أيقونة جديدة | منجز |
| 1: قاعدة البيانات + RLS + اختبارات + دخول Google→Supabase + ملف شخصي + حذف الحساب | منجز في الكود. المستخدم أنشأ مشروع Supabase وشغّل الـ3 migrations؛ **لم يصلني تأكيد أن الدخول يعمل فعليًا** |
| 2أ: شاشة «مكتبتي على الإنترنت»، إعدادات المكتبة، رفوف (إنشاء/تعديل/حذف/ترتيب)، خصوصية المكتبة والرفوف، كلمة المرور | منجز في الكود، **بانتظار تجربة المستخدم** |
| 2ب: إضافة كتب من الجهاز كسجلات (بيانات فقط + تأكيد الحقوق)، كتب داخل الرفوف (إضافة/إزالة/ترتيب)، خصوصية الكتاب وكلمة مرور وصلاحيات القراءة/التنزيل | منجز في الكود، بانتظار التجربة (الملفات: `src/components/OnlineBooks.tsx`, `AccessControls.tsx`) |
| 3أ: رفع الملفات إلى تخزين خاص (المالك فقط): `0004_storage.sql` (buckets + سياسات + `finalize_book_upload` + `my_book_hashes`) + زر الرفع في الواجهة + 28 اختبار SQL | منجز في الكود؛ **يحتاج المستخدم لتشغيل 0004 وتجربة الرفع** |
| 3ب (قراءة/تنزيل الزوار + روابط موقّعة + الاستيراد + زيارة مكتبة @handle)، 3ج (اكتشاف وبحث)، 4، 5 | لم تبدأ |

مهم: لا أحد شغّل `npm run typecheck` ولا `build` للتطبيق كاملًا (الشبكة كانت مغلقة). **أول خطوة في أي محادثة لها شبكة**: `npm i && npm run typecheck && npm test && npm run build` وإصلاح أي خطأ.

## 3. الملفات الأساسية
- `supabase/migrations/0001_tables.sql` الجداول والأنواع. `0002_access_functions.sql` دوال الخصوصية في schema `private`. `0003_security_and_rpcs.sql` RLS + الصلاحيات + RPCs. **اقرأ الثلاثة قبل أي عمل**.
- `supabase/tests/` (محاكاة Supabase + 133 فحص خصوصية). التشغيل أدناه.
- `src/lib/online.ts`: كل الاتصال بالخادم (`send` → `authed` مع تجديد الجلسة ومحاولة واحدة → `rpc`). الأخطاء `OnlineError` بأكواد (`offline, notSignedIn, sessionExpired, handleTaken, …, passwordInvalid, notFound, unknown`) وكل كود له ترجمة `online.err.<code>`. أي دالة جديدة تُضاف هنا وتُختبر في `tests/online.test.ts`.
- `src/lib/access.ts`: أنواع الوصول وأدوات (`effectiveShelfMode`, `isLoosening`).
- `src/store/useOnline.ts`: حالة الاتصال والملف الشخصي. `src/screens/OnlineLibrary.tsx` شاشة 2أ. `src/components/OnlineProfileCard.tsx` بطاقة الملف (فيها زر الدخول للمكتبة).
- التوجيه: `Route` في `src/lib/types.ts` + عرض الشاشة في `src/App.tsx` (مسارات غير المكتبة ترجع للمكتبة بزر الرجوع).
- الترجمة: `src/lib/i18n/{en,ar,fr}.ts`. `en` هو المصدر (`as const`) والباقي يجب أن يملك **نفس المفاتيح** وإلا فشل النوع. تُضاف المفاتيح قبل إغلاق الكائن. `t(key, {param})` يدعم `{param}`. لا نصوص ثابتة في الواجهة، ولا مفاتيح خطأ بلا ترجمة في اللغات الثلاث.
- الواجهة: `Sheet`, `ConfirmDialog`, أزرار `.btn`, `.icon-btn`, `.acc-card`, `.online-form`, `.olib-*` في `src/styles/app.css`. أيقونات `lucide-react`. اتجاه RTL: استخدم `margin-inline`/`inset-inline` وليس left/right، و`className="flip"` لأسهم الرجوع.
- `docs/ONLINE_SETUP.md`: خطوات المستخدم اليدوية ونموذج البيانات والقواعد. حدّثه مع كل مرحلة وبصدق (قسم «ما لم ينجز»).
- الإعدادات: `online.ts` فيه `DEFAULT_URL` و`DEFAULT_ANON_KEY` (مفتاح anon عام) لمشروع المستخدم `https://puvcorlkdxerphfdzpsz.supabase.co`، ويمكن تجاوزها بـ`VITE_SUPABASE_URL/ANON_KEY`. لا تضع أبدًا `service_role` في العميل.

## 4. قواعد الخصوصية (مطبقة في SQL، لا تعيد تطبيقها في العميل)
- الأنماط من الأقل للأشد: `public(1) < password(2) < friends(3) < private(4)`.
- المكتبة: `default_access` الافتراضي private، لا تَرِث من شيء. الرف: `inherit` أو نمطه الخاص. الكتاب: نمطه الخاص إن وُجد، وإلا **الأشد** بين رفوفه (أو افتراضي المكتبة).
- المالك يرى كل شيء. الحظر يخفي كل شيء في الاتجاهين. غير المالك لا يرى إلا الكتب `file_status='ready'`. القراءة والتنزيل يتطلبان `read_allowed`/`download_allowed` (الافتراضي false).
- كلمة المرور: bcrypt (pgcrypto)، 8–128 حرفًا، تصريح 24 ساعة عبر `redeem_access_password`، قفل 5 محاولات/15 دقيقة لكل مورد و20/ساعة لكل مستخدم، وتنتهي التصاريح عند تغيير كلمة المرور.
- الأصدقاء: صف في `friendships` مقبول (`user_a < user_b`).
- لا تُخزَّن مسارات ملفات؛ المسار يُشتق: `books/<owner>/<book>.<ext>` و`covers/<owner>/<book>.jpg`.
- الحصص: 200 رف، 2000 كتاب، 1000 اشتراك لكل مستخدم.
- سياسات RLS تضع `owner_id = auth.uid()` أولًا ليعمل `INSERT … RETURNING`. أعمدة العميل القابلة للكتابة محددة بـ`GRANT` على مستوى العمود (انظر 0003)؛ أي عمود جديد يحتاج منحًا صريحًا.
- RPCs الموجودة (للمستخدم `authenticated` فقط): `handle_available, create_profile, change_handle, delete_my_account, send_friend_request, respond_friend_request, cancel_friend_request, remove_friend, block_user, unblock_user, reorder_shelves(uuid[]), set_access_password(type,id,pw), remove_access_password, revoke_access_grants, has_access_password, redeem_access_password`.

## 5. المهام القادمة

### المرحلة 2ب — **منجزة** (للمرجع فقط؛ ابدأ من المرحلة 3 بعد تأكيد المستخدم أن 2أ/2ب تعمل)
1. دوال في `online.ts`: قائمة كتبي المنشورة، إضافة/إزالة كتاب من رف (`shelf_books`)، ترتيب داخل الرف، تعديل `access`/`read_allowed`/`download_allowed` للكتاب، كلمة مرور للكتاب (type=`book` إن كان مدعومًا في RPCs — تحقق من 0003 وعدّل SQL + اختباراته إن لزم، ثم أعد تشغيل مجموعة SQL).
2. شاشة رف: كتبه، إضافة كتب، إزالة، ترتيب. مؤشر خصوصية الكتاب ومصدرها (خاص به / موروث / أشد رفوفه).
3. إعدادات كتاب: نمط الوصول، السماح بالقراءة/التنزيل، تأكيد عند التحويل لعام.
4. ملاحظة: لا يوجد رفع ملفات بعد (مرحلة 3)، لذا كتب 2ب هي سجلات بيانات وصفية؛ قرّر مع المستخدم هل تُنشأ سجلات من الكتب المحلية قبل الرفع (الأرجح: تُؤجَّل إلى المرحلة 3 ويقتصر 2ب على ما هو ممكن).

### المرحلة 3 — النشر والقراءة والاكتشاف (3أ منجزة: الرفع للمالك. المتبقي 3ب و3ج؛ لا تعد كتابة الرفع)
ملاحظات 3ب: سياسة SELECT على `storage.objects` الآن للمالك فقط (`private.own_object_ok`) — وسّعها بدالة تستدعي `private.can_read_book_file` / `can_download_book_file` ثم أنشئ الروابط الموقّعة من العميل أو Edge Function، مع فرق القراءة/التنزيل. المسارات: `books/<uid>/<book>.<epub|pdf>` و`covers/<uid>/<book>.jpg`. حد الحجم 50MB (الخطة المجانية). اختبرها في `supabase/tests/` (المحاكاة تدعم storage.objects).
- Storage: bucketان خاصان `books` و`covers`، سياسات تخزين تطابق قواعد 4، روابط موقّعة قصيرة العمر عبر **Edge Functions** (تتحقق بـ`can_read_book_file`/`can_download_book_file`).
- رفع كتاب: من المكتبة المحلية مع **تأكيد حقوق النشر** (العمود `rights_confirmed_at NOT NULL`)، تتبع `file_status` (uploading→ready…)، حد حجم، استئناف عند فشل الشبكة.
- القراءة/التنزيل/الاستيراد إلى المكتبة المحلية، وزيارة مكتبة شخص آخر بالاسم `@handle` مع إدخال كلمة المرور (`redeem_access_password`).
- اكتشاف وبحث (عام فقط، مع تجاهل المحظورين).
- حذف الحساب يجب أن ينظف الملفات المخزنة (Edge Function) — حاليًا لا شيء مخزَّن.

### المرحلة 4 — أصدقاء وحظر واشتراكات (واجهة فقط تقريبًا؛ الـRPCs والجداول موجودة ومختبرة)
بحث بالـhandle، إرسال/قبول/رفض/إلغاء طلبات الصداقة، قائمة الأصدقاء وإزالتهم، حظر/فك حظر، اشتراك في مكتبة/رف/سلسلة (`subscriptions` و`can_subscribe`).

### المرحلة 5 — إشعارات وبلاغات
صندوق إشعارات داخل التطبيق + تفضيلاتها، بلاغات وإزالة محتوى (takedown) مع واجهة للمشرف. Push على أندرويد يحتاج Firebase (FCM) — **لا تدّعِ أنه push قبل إعداده فعلًا**؛ حتى ذلك الحين الإشعارات داخل التطبيق فقط. جداول هذه المرحلة غير موجودة بعد: تحتاج migration جديدة `0004_…` مع RLS واختبارات.

(تحديث: اختبارات العميل 41، واختبارات SQL 133 + 28.)

## 6. طريقة العمل والاختبار
```bash
# SQL (Postgres 16 محلي؛ مسار الـpg_ctl قد يختلف)
runuser -u postgres -- /usr/lib/postgresql/16/bin/pg_ctl -D /tmp/pgtest/data -o "-p 54329 -k /tmp/pgtest -c listen_addresses=''" -l /tmp/pgtest/log -w start
PGHOST=/tmp/pgtest PGPORT=54329 PGUSER=postgres bash supabase/tests/run.sh   # 133 فحصًا
bun test tests          # منطق العميل بـfetch وهمي (28 اختبارًا)
npm run typecheck && npm run build   # لم تُشغَّل بعد!
```
قواعد: أي تغيير SQL ← migration جديدة (لا تعدّل 0001–0003 بعد أن شغّلها المستخدم) + اختبار يثبت الرفض والقبول (الأمان يُختبر بمحاولات الاختراق، لا بالمسار السعيد). أي دالة عميل ← اختبار. أي نص ← ثلاث لغات. أخبر المستخدم دائمًا بما **لم** يُختبر. سلّمه zip كاملًا: `cd proj && zip -qr ../margins_updated.zip margins -x "margins/node_modules/*"`.

## 7. مزالق معروفة
- المستخدم لصق رابط `/rest/v1/` بدل الجذر: `cleanBaseUrl` يعالجه.
- الجلسة في `localStorage` (مفتاح `margins.sb`) — حد معروف.
- قد يلزم تفعيل «Skip nonce checks» في مزوّد Google بـSupabase إذا فشل تبادل `idToken`.
- مفاتيح Supabase الجديدة «publishable» لا تبدأ بـ`eyJ`: الكود لا يرسل Authorization إلا مع رمز مستخدم أو مفتاح JWT.
- في SQL: دوال المساعدة في schema `private` غير مكشوفة للـAPI؛ `pgcrypto` في schema `extensions`.
- ترتيب الرفوف بأزرار أعلى/أسفل وليس سحبًا (قرار مقصود للبساطة وإمكانية الوصول).
