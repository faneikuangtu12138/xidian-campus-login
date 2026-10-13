using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Threading;
using System.Windows.Forms;

namespace CampusLogin
{
    internal static class SilentLauncher
    {
        [STAThread]
        private static int Main(string[] arguments)
        {
            string root = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
            string data = Environment.GetEnvironmentVariable("XIDIAN_CAMPUS_DATA");
            if (String.IsNullOrEmpty(data)) data = Path.Combine(root, "data");
            bool background = Array.IndexOf(arguments, "--background") >= 0;
            bool supervise = Array.IndexOf(arguments, "--supervise") >= 0;
            bool repair = Array.IndexOf(arguments, "--repair") >= 0 || String.Equals(Path.GetFileName(Application.ExecutablePath), "Repair.exe", StringComparison.OrdinalIgnoreCase);
            try {
                Directory.CreateDirectory(data);
                if (repair) {
                    string installed = @"D:\XidianCampusLogin\runtime\pwsh.exe";
                    using (Process update = BackgroundProcess.Start(installed,
                        "-NoLogo -NoProfile -ExecutionPolicy Bypass -File \"" + Path.Combine(root, "Apply-Fix.ps1") + "\"", root)) {
                        update.WaitForExit();
                        if (update.ExitCode != 0) throw new InvalidOperationException("Repair failed.");
                    }
                    MessageBox.Show("修复已安装。后台启动和网络检查已改为不创建终端窗口。", "西电校园网自动登录", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return 0;
                }
                // Calendar/recovery triggers must respect an explicit user exit.
                // Only logon (--background) and opening settings clear the marker.
                if (!supervise) {
                    string stop = Path.Combine(data, "stop.request");
                    if (File.Exists(stop)) File.Delete(stop);
                    if (!background) File.WriteAllText(Path.Combine(data, "open.request"), "");
                } else if (File.Exists(Path.Combine(data, "stop.request"))) return 0;

                using (var mutex = new Mutex(false, BackgroundProcess.MutexName(@"Local\XidianCampusLoginSupervisor",root,data))) {
                    bool free;
                    try { free = mutex.WaitOne(0); }
                    catch (AbandonedMutexException) { free = true; }
                    if (!free) return 0;
                    mutex.ReleaseMutex();
                }
                // Task Scheduler owns the persistent launcher and restarts failures.
                if (!supervise && String.Equals(Path.GetFullPath(data).TrimEnd('\\'), Path.GetFullPath(Path.Combine(root,"data")).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase) && TryRunScheduledTask()) return 0;
                string runtime = FindRuntime(root);
                string args = "-NoLogo -NoProfile -ExecutionPolicy Bypass -File \"" + Path.Combine(root, "Supervisor.ps1") + "\"";
                if (!background && !supervise) args += " -OpenSettings";
                using (Process process = BackgroundProcess.Start(runtime, args, root)) {
                    if (supervise) { process.WaitForExit(); return process.ExitCode; }
                    if (process.WaitForExit(1500) && process.ExitCode != 0)
                        throw new InvalidOperationException("Supervisor exited during startup.");
                }
                return 0;
            } catch (Exception error) {
                try { File.AppendAllText(Path.Combine(data, "startup.log"), DateTimeOffset.Now.ToString("o") + " STARTUP_FAILED type=" + error.GetType().Name + Environment.NewLine); } catch { }
                // Automatic starts never display error dialogs over other apps.
                if (repair || (!background && !supervise))
                    MessageBox.Show(repair ? "修复没有完成。请检查修复包 data\\repair-result.json 和 startup.log。" : "启动失败，请检查 data\\startup.log。", "西电校园网自动登录", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }
        }

        private static bool TryRunScheduledTask()
        {
            object service = null, folder = null, task = null, running = null;
            try {
                service = Activator.CreateInstance(Type.GetTypeFromProgID("Schedule.Service"));
                service.GetType().InvokeMember("Connect", BindingFlags.InvokeMethod, null, service, new object[] { Type.Missing, Type.Missing, Type.Missing, Type.Missing });
                folder = service.GetType().InvokeMember("GetFolder", BindingFlags.InvokeMethod, null, service, new object[] { "\\" });
                string name = "XidianCampusLogin-" + WindowsIdentity.GetCurrent().User.Value;
                task = folder.GetType().InvokeMember("GetTask", BindingFlags.InvokeMethod, null, folder, new object[] { name });
                bool enabled = (bool)task.GetType().InvokeMember("Enabled", BindingFlags.GetProperty, null, task, null);
                if (!enabled) return false;
                running = task.GetType().InvokeMember("Run", BindingFlags.InvokeMethod, null, task, new object[] { null });
                return true;
            } catch { return false; }
            finally {
                foreach(object item in new object[] {running, task, folder, service})
                    if(item != null && Marshal.IsComObject(item)) Marshal.ReleaseComObject(item);
            }
        }

        private static string FindRuntime(string root)
        {
            string[] candidates = {
                Path.Combine(root, @"runtime\pwsh.exe"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), @"PowerShell\7\pwsh.exe"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), @".cache\codex-runtimes\codex-primary-runtime\dependencies\native\powershell\pwsh.exe")
            };
            foreach (string candidate in candidates) if (File.Exists(candidate)) return candidate;
            throw new FileNotFoundException("PowerShell 7.4 or later is required.");
        }
    }
}
