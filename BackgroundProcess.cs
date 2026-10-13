using System;
using System.Diagnostics;
using System.Threading.Tasks;
using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace CampusLogin
{
    public static class BackgroundProcess
    {
        public static string MutexName(string name, string root, string data)
        {
            string standard = Path.GetFullPath(Path.Combine(root, "data")).TrimEnd('\\');
            string actual = Path.GetFullPath(data).TrimEnd('\\');
            if (String.Equals(standard, actual, StringComparison.OrdinalIgnoreCase)) return name;
            using (SHA256 hash = SHA256.Create()) {
                byte[] digest = hash.ComputeHash(Encoding.UTF8.GetBytes(actual.ToUpperInvariant()));
                return name + "-" + BitConverter.ToString(digest, 0, 8).Replace("-", "");
            }
        }
        private static Process Create(string file, string arguments, string directory, bool capture)
        {
            return new Process { StartInfo = new ProcessStartInfo {
                FileName = file, Arguments = arguments, WorkingDirectory = directory,
                UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardOutput = capture, RedirectStandardError = capture
            }};
        }

        public static Process Start(string file, string arguments, string directory)
        {
            var process = Create(file, arguments, directory, false);
            try {
                if (!process.Start()) throw new InvalidOperationException("Process did not start.");
                // Detached long-running children must not depend on pipes owned
                // by a launcher that exits. CREATE_NO_WINDOW suppresses consoles.
                return process;
            } catch { process.Dispose(); throw; }
        }

        public static string Capture(string file, string arguments, string directory, int timeout)
        {
            using (var process = Create(file, arguments, directory, true)) {
                if (!process.Start()) throw new InvalidOperationException("Process did not start.");
                Task<string> output = process.StandardOutput.ReadToEndAsync();
                Task<string> errors = process.StandardError.ReadToEndAsync();
                if (!process.WaitForExit(timeout)) {
                    try { process.Kill(); process.WaitForExit(2000); } catch { }
                    throw new TimeoutException("Background command timed out.");
                }
                string result = output.GetAwaiter().GetResult();
                errors.GetAwaiter().GetResult();
                if (process.ExitCode != 0) throw new InvalidOperationException("Background command failed.");
                return result;
            }
        }
    }
}
