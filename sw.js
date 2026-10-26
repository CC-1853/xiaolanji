/* 小懒记 · 离线缓存 Service Worker */
const CACHE = "xlj-cache-v13";
const ASSETS = [
  "./",
  "./index.html",
  "./manifest.json",
  "./icon-180.png",
  "./icon-192.png",
  "./icon-512.png",
  "./icon-64.png"
];

self.addEventListener("install", e => {
  e.waitUntil(
    caches.open(CACHE).then(async c => {
      // 逐个缓存，某个资源（如偶发抽风的图标）拉不到也不影响整体安装
      for (const url of ASSETS) {
        try { await c.add(url); } catch (err) { console.warn("预缓存失败（可忽略）:", url); }
      }
    }).then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", e => {
  e.waitUntil(
    caches.keys()
      .then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", e => {
  if (e.request.method !== "GET") return;
  const url = new URL(e.request.url);
  const isHTML = e.request.mode === "navigate" || url.pathname.endsWith(".html");
  if (isHTML) {
    // 首页/页面：网络优先，保证每次都拿到最新版；离线时回退缓存
    e.respondWith(
      fetch(e.request).then(res => {
        const copy = res.clone();
        caches.open(CACHE).then(c => c.put(e.request, copy)).catch(() => {});
        return res;
      }).catch(() => caches.match(e.request).then(h => h || caches.match("./index.html")))
    );
  } else {
    // 静态资源：缓存优先，离线可用
    e.respondWith(
      caches.match(e.request, { ignoreSearch: true }).then(hit =>
        hit ||
        fetch(e.request).then(res => {
          const copy = res.clone();
          caches.open(CACHE).then(c => c.put(e.request, copy)).catch(() => {});
          return res;
        }).catch(() => caches.match("./index.html"))
      )
    );
  }
});
