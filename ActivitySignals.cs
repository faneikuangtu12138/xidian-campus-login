using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Threading;

namespace CampusLogin
{
    [ComVisible(true), Guid("DCB00001-570F-4A9B-8D69-199FDBA5723B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IConnectivityEvents { void ConnectivityChanged(int connectivity); }
    [ComVisible(true), Guid("DCB00007-570F-4A9B-8D69-199FDBA5723B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IConnectionEvents {
        void NetworkConnectionConnectivityChanged(Guid connectionId, int connectivity);
        void NetworkConnectionPropertyChanged(Guid connectionId, int flags);
    }
    [ComVisible(true), ClassInterface(ClassInterfaceType.None)]
    public sealed class ConnectivitySink : IConnectivityEvents, IConnectionEvents
    {
        private readonly ActivitySignals owner;
        private int previous = -1;
        private readonly Dictionary<Guid,int> connections = new Dictionary<Guid,int>();
        public ConnectivitySink(ActivitySignals owner) { this.owner = owner; }
        public void ConnectivityChanged(int value) {
            if (Interlocked.Exchange(ref previous, value) != value) owner.Signal(1);
        }
        public void NetworkConnectionConnectivityChanged(Guid id, int value) {
            lock(connections) {
                int old;
                if(connections.TryGetValue(id,out old) && old == value)return;
                connections[id]=value;
            }
            owner.Signal(ActivitySignals.Network);
        }
        public void NetworkConnectionPropertyChanged(Guid id, int flags) {
            if((flags & 1) != 0) owner.Signal(ActivitySignals.Network);
        }
    }

    // Kernel waits and OS callbacks keep the idle worker asleep. There is no
    // timer, network polling, heartbeat loop, or PowerShell callback on a pool thread.
    public sealed class ActivitySignals : IDisposable
    {
        public const int Network = 1, Resume = 2, Request = 4, ChildExited = 8;
        private readonly AutoResetEvent wake = new AutoResetEvent(false);
        private readonly object sync = new object();
        private int pending;
        private bool disposed;
        private readonly FileSystemWatcher files;
        private readonly HashSet<string> names;
        private readonly bool network;
        private readonly List<Process> children = new List<Process>();
        private PowerCallback powerCallback;
        private IntPtr powerHandle, wlanHandle;
        private WlanCallback wlanCallback;
        private object manager;
        private IConnectionPoint connectionPoint;
        private IConnectionPoint adapterConnectionPoint;
        private ConnectivitySink sink;
        private int cookie;
        private int adapterCookie;
        public bool PowerSubscribed { get; private set; }
        public bool WifiSubscribed { get; private set; }
        public bool ConnectivitySubscribed { get; private set; }
        public bool ConnectionSubscribed { get; private set; }
        public string SubscriptionErrors { get; private set; }

        [UnmanagedFunctionPointer(CallingConvention.Winapi)]
        private delegate uint PowerCallback(IntPtr context, uint type, IntPtr setting);
        [StructLayout(LayoutKind.Sequential)]
        private struct PowerRecipient { public PowerCallback Callback; public IntPtr Context; }
        [DllImport("powrprof.dll")]
        private static extern uint PowerRegisterSuspendResumeNotification(uint flags, ref PowerRecipient recipient, out IntPtr handle);
        [DllImport("powrprof.dll")]
        private static extern uint PowerUnregisterSuspendResumeNotification(IntPtr handle);
        [UnmanagedFunctionPointer(CallingConvention.Winapi)]
        private delegate void WlanCallback(IntPtr notification, IntPtr context);
        [DllImport("wlanapi.dll")]
        private static extern uint WlanOpenHandle(uint version, IntPtr reserved, out uint negotiated, out IntPtr handle);
        [DllImport("wlanapi.dll")]
        private static extern uint WlanRegisterNotification(IntPtr handle, uint source, [MarshalAs(UnmanagedType.Bool)] bool ignoreDuplicate, WlanCallback callback, IntPtr context, IntPtr reserved, out uint previous);
        [DllImport("wlanapi.dll")]
        private static extern uint WlanCloseHandle(IntPtr handle, IntPtr reserved);

        public ActivitySignals(string directory, string[] watchedNames, bool watchNetwork)
        {
            network = watchNetwork;
            names = new HashSet<string>(watchedNames, StringComparer.OrdinalIgnoreCase);
            files = new FileSystemWatcher(directory) { NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite, IncludeSubdirectories = false };
            files.Created += FileChanged; files.Changed += FileChanged; files.Deleted += FileChanged;
            files.Renamed += delegate(object sender, RenamedEventArgs e) { FileChanged(sender, e); };
            files.Error += delegate { Signal(Request); };
            files.EnableRaisingEvents = true;
            SubscriptionErrors = "";
            if (!watchNetwork) return;
            try {
                NetworkChange.NetworkAddressChanged += AddressChanged;
                NetworkChange.NetworkAvailabilityChanged += AvailabilityChanged;
                powerCallback = delegate(IntPtr context, uint type, IntPtr setting) {
                    if (type == 7 || type == 18) Signal(Resume);
                    return 0;
                };
                var recipient = new PowerRecipient { Callback = powerCallback };
                uint code = PowerRegisterSuspendResumeNotification(2, ref recipient, out powerHandle);
                PowerSubscribed = code == 0;
                if (!PowerSubscribed) SubscriptionErrors += "power:"+code+";";
            } catch (Exception error) { SubscriptionErrors += "power:"+error.GetType().Name+";"; }
            try {
                uint version, previous;
                if (WlanOpenHandle(2, IntPtr.Zero, out version, out wlanHandle) == 0) {
                    wlanCallback = delegate(IntPtr notification, IntPtr context) {
                        int code = Marshal.ReadInt32(notification, 4);
                        // Connection complete, interface arrival/removal, disconnect.
                        if (code == 10 || code == 13 || code == 14 || code == 21) Signal(Network);
                    };
                    WifiSubscribed = WlanRegisterNotification(wlanHandle, 8, true, wlanCallback, IntPtr.Zero, IntPtr.Zero, out previous) == 0;
                }
            } catch (Exception error) { SubscriptionErrors += "wifi:"+error.GetType().Name+";"; }
            // COM connectivity callbacks use an MTA registration so they do not
            // depend on the PowerShell main thread pumping Windows messages.
            using (var ready = new ManualResetEvent(false)) {
                var thread = new Thread(delegate() {
                    try {
                        manager = Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("DCB00C01-570F-4A9B-8D69-199FDBA5723B")));
                        Guid iid = new Guid("DCB00001-570F-4A9B-8D69-199FDBA5723B");
                        ((IConnectionPointContainer)manager).FindConnectionPoint(ref iid, out connectionPoint);
                        sink = new ConnectivitySink(this);
                        connectionPoint.Advise(sink, out cookie);
                        ConnectivitySubscribed = true;
                        iid = new Guid("DCB00007-570F-4A9B-8D69-199FDBA5723B");
                        ((IConnectionPointContainer)manager).FindConnectionPoint(ref iid,out adapterConnectionPoint);
                        adapterConnectionPoint.Advise(sink,out adapterCookie);
                        ConnectionSubscribed = true;
                    } catch (Exception error) { SubscriptionErrors += "connectivity:"+error.GetType().Name+";"; }
                    finally { ready.Set(); }
                }) { IsBackground = true };
                thread.SetApartmentState(ApartmentState.MTA);
                thread.Start();
                ready.WaitOne();
            }
        }
        private void FileChanged(object sender, FileSystemEventArgs e) {
            if (e.ChangeType == WatcherChangeTypes.Deleted && String.Equals(e.Name, "retry.request", StringComparison.OrdinalIgnoreCase)) return;
            if (names.Contains(e.Name)) Signal(Request);
        }
        private void AddressChanged(object sender, EventArgs e) { Signal(Network); }
        private void AvailabilityChanged(object sender, NetworkAvailabilityEventArgs e) { Signal(Network); }
        private void ProcessExited(object sender, EventArgs e) { Signal(ChildExited); }
        public void Watch(Process process) {
            process.EnableRaisingEvents = true;
            process.Exited += ProcessExited;
            children.Add(process);
            if (process.HasExited) Signal(ChildExited);
        }
        public void Signal(int reason) {
            lock(sync) { if (disposed) return; pending |= reason; wake.Set(); }
        }
        public int Wait(int milliseconds) {
            if (!wake.WaitOne(milliseconds)) return 0;
            lock(sync) { int reason=pending; pending=0; return reason; }
        }
        public void Dispose() {
            lock(sync) { if(disposed)return; disposed=true; }
            files.Dispose();
            foreach (Process child in children) child.Exited -= ProcessExited;
            if (network) {
                NetworkChange.NetworkAddressChanged -= AddressChanged;
                NetworkChange.NetworkAvailabilityChanged -= AvailabilityChanged;
                if(powerHandle != IntPtr.Zero) PowerUnregisterSuspendResumeNotification(powerHandle);
                if(wlanHandle != IntPtr.Zero) WlanCloseHandle(wlanHandle, IntPtr.Zero);
                try { if(connectionPoint != null && cookie != 0) connectionPoint.Unadvise(cookie); } catch { }
                try { if(adapterConnectionPoint != null && adapterCookie != 0) adapterConnectionPoint.Unadvise(adapterCookie); } catch { }
                if(adapterConnectionPoint != null) Marshal.ReleaseComObject(adapterConnectionPoint);
                if(connectionPoint != null) Marshal.ReleaseComObject(connectionPoint);
                if(manager != null) Marshal.ReleaseComObject(manager);
            }
            wake.Dispose();
        }
    }
}
