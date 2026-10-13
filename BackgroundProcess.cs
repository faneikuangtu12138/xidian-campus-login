using System;
using System.Diagnostics;
using System.Threading.Tasks;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

namespace CampusLogin
{
    // IShellLinkW and IPersistFile keep shortcut paths Unicode on every system locale.
    [ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IShellLinkW
    {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path, int count, IntPtr findData, uint flags);
        void GetIDList(out IntPtr item);
        void SetIDList(IntPtr item);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder text, int count);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string text);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path, int count);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string path);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder text, int count);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string text);
        void GetHotkey(out short value);
        void SetHotkey(short value);
        void GetShowCmd(out int value);
        void SetShowCmd(int value);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path, int count, out int index);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string path, int index);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string path, uint reserved);
        void Resolve(IntPtr window, uint flags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string path);
    }

    public static class BackgroundProcess
    {
        private static object NewShellLink()
        {
            return Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("00021401-0000-0000-C000-000000000046")));
        }
        public static void SaveShortcut(string path, string target, string arguments, string directory, string description)
        {
            object value = NewShellLink();
            try {
                var link = (IShellLinkW)value;
                link.SetPath(Path.GetFullPath(target));
                link.SetArguments(arguments ?? "");
                link.SetWorkingDirectory(Path.GetFullPath(directory));
                link.SetDescription(description ?? "");
                link.SetShowCmd(7);
                ((IPersistFile)value).Save(Path.GetFullPath(path), true);
            } finally { Marshal.FinalReleaseComObject(value); }
        }
        public static string ReadShortcutTarget(string path)
        {
            object value = NewShellLink();
            try {
                ((IPersistFile)value).Load(Path.GetFullPath(path), 0);
                var text = new StringBuilder(32768);
                ((IShellLinkW)value).GetPath(text, text.Capacity, IntPtr.Zero, 4);
                return text.ToString();
            } finally { Marshal.FinalReleaseComObject(value); }
        }
        public static string ReadShortcutArguments(string path)
        {
            object value = NewShellLink();
            try {
                ((IPersistFile)value).Load(Path.GetFullPath(path), 0);
                var text = new StringBuilder(32768);
                ((IShellLinkW)value).GetArguments(text, text.Capacity);
                return text.ToString();
            } finally { Marshal.FinalReleaseComObject(value); }
        }
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
