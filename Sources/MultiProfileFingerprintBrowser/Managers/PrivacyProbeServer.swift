import Darwin
import Foundation

final class PrivacyProbeServer {
    private let fd: Int32
    private let queue = DispatchQueue(label: "local.mpfb.privacy-probe-server")
    private var running = true
    private var results: [String: Data] = [:]
    private let lock = NSLock()

    let port: Int

    init() throws {
        let fdLocal = socket(AF_INET, SOCK_STREAM, 0)
        guard fdLocal >= 0 else { throw NSError(domain: "PrivacyProbeServer", code: 1) }
        var yes: Int32 = 1
        setsockopt(fdLocal, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(0).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fdLocal, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fdLocal, 32) == 0 else {
            close(fdLocal)
            throw NSError(domain: "PrivacyProbeServer", code: 2)
        }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fdLocal, $0, &len)
            }
        }
        guard got == 0 else {
            close(fdLocal)
            throw NSError(domain: "PrivacyProbeServer", code: 3)
        }
        fd = fdLocal
        port = Int(UInt16(bigEndian: addr.sin_port))
        queue.async { [weak self] in self?.acceptLoop() }
    }

    deinit {
        stop()
    }

    func url(role: String) -> String {
        "http://127.0.0.1:\(port)/probe.html?role=\(role)"
    }

    func result(role: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return results[role]
    }

    func stop() {
        lock.lock()
        let shouldClose = running
        running = false
        lock.unlock()
        if shouldClose {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
    }

    private func acceptLoop() {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { break }
            handle(client: client)
        }
    }

    private func handle(client: Int32) {
        defer { close(client) }
        var buffer = [UInt8](repeating: 0, count: 128 * 1024)
        let n = recv(client, &buffer, buffer.count, 0)
        guard n > 0 else { return }
        let data = Data(buffer.prefix(n))
        guard let request = String(data: data, encoding: .utf8),
              let first = request.split(separator: "\r\n").first else { return }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return }
        let method = String(parts[0])
        let path = String(parts[1])

        if method == "GET", path.hasPrefix("/probe.html") {
            respond(client: client, status: "200 OK", contentType: "text/html; charset=utf-8", body: Self.probeHTML.data(using: .utf8)!)
        } else if method == "GET", path == "/sw.js" {
            respond(client: client, status: "200 OK", contentType: "application/javascript", body: Self.serviceWorkerJS.data(using: .utf8)!)
        } else if method == "POST", path.hasPrefix("/result") {
            let role = query(path, "role") ?? "unknown"
            let marker = Data("\r\n\r\n".utf8)
            let body = data.range(of: marker).map { data[$0.upperBound...] } ?? Data.SubSequence()
            lock.lock()
            results[role] = Data(body)
            lock.unlock()
            respond(client: client, status: "204 No Content", contentType: "text/plain", body: Data())
        } else {
            respond(client: client, status: "404 Not Found", contentType: "text/plain", body: Data("not found".utf8))
        }
    }

    private func query(_ path: String, _ name: String) -> String? {
        guard let q = path.split(separator: "?", maxSplits: 1).dropFirst().first else { return nil }
        for part in q.split(separator: "&") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.first == Substring(name), kv.count == 2 {
                return String(kv[1])
            }
        }
        return nil
    }

    private func respond(client: Int32, status: String, contentType: String, body: Data) {
        let head = """
        HTTP/1.1 \(status)\r
        Content-Length: \(body.count)\r
        Content-Type: \(contentType)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r

        """
        var payload = Data(head.utf8)
        payload.append(body)
        payload.withUnsafeBytes { ptr in
            _ = send(client, ptr.baseAddress, payload.count, 0)
        }
    }

    private static let serviceWorkerJS = """
    self.addEventListener('message', (event) => {
      event.source.postMessage({
        timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
        language: navigator.language,
        languages: navigator.languages || [],
        platform: navigator.platform,
        hardwareConcurrency: navigator.hardwareConcurrency || 0
      });
    });
    """

    private static let probeHTML = """
    <!doctype html><meta charset="utf-8">
    <script>
    const role = new URL(location.href).searchParams.get('role') || 'single';
    const key = 'mpfb_marker';
    const out = { role };
    const hash = async (text) => {
      const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
      return [...new Uint8Array(buf)].map(x => x.toString(16).padStart(2, '0')).join('').slice(0, 16);
    };
    const withTimeout = (p, ms, label) => Promise.race([p, new Promise((_, rej) => setTimeout(() => rej(new Error(label)), ms))]);
    async function idbGet() {
      return await new Promise((resolve) => {
        const req = indexedDB.open('mpfb_db', 1);
        req.onupgradeneeded = () => { if (!req.result.objectStoreNames.contains('kv')) req.result.createObjectStore('kv'); };
        req.onerror = () => resolve('ERR');
        req.onsuccess = () => {
          const db = req.result;
          if (!db.objectStoreNames.contains('kv')) { db.close(); resolve(null); return; }
          const tx = db.transaction('kv', 'readonly');
          const get = tx.objectStore('kv').get(key);
          get.onsuccess = () => { const v = get.result || null; db.close(); resolve(v); };
          get.onerror = () => { db.close(); resolve('ERR'); };
        };
      });
    }
    async function idbSet(v) {
      return await new Promise((resolve, reject) => {
        const req = indexedDB.open('mpfb_db', 1);
        req.onupgradeneeded = () => { if (!req.result.objectStoreNames.contains('kv')) req.result.createObjectStore('kv'); };
        req.onerror = () => reject(req.error);
        req.onsuccess = () => {
          const db = req.result;
          const tx = db.transaction('kv', 'readwrite');
          tx.objectStore('kv').put(v, key);
          tx.oncomplete = () => { db.close(); resolve(true); };
          tx.onerror = () => { db.close(); reject(tx.error); };
        };
      });
    }
    async function workerTimezone() {
      return await withTimeout(new Promise((resolve) => {
        const blob = new Blob(['postMessage({timezone:Intl.DateTimeFormat().resolvedOptions().timeZone,language:navigator.language,languages:navigator.languages||[],platform:navigator.platform,hardwareConcurrency:navigator.hardwareConcurrency||0})'], {type:'text/javascript'});
        const w = new Worker(URL.createObjectURL(blob));
        w.onmessage = e => resolve(e.data);
        w.onerror = e => resolve({error:String(e.message||e)});
      }), 4000, 'worker');
    }
    async function iframeTimezone() {
      return await withTimeout(new Promise((resolve) => {
        const f = document.createElement('iframe');
        f.onload = () => resolve({
          timezone: f.contentWindow.Intl.DateTimeFormat().resolvedOptions().timeZone,
          language: f.contentWindow.navigator.language,
          languages: f.contentWindow.navigator.languages || [],
          platform: f.contentWindow.navigator.platform,
          hardwareConcurrency: f.contentWindow.navigator.hardwareConcurrency || 0
        });
        document.body.appendChild(f);
      }), 4000, 'iframe');
    }
    async function serviceWorkerSignal() {
      if (!('serviceWorker' in navigator)) return { error: 'unsupported' };
      try {
        const reg = await navigator.serviceWorker.register('/sw.js');
        await navigator.serviceWorker.ready;
        const sw = reg.active || reg.waiting || reg.installing;
        return await withTimeout(new Promise((resolve) => {
          navigator.serviceWorker.onmessage = e => resolve(e.data);
          sw.postMessage('probe');
        }), 4000, 'service worker');
      } catch (e) { return { error: String(e) }; }
    }
    async function webrtcIPs() {
      if (!window.RTCPeerConnection) return [];
      return await withTimeout(new Promise((resolve) => {
        const ips = new Set();
        const pc = new RTCPeerConnection({iceServers:[{urls:'stun:stun.l.google.com:19302'}]});
        pc.createDataChannel('x');
        pc.onicecandidate = ev => {
          if (!ev.candidate) { pc.close(); resolve([...ips]); return; }
          for (const token of ev.candidate.candidate.split(/\\s+/)) {
            if (/^(?:[0-9]{1,3}\\.){3}[0-9]{1,3}$/.test(token) || (/^[a-f0-9:]+$/i.test(token) && (token.match(/:/g) || []).length >= 2)) {
              ips.add(token);
            }
          }
        };
        pc.createOffer().then(o => pc.setLocalDescription(o));
        setTimeout(() => { try { pc.close(); } catch (_) {} resolve([...ips]); }, 3500);
      }), 5000, 'webrtc').catch(e => ['ERR:' + e]);
    }
    async function canvasHash() {
      const c = document.createElement('canvas'); c.width = 240; c.height = 60;
      const x = c.getContext('2d'); x.textBaseline='top'; x.font='16px Arial'; x.fillStyle='#f60'; x.fillRect(0,0,240,60); x.fillStyle='#069'; x.fillText('MPFB canvas stable text', 8, 8);
      const metrics = ['MPFB canvas stable text', 'mmmmmmmmmm', '漢字かなABC123'].map(t => x.measureText(t).width.toFixed(6)).join('|');
      return await hash(c.toDataURL() + ':' + metrics);
    }
    async function audioHash() {
      try {
        var props = '';
        try {
          const AC1 = window.AudioContext || window.webkitAudioContext;
          const ac1 = new AC1();
          props = [ac1.sampleRate, ac1.outputLatency || 0, ac1.destination && ac1.destination.maxChannelCount || 0].join(':');
          if (ac1.close) ac1.close();
        } catch (_) {}
        const AC = OfflineAudioContext || webkitOfflineAudioContext;
        const ac = new AC(1, 44100, 44100);
        const osc = ac.createOscillator(); const comp = ac.createDynamicsCompressor();
        osc.type = 'triangle'; osc.frequency.value = 10000; osc.connect(comp); comp.connect(ac.destination); osc.start(0);
        const b = await withTimeout(ac.startRendering(), 5000, 'audio');
        const data = b.getChannelData(0); let s = '';
        for (let i=0; i<data.length; i+=997) s += data[i].toFixed(8);
        return await hash(props + ':' + s);
      } catch (e) { return 'ERR:' + e; }
    }
    async function run() {
      out.main = {
        timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
        language: navigator.language,
        languages: navigator.languages || [],
        platform: navigator.platform,
        hardwareConcurrency: navigator.hardwareConcurrency || 0,
        deviceMemory: navigator.deviceMemory || 0,
        webdriver: navigator.webdriver === true,
        userAgent: navigator.userAgent
      };
      out.worker = await workerTimezone();
      out.iframe = await iframeTimezone();
      out.serviceWorker = await serviceWorkerSignal();
      const gl = document.createElement('canvas').getContext('webgl');
      out.webgl = gl ? { vendor: gl.getParameter(gl.VENDOR), renderer: gl.getParameter(gl.RENDERER) } : { error: 'none' };
      out.canvas = await canvasHash();
      out.audio = await audioHash();
      out.webrtc = await webrtcIPs();
      out.storageBefore = { cookie: document.cookie, local: localStorage.getItem(key), idb: await idbGet(), cache: null };
      if ('caches' in window) {
        const cache = await caches.open('mpfb_cache');
        out.storageBefore.cache = !!(await cache.match('/marker'));
        if (role === 'a') await cache.put('/marker', new Response('A'));
      }
      if (role === 'a') {
        document.cookie = key + '=A; path=/; SameSite=Lax';
        localStorage.setItem(key, 'A');
        await idbSet('A');
      }
      await fetch('/result?role=' + encodeURIComponent(role), { method: 'POST', body: JSON.stringify(out), keepalive: true });
      document.body.textContent = 'done';
    }
    run().catch(async e => {
      out.error = String(e && e.stack || e);
      await fetch('/result?role=' + encodeURIComponent(role), { method: 'POST', body: JSON.stringify(out), keepalive: true });
    });
    </script>
    """
}
