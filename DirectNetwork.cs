using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace CampusLogin {
    // Pin both DNS and TCP sockets to the physical Windows adapter. UseProxy=false
    // alone does not bypass a TUN adapter, nor does binding a source address alone.
    public sealed class DirectNetwork : IDisposable {
        readonly int index;
        readonly IPAddress source;
        readonly string[] servers;
        readonly HttpClient client;
        readonly Dictionary<string, IPAddress> cache = new Dictionary<string, IPAddress>();
        public string LastResolvedAddress { get; private set; }
        public DirectNetwork(int interfaceIndex, string sourceAddress, string[] dnsServers) {
            index = interfaceIndex; source = IPAddress.Parse(sourceAddress); servers = dnsServers;
            var handler = new SocketsHttpHandler {
                UseProxy = false, AllowAutoRedirect = false,
                AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate,
                ConnectTimeout = TimeSpan.FromSeconds(5), UseCookies = true,
                CookieContainer = new CookieContainer(), MaxResponseHeadersLength = 64
            };
            handler.ConnectCallback = Connect;
            client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(12), MaxResponseContentBufferSize = 2 * 1024 * 1024 };
            client.DefaultRequestHeaders.UserAgent.ParseAdd("CampusLogin/1.0");
        }
        Socket NewSocket(SocketType type, ProtocolType protocol) {
            var s = new Socket(AddressFamily.InterNetwork, type, protocol);
            try {
                // Windows IP_UNICAST_IF (31) takes the adapter index in network byte order.
                s.SetSocketOption(SocketOptionLevel.IP, (SocketOptionName)31, IPAddress.HostToNetworkOrder(index));
                s.Bind(new IPEndPoint(source, 0));
                return s;
            } catch { s.Dispose(); throw; }
        }
        static ushort U16(byte[] b, int p) {
            if (p < 0 || p + 2 > b.Length) throw new IOException("Invalid DNS response");
            return (ushort)((b[p] << 8) | b[p + 1]);
        }
        static int SkipName(byte[] b, int p) {
            for (int n = 0; n < 128; n++) {
                if (p >= b.Length) throw new IOException("Invalid DNS name");
                int len = b[p++];
                if (len == 0) return p;
                if ((len & 0xc0) == 0xc0) {
                    if (p >= b.Length) throw new IOException("Invalid DNS pointer");
                    return p + 1;
                }
                if (len > 63 || p + len > b.Length) throw new IOException("Invalid DNS label");
                p += len;
            }
            throw new IOException("Invalid DNS name");
        }
        public IPAddress Resolve(string host) {
            if (IPAddress.TryParse(host, out var literal)) {
                if (literal.AddressFamily != AddressFamily.InterNetwork) throw new IOException("IPv4 required");
                return literal;
            }
            if (cache.TryGetValue(host, out var cached)) return cached;
            var id = (ushort)Random.Shared.Next(65536);
            var q = new List<byte> { (byte)(id >> 8), (byte)id, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0 };
            foreach (string label in host.TrimEnd('.').Split('.')) {
                byte[] l = Encoding.ASCII.GetBytes(label);
                if (l.Length == 0 || l.Length > 63) throw new IOException("Invalid DNS label");
                q.Add((byte)l.Length); q.AddRange(l);
            }
            q.AddRange(new byte[] { 0, 0, 1, 0, 1 });
            foreach (string server in servers) {
                if (!IPAddress.TryParse(server, out var ns) || ns.AddressFamily != AddressFamily.InterNetwork) continue;
                try {
                    using (var s = NewSocket(SocketType.Dgram, ProtocolType.Udp)) {
                        s.ReceiveTimeout = 1800; s.SendTimeout = 1800;
                        s.Connect(new IPEndPoint(ns, 53)); s.Send(q.ToArray());
                        var buffer = new byte[4096]; int size = s.Receive(buffer);
                        byte[] b = new byte[size]; Array.Copy(buffer, b, size);
                        if (size < 12 || U16(b, 0) != id || (b[2] & 0x80) == 0 || (b[3] & 15) != 0 || (b[2] & 2) != 0) continue;
                        int p = 12;
                        for (int n = 0; n < U16(b, 4); n++) p = SkipName(b, p) + 4;
                        for (int n = 0; n < U16(b, 6); n++) {
                            p = SkipName(b, p); int type = U16(b, p), cls = U16(b, p + 2), len = U16(b, p + 8); p += 10;
                            if (p + len > b.Length) throw new IOException("Invalid DNS record");
                            if (type == 1 && cls == 1 && len == 4) {
                                byte[] a = new byte[4]; Array.Copy(b, p, a, 0, 4);
                                // Reject fake-IP and local/multicast destinations, never fall back to proxy DNS.
                                if (a[0] == 0 || a[0] == 127 || a[0] >= 224 || (a[0] == 198 && (a[1] == 18 || a[1] == 19))) continue;
                                var ip = new IPAddress(a); cache[host] = ip; LastResolvedAddress = ip.ToString(); return ip;
                            }
                            p += len;
                        }
                    }
                } catch (SocketException) { } catch (IOException) { }
            }
            throw new IOException("Physical-adapter DNS lookup failed for " + host);
        }
        async ValueTask<Stream> Connect(SocketsHttpConnectionContext context, CancellationToken token) {
            var ip = Resolve(context.DnsEndPoint.Host);
            var s = NewSocket(SocketType.Stream, ProtocolType.Tcp);
            try { await s.ConnectAsync(new IPEndPoint(ip, context.DnsEndPoint.Port), token); return new NetworkStream(s, true); }
            catch { s.Dispose(); throw; }
        }
        public HttpResponseMessage Get(string url) { return client.GetAsync(url).GetAwaiter().GetResult(); }
        public HttpResponseMessage Post(string url, Dictionary<string,string> fields) {
            using (var content = new FormUrlEncodedContent(fields)) return client.PostAsync(url, content).GetAwaiter().GetResult();
        }
        public void Dispose() { client.Dispose(); }
    }
}
