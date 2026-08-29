self.addEventListener('install', function(){ self.skipWaiting(); });
self.addEventListener('activate', function(e){
  e.waitUntil((async function(){
    try {
      const ks = await caches.keys();
      await Promise.all(ks.map(function(k){ return caches.delete(k); }));
      await self.registration.unregister();
      const cs = await self.clients.matchAll({type:'window'});
      cs.forEach(function(c){ c.navigate(c.url); });
    } catch (err) {}
  })());
});
