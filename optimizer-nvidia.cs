using System;
using System.IO;
using System.Runtime.InteropServices;

// Public NVAPI DRS ABI: NVIDIA/nvapi (nvapi.h, nvapi_interface.h, NvApiDriverSettings.h).
// Only existing application profiles and DWORD settings; never the global profile.
public sealed class OptimizerNvidia : IDisposable
{
    [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr LoadLibraryEx(string path, IntPtr file, uint flags);
    [DllImport("kernel32", CharSet = CharSet.Ansi)]
    static extern IntPtr GetProcAddress(IntPtr module, string name);
    [DllImport("kernel32")] static extern bool FreeLibrary(IntPtr module);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate IntPtr Query(uint id);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int Initialize();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int Create(out IntPtr session);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int SessionCall(IntPtr session);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl, CharSet = CharSet.Unicode)]
    delegate int Find(IntPtr session, [MarshalAs(UnmanagedType.LPWStr)] string app, out IntPtr profile, IntPtr info);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int Get(IntPtr session, IntPtr profile, uint id, IntPtr setting);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int Set(IntPtr session, IntPtr profile, IntPtr setting);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int Delete(IntPtr session, IntPtr profile, uint id);
    IntPtr library, session;
    Query query;
    SessionCall destroy, load, save;
    Find find;
    Get get;
    Set set;
    Delete delete;

    public sealed class Value
    {
        public uint Data;
        public bool UserOverride;
    }

    T Bind<T>(uint id) where T : class
    {
        IntPtr address = query(id);
        if (address == IntPtr.Zero) throw new NotSupportedException("NVIDIA driver API unavailable.");
        return Marshal.GetDelegateForFunctionPointer(address, typeof(T)) as T;
    }
    static void Check(int code)
    {
        if (code == -104 || code == -3) throw new NotSupportedException("NVIDIA setting is unsupported (" + code + ").");
        if (code != 0) throw new InvalidOperationException("NVIDIA driver returned " + code + ".");
    }
    static IntPtr Buffer(int size)
    {
        IntPtr p = Marshal.AllocHGlobal(size);
        Marshal.Copy(new byte[size], 0, p, size);
        Marshal.WriteInt32(p, size | (1 << 16));
        return p;
    }
    static void RequireProfile(IntPtr profile)
    {
        if (profile == IntPtr.Zero || profile == new IntPtr(-1))
            throw new ArgumentException("An existing application profile is required.");
    }
    public OptimizerNvidia()
    {
        string path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
            IntPtr.Size == 8 ? "nvapi64.dll" : "nvapi.dll");
        if (!File.Exists(path)) throw new NotSupportedException("NVIDIA driver is not installed.");
        library = LoadLibraryEx(path, IntPtr.Zero, 0x800); // Dependencies from System32 only.
        if (library == IntPtr.Zero) throw new InvalidOperationException("Cannot load the NVIDIA driver API.");
        try
        {
            IntPtr address = GetProcAddress(library, "nvapi_QueryInterface");
            if (address == IntPtr.Zero) throw new NotSupportedException("NVIDIA driver API unavailable.");
            query = (Query)Marshal.GetDelegateForFunctionPointer(address, typeof(Query));
            Check(Bind<Initialize>(0x0150e828)());
            destroy = Bind<SessionCall>(0xdad9cff8);
            load = Bind<SessionCall>(0x375dbd6b);
            save = Bind<SessionCall>(0xfcbc7e14);
            find = Bind<Find>(0xeee566b2);
            get = Bind<Get>(0x73bf8338);
            set = Bind<Set>(0x577dd202);
            delete = Bind<Delete>(0xe4a26362);
            Check(Bind<Create>(0x0694d52e)(out session));
            Reload();
        }
        catch { Dispose(); throw; }
    }
    public IntPtr FindProfile(string app)
    {
        IntPtr info = Buffer(12296); // NVDRS_APPLICATION_V1: 2 DWORDs + 3 UTF-16[2048].
        try
        {
            IntPtr profile;
            int code = find(session, app, out profile, info);
            if (code == -166) return IntPtr.Zero; // NVAPI_EXECUTABLE_NOT_FOUND
            Check(code);
            if (profile == IntPtr.Zero || profile == new IntPtr(-1)) throw new InvalidOperationException("Invalid application profile.");
            return profile;
        }
        finally { Marshal.FreeHGlobal(info); }
    }
    public Value Read(IntPtr profile, uint id)
    {
        RequireProfile(profile);
        IntPtr p = Buffer(12320); // NVDRS_SETTING_V1, pack 4; each value union is 4100 bytes.
        try
        {
            int code = get(session, profile, id, p);
            if (code == -160) return null; // NVAPI_SETTING_NOT_FOUND
            Check(code);
            if (Marshal.ReadInt32(p, 4104) != 0) throw new NotSupportedException("NVIDIA setting is not a DWORD.");
            return new Value {
                Data = unchecked((uint)Marshal.ReadInt32(p, 8220)),
                UserOverride = Marshal.ReadInt32(p, 4108) == 0 && Marshal.ReadInt32(p, 4112) == 0
            };
        }
        finally { Marshal.FreeHGlobal(p); }
    }
    public void Write(IntPtr profile, uint id, uint value)
    {
        RequireProfile(profile);
        IntPtr p = Buffer(12320);
        try
        {
            Marshal.WriteInt32(p, 4100, unchecked((int)id));
            Marshal.WriteInt32(p, 8220, unchecked((int)value));
            Check(set(session, profile, p));
        }
        finally { Marshal.FreeHGlobal(p); }
    }
    public void Reset(IntPtr profile, uint id) { RequireProfile(profile); Check(delete(session, profile, id)); }
    public void Save() { Check(save(session)); }
    public void Reload() { Check(load(session)); }
    public void Dispose()
    {
        if (session != IntPtr.Zero) { destroy(session); session = IntPtr.Zero; }
        if (library != IntPtr.Zero) { FreeLibrary(library); library = IntPtr.Zero; }
    }
}
