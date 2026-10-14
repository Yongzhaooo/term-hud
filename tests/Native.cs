using System;
using System.Runtime.InteropServices;
using System.Text;

public static class TestDesktop
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool SetProp(IntPtr window, string name, IntPtr value);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    public static uint ProcessId(IntPtr window) { uint process; GetWindowThreadProcessId(window, out process); return process; }
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int cmd);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out Point p);
    [DllImport("user32.dll")] static extern uint SendInput(uint count, Input[] input, int size);
    [DllImport("user32.dll")] static extern bool PeekMessage(out Message msg, IntPtr window, uint min, uint max, uint remove);
    [DllImport("user32.dll")] static extern bool TranslateMessage(ref Message msg);
    [DllImport("user32.dll")] static extern IntPtr DispatchMessage(ref Message msg);
    [StructLayout(LayoutKind.Sequential)] struct Message { public IntPtr Window; public uint Id; public UIntPtr W; public IntPtr L; public uint Time; public Point Point; public uint Private; }
    [StructLayout(LayoutKind.Sequential)] public struct Point { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct Mouse { public int X, Y; public uint Data, Flags, Time; public UIntPtr Extra; }
    [StructLayout(LayoutKind.Explicit)] struct Input { [FieldOffset(0)] public uint Type; [FieldOffset(8)] public Mouse Mouse; }
    public static void Button(bool down)
    {
        if (SendInput(1, new[] { new Input { Mouse = new Mouse { Flags = down ? 2u : 4u } } }, Marshal.SizeOf<Input>()) != 1)
            throw new InvalidOperationException("SendInput failed: " + Marshal.GetLastWin32Error());
    }
    public static void Pump(int milliseconds)
    {
        long until = Environment.TickCount64 + milliseconds;
        do {
            Message message;
            while (Environment.TickCount64 < until && PeekMessage(out message, IntPtr.Zero, 0, 0, 1)) {
                TranslateMessage(ref message); DispatchMessage(ref message);
            }
            System.Threading.Thread.Sleep(2);
        } while (Environment.TickCount64 < until);
    }
}
