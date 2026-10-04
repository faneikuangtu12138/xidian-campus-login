using System;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Text;

namespace CampusLogin {
    public static class SrunCrypto {
        // Matches the encoder served by w.xidian.edu.cn/static/themes/pro/js/Portal.js.
        public static string Encode(string text, string key) {
            if (text.Length == 0) return "";
            uint[] v = Words(text, true), k = Words(key, false);
            if (k.Length < 4) Array.Resize(ref k, 4);
            int n = v.Length - 1, q = 6 + 52 / v.Length;
            uint z = v[n], y, sum = 0;
            unchecked {
                while (q-- > 0) {
                    sum += 0x9e3779b9; uint e = (sum >> 2) & 3; int p;
                    for (p = 0; p < n; p++) {
                        y = v[p + 1];
                        uint m = (z >> 5) ^ (y << 2);
                        m += (y >> 3) ^ (z << 4) ^ (sum ^ y);
                        m += k[(p & 3) ^ (int)e] ^ z;
                        z = v[p] += m;
                    }
                    y = v[0];
                    uint last = (z >> 5) ^ (y << 2);
                    last += (y >> 3) ^ (z << 4) ^ (sum ^ y);
                    last += k[(p & 3) ^ (int)e] ^ z;
                    z = v[n] += last;
                }
            }
            byte[] bytes = new byte[v.Length * 4];
            for (int i = 0; i < v.Length; i++) {
                bytes[i * 4] = (byte)v[i]; bytes[i * 4 + 1] = (byte)(v[i] >> 8);
                bytes[i * 4 + 2] = (byte)(v[i] >> 16); bytes[i * 4 + 3] = (byte)(v[i] >> 24);
            }
            const string standard = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
            const string custom = "LVoJPiCN2R8G90yg+hmFHuacZ1OWMnrsSTXkYpUq/3dlbfKwv6xztjI7DeBE45QA";
            var encoded = Convert.ToBase64String(bytes).ToCharArray();
            for (int i = 0; i < encoded.Length; i++) if (encoded[i] != '=') encoded[i] = custom[standard.IndexOf(encoded[i])];
            return "{SRBX1}" + new string(encoded);
        }
        static uint[] Words(string s, bool length) {
            var v = new uint[(s.Length + 3) / 4 + (length ? 1 : 0)];
            for (int i = 0; i < s.Length; i++) v[i / 4] |= (uint)s[i] << ((i % 4) * 8);
            if (length) v[v.Length - 1] = (uint)s.Length;
            return v;
        }
        static string Quote(string s) {
            // JSON.stringify keeps valid UTF-16 surrogate pairs literal. The default
            // .NET JSON encoder escapes emoji, which changes SRun's input bytes.
            var b = new StringBuilder("\"");
            for (int i = 0; i < s.Length; i++) {
                char c = s[i];
                switch (c) {
                    case '"': b.Append("\\\""); break;
                    case '\\': b.Append("\\\\"); break;
                    case '\b': b.Append("\\b"); break;
                    case '\f': b.Append("\\f"); break;
                    case '\n': b.Append("\\n"); break;
                    case '\r': b.Append("\\r"); break;
                    case '\t': b.Append("\\t"); break;
                    default:
                        if (c < 32 || (char.IsHighSurrogate(c) && (i + 1 == s.Length || !char.IsLowSurrogate(s[i + 1]))) || (char.IsLowSurrogate(c) && (i == 0 || !char.IsHighSurrogate(s[i - 1])))) b.Append("\\u").Append(((int)c).ToString("x4"));
                        else b.Append(c);
                        break;
                }
            }
            return b.Append('"').ToString();
        }
        public static Dictionary<string,string> Build(string username, string password, string ip, string acid, string token) {
            string json = "{\"username\":" + Quote(username) + ",\"password\":" + Quote(password) + ",\"ip\":" + Quote(ip) + ",\"acid\":" + Quote(acid) + ",\"enc_ver\":\"srun_bx1\"}";
            string info = Encode(json, token);
            string digest;
            using (var hmac = new HMACMD5(Encoding.UTF8.GetBytes(token))) digest = Convert.ToHexString(hmac.ComputeHash(Encoding.UTF8.GetBytes(password))).ToLowerInvariant();
            string check = token + username + token + digest + token + acid + token + ip + token + "200" + token + "1" + token + info;
            string checksum = Convert.ToHexString(SHA1.HashData(Encoding.UTF8.GetBytes(check))).ToLowerInvariant();
            return new Dictionary<string,string> {
                {"action","login"},{"username",username},{"password","{MD5}" + digest},
                {"os","Windows 10"},{"name","Windows"},{"double_stack","0"},
                {"chksum",checksum},{"info",info},{"ac_id",acid},{"ip",ip},{"n","200"},{"type","1"}
            };
        }
    }
}
