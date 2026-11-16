self.addEventListener('push', (event) => {
  if (!event.data) return;

  let payload = {};
  try {
    payload = event.data.json();
  } catch (err) {
    payload = {
      title: 'SCInsta',
      body: event.data.text(),
      tag: 'system',
      data: { targetUrl: 'scinsta://direct-inbox' }
    };
  }

  const title = payload.title || 'SCInsta';
  const options = {
    body: payload.body,
    tag: payload.tag,
    icon: '/icon-192.png',
    data: payload.data
  };

  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();

  const targetUrl =
    event.notification.data && event.notification.data.targetUrl
      ? event.notification.data.targetUrl
      : 'scinsta://direct-inbox';

  event.waitUntil(clients.openWindow(targetUrl));
});
