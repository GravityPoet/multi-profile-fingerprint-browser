import Darwin
import Foundation

enum ProxyRelayError: Error, LocalizedError {
    case pythonMissing
    case scriptWriteFailed(Error)
    case launchFailed(Error)
    case portUnavailable
    case notReady

    var errorDescription: String? {
        switch self {
        case .pythonMissing:
            return "python3 is required for the local authenticated proxy relay."
        case .scriptWriteFailed(let error):
            return "Could not write proxy relay helper: \(error.localizedDescription)"
        case .launchFailed(let error):
            return "Could not start proxy relay: \(error.localizedDescription)"
        case .portUnavailable:
            return "Could not allocate local proxy relay port."
        case .notReady:
            return "Proxy relay did not become ready."
        }
    }
}

final class ProxyRelay {
    let localHost = "127.0.0.1"
    let localPort: Int
    private let process: Process

    private init(localPort: Int, process: Process) {
        self.localPort = localPort
        self.process = process
    }

    deinit {
        stop()
    }

    static func start(for proxy: ProxyConfig) throws -> ProxyRelay {
        guard proxy.isEnabled else {
            throw ProxyRelayError.portUnavailable
        }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw ProxyRelayError.pythonMissing
        }
        try AppPaths.ensureExists()
        let scriptURL = AppPaths.helpersDir.appendingPathComponent("proxy-relay.py")
        do {
            try relayScript.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: scriptURL.path)
        } catch {
            throw ProxyRelayError.scriptWriteFailed(error)
        }

        let port = try allocatePort()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = [
            scriptURL.path,
            "--listen", "127.0.0.1:\(port)",
            "--kind", proxy.kind.rawValue,
            "--host", proxy.host,
            "--port", String(proxy.port),
        ]
        if proxy.hasCredentials {
            proc.arguments? += ["--username", proxy.username, "--password", proxy.password]
        }
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()

        do {
            try proc.run()
        } catch {
            throw ProxyRelayError.launchFailed(error)
        }

        for _ in 0..<50 {
            if canConnect(host: "127.0.0.1", port: port) {
                AppLogger.info("ProxyRelay ready at 127.0.0.1:\(port) upstream=\(proxy.displayString)")
                return ProxyRelay(localPort: port, process: proc)
            }
            if !proc.isRunning { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        proc.terminate()
        throw ProxyRelayError.notReady
    }

    func stop() {
        guard process.isRunning else { return }
        process.terminate()
        Thread.sleep(forTimeInterval: 0.1)
        if process.isRunning {
            process.interrupt()
        }
    }

    private static func allocatePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ProxyRelayError.portUnavailable }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(0).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw ProxyRelayError.portUnavailable }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard got == 0 else { throw ProxyRelayError.portUnavailable }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    private static func canConnect(host: String, port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port)).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr(host))
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        } == 0
    }
}

private let relayScript = #"""
#!/usr/bin/env python3
import argparse, base64, select, socket, ssl, struct, sys, threading

TIMEOUT = 20

def recvn(sock, n):
    data = b""
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            raise ConnectionError("unexpected EOF")
        data += chunk
    return data

def dial_socks5(args, host, port):
    s = socket.create_connection((args.host, args.port), timeout=TIMEOUT)
    try:
        s.sendall(b"\x05\x01\x02" if args.username else b"\x05\x01\x00")
        ver, method = recvn(s, 2)
        if ver != 5:
            raise ConnectionError("upstream is not SOCKS5")
        if method == 2:
            u = (args.username or "").encode()
            p = (args.password or "").encode()
            s.sendall(b"\x01" + bytes([len(u)]) + u + bytes([len(p)]) + p)
            _, status = recvn(s, 2)
            if status != 0:
                raise ConnectionError("SOCKS5 auth rejected")
        elif method != 0:
            raise ConnectionError("SOCKS5 auth method rejected")
        hb = host.encode()
        s.sendall(b"\x05\x01\x00\x03" + bytes([len(hb)]) + hb + int(port).to_bytes(2, "big"))
        rep = recvn(s, 4)
        if rep[1] != 0:
            raise ConnectionError("SOCKS5 CONNECT failed")
        atyp = rep[3]
        if atyp == 1: recvn(s, 4)
        elif atyp == 3: recvn(s, recvn(s, 1)[0])
        elif atyp == 4: recvn(s, 16)
        recvn(s, 2)
        return s
    except Exception:
        s.close()
        raise

def dial_http(args, host, port):
    s = socket.create_connection((args.host, args.port), timeout=TIMEOUT)
    try:
        req = f"CONNECT {host}:{port} HTTP/1.1\r\nHost: {host}:{port}\r\n"
        if args.username:
            tok = base64.b64encode(f"{args.username}:{args.password or ''}".encode()).decode()
            req += f"Proxy-Authorization: Basic {tok}\r\n"
        req += "\r\n"
        s.sendall(req.encode())
        buf = b""
        while b"\r\n\r\n" not in buf and len(buf) < 65536:
            buf += s.recv(4096)
        if not buf.startswith(b"HTTP/1.1 200") and not buf.startswith(b"HTTP/1.0 200"):
            raise ConnectionError("HTTP CONNECT failed")
        return s
    except Exception:
        s.close()
        raise

def dial(args, host, port):
    if args.kind == "socks5":
        return dial_socks5(args, host, port)
    return dial_http(args, host, port)

def relay(a, b):
    sockets = [a, b]
    try:
        while True:
            readable, _, _ = select.select(sockets, [], [], TIMEOUT)
            if not readable:
                break
            for s in readable:
                data = s.recv(65536)
                if not data:
                    return
                (b if s is a else a).sendall(data)
    finally:
        for s in sockets:
            try: s.close()
            except Exception: pass

def handle(client, args):
    try:
        ver, nmethods = recvn(client, 2)
        methods = recvn(client, nmethods)
        if ver != 5:
            raise ConnectionError("client is not SOCKS5")
        client.sendall(b"\x05\x00")
        ver, cmd, _, atyp = recvn(client, 4)
        if ver != 5 or cmd != 1:
            raise ConnectionError("only CONNECT is supported")
        if atyp == 1:
            host = socket.inet_ntoa(recvn(client, 4))
        elif atyp == 3:
            host = recvn(client, recvn(client, 1)[0]).decode()
        elif atyp == 4:
            host = socket.inet_ntop(socket.AF_INET6, recvn(client, 16))
        else:
            raise ConnectionError("bad ATYP")
        port = struct.unpack("!H", recvn(client, 2))[0]
        upstream = dial(args, host, port)
        client.sendall(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")
        relay(client, upstream)
    except Exception:
        try: client.sendall(b"\x05\x01\x00\x01\x00\x00\x00\x00\x00\x00")
        except Exception: pass
        try: client.close()
        except Exception: pass

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--listen", required=True)
    p.add_argument("--kind", choices=["http", "socks5"], required=True)
    p.add_argument("--host", required=True)
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--username", default="")
    p.add_argument("--password", default="")
    args = p.parse_args()
    lh, lp = args.listen.rsplit(":", 1)
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((lh, int(lp)))
    srv.listen(100)
    while True:
        client, _ = srv.accept()
        threading.Thread(target=handle, args=(client, args), daemon=True).start()

if __name__ == "__main__":
    main()
"""#
