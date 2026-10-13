// সহজ হিসাব — Service Worker: অ্যাপ নেট ছাড়াও খোলার জন্য
const CACHE = 'sk-shell-v2';
const SHELL = ['./', 'index.html', 'config.js', 'manifest.json', 'icon-192.png', 'icon-512.png'];
const CDN = ['https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.js',
             'https://fonts.googleapis.com/css2?family=Hind+Siliguri:wght@400;500;600;700&display=swap'];

self.addEventListener('install', e=>{
  e.waitUntil((async()=>{
    const c = await caches.open(CACHE);
    await Promise.all(SHELL.concat(CDN).map(u=> c.add(u).catch(()=>{})));   // একটা না এলেও ইনস্টল ভাঙবে না
    self.skipWaiting();
  })());
});
self.addEventListener('activate', e=>{
  e.waitUntil((async()=>{
    const keys = await caches.keys();
    await Promise.all(keys.filter(k=>k!==CACHE).map(k=>caches.delete(k)));
    await self.clients.claim();
  })());
});
self.addEventListener('fetch', e=>{
  const req = e.request, url = new URL(req.url);
  if(req.method!=='GET') return;
  if(url.hostname.endsWith('supabase.co')) return;           // ডাটাবেজ কল কখনো ক্যাশ নয়
  if(req.mode==='navigate'){                                  // পেজ: নেট থাকলে নতুনটা, না থাকলে ফোনের কপি
    e.respondWith(fetch(req).then(r=>{ const cp=r.clone(); caches.open(CACHE).then(c=>c.put('index.html', cp)); return r; })
      .catch(()=> caches.match('index.html').then(r=> r || caches.match('./'))));
    return;
  }
  e.respondWith(caches.match(req).then(hit=>{                 // বাকি সব: ক্যাশ আগে, পেছনে নতুন করে আনা
    const net = fetch(req).then(r=>{ if(r && (r.ok||r.type==='opaque')){ const cp=r.clone(); caches.open(CACHE).then(c=>c.put(req,cp)); } return r; }).catch(()=>hit);
    return hit || net;
  }));
});
