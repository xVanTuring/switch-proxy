import Foundation
import Network

/// Minimal SOCKS5 client: negotiates auth and issues a CONNECT to a target host:port
/// over an already-connected NWConnection. Calls `completion(true)` once the tunnel
/// is established; the caller may then pipe raw bytes through `conn`.
enum Socks5 {
    static func connect(over conn: NWConnection,
                        targetHost: String,
                        targetPort: Int,
                        username: String?,
                        password: String?,
                        completion: @escaping (Bool) -> Void) {

        let useAuth = (username?.isEmpty == false)

        func recvExact(_ n: Int, _ cb: @escaping ([UInt8]?) -> Void) {
            conn.receive(minimumIncompleteLength: n, maximumLength: n) { data, _, _, _ in
                if let data = data, data.count == n {
                    cb([UInt8](data))
                } else {
                    cb(nil)
                }
            }
        }

        func fail() { completion(false) }

        // Parse the CONNECT reply (VER REP RSV ATYP BND.ADDR BND.PORT).
        func readReply() {
            recvExact(4) { head in
                guard let head = head, head[0] == 0x05, head[1] == 0x00 else { fail(); return }
                let atyp = head[3]
                switch atyp {
                case 0x01: // IPv4
                    recvExact(4 + 2) { rest in completion(rest != nil) }
                case 0x04: // IPv6
                    recvExact(16 + 2) { rest in completion(rest != nil) }
                case 0x03: // domain
                    recvExact(1) { lenByte in
                        guard let lenByte = lenByte else { fail(); return }
                        recvExact(Int(lenByte[0]) + 2) { rest in completion(rest != nil) }
                    }
                default:
                    fail()
                }
            }
        }

        func sendConnect() {
            guard targetHost.utf8.count <= 255 else { fail(); return }
            var req: [UInt8] = [0x05, 0x01, 0x00, 0x03]
            let hostBytes = Array(targetHost.utf8)
            req.append(UInt8(hostBytes.count))
            req.append(contentsOf: hostBytes)
            req.append(UInt8((targetPort >> 8) & 0xff))
            req.append(UInt8(targetPort & 0xff))
            conn.send(content: Data(req), completion: .contentProcessed { err in
                if err != nil { fail(); return }
                readReply()
            })
        }

        func doAuth() {
            var msg: [UInt8] = [0x01]
            let user = Array((username ?? "").utf8)
            let pass = Array((password ?? "").utf8)
            msg.append(UInt8(min(user.count, 255)))
            msg.append(contentsOf: user.prefix(255))
            msg.append(UInt8(min(pass.count, 255)))
            msg.append(contentsOf: pass.prefix(255))
            conn.send(content: Data(msg), completion: .contentProcessed { err in
                if err != nil { fail(); return }
                recvExact(2) { reply in
                    guard let reply = reply, reply[1] == 0x00 else { fail(); return }
                    sendConnect()
                }
            })
        }

        // Greeting: offer methods (no-auth and, if creds present, username/password).
        var greeting: [UInt8] = [0x05]
        if useAuth {
            greeting.append(contentsOf: [0x02, 0x00, 0x02])
        } else {
            greeting.append(contentsOf: [0x01, 0x00])
        }
        conn.send(content: Data(greeting), completion: .contentProcessed { err in
            if err != nil { fail(); return }
            recvExact(2) { resp in
                guard let resp = resp, resp[0] == 0x05 else { fail(); return }
                switch resp[1] {
                case 0x00: sendConnect()
                case 0x02 where useAuth: doAuth()
                default: fail()
                }
            }
        })
    }
}
