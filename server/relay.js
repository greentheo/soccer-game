// Tiny WebSocket relay for Soccer Game multiplayer.
// One global room: every message from a client is broadcast to all other
// clients. The relay assigns ids and tracks who the host is (lowest id).
// Run: node relay.js  (listens on port 8765)

const { WebSocketServer } = require("ws");

const PORT = 8765;
const wss = new WebSocketServer({ port: PORT });

let nextId = 1;
const clients = new Map(); // id -> socket

function hostId() {
  return clients.size ? Math.min(...clients.keys()) : 0;
}

function send(sock, obj) {
  if (sock.readyState === 1) sock.send(JSON.stringify(obj));
}

function broadcast(obj, exceptId = 0) {
  for (const [id, sock] of clients) if (id !== exceptId) send(sock, obj);
}

wss.on("connection", (sock) => {
  const id = nextId++;
  clients.set(id, sock);
  send(sock, { t: "welcome", id, host: hostId() });
  broadcast({ t: "join", id }, id);
  console.log(`join id=${id} (${clients.size} online, host=${hostId()})`);

  sock.on("message", (data) => {
    // pure relay: forward to everyone else
    let msg;
    try { msg = JSON.parse(data); } catch { return; }
    msg.id = id; // stamp the sender, clients can't spoof
    broadcast(msg, id);
  });

  sock.on("close", () => {
    clients.delete(id);
    broadcast({ t: "leave", id, host: hostId() });
    console.log(`leave id=${id} (${clients.size} online, host=${hostId()})`);
  });
  sock.on("error", () => {});
});

console.log(`Soccer relay listening on ws://localhost:${PORT}`);
