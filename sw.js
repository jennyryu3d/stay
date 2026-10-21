// 남위례 햇살집 · 알림 전용 서비스 워커 (파일 캐시는 하지 않아요)
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", e => e.waitUntil(self.clients.claim()));

self.addEventListener("push", e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (err) { d = { body: e.data ? e.data.text() : "" }; }
  e.waitUntil((async () => {
    await self.registration.showNotification(d.title || "남위례 햇살집", {
      body: d.body || "새 예약 신청이 들어왔어요",
      icon: "icon-192.png",
      badge: "icon-192.png",
      tag: d.tag || undefined,
      data: { url: d.url || "./#host" }
    });
    try { if (self.navigator.setAppBadge && d.count) await self.navigator.setAppBadge(d.count); } catch (err) {}
  })());
});

self.addEventListener("notificationclick", e => {
  e.notification.close();
  const url = new URL((e.notification.data && e.notification.data.url) || "./#host", self.registration.scope).href;
  e.waitUntil((async () => {
    const list = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const c of list) {
      if (c.url.startsWith(self.registration.scope)) { try { await c.navigate(url); } catch (err) {} return c.focus(); }
    }
    return self.clients.openWindow(url);
  })());
});
